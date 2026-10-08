import Foundation
import Testing
import GRDB
import DataContracts
import DataProviders
import MarketDataProviders
@testable import Persistence

private let equityWriteNow = Date(timeIntervalSince1970: 1_789_743_600)
private struct EquityWriteClock: EquityRequestClock {
    func now() -> Date { equityWriteNow }
    func uptime() -> TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation() }
}
private struct EquityWriteTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPPayload {
        HTTPPayload(statusCode: 200, mediaType: "application/json", body: Data(
            #"{"symbol":"MSFT","quote":{"t":"2026-09-18T14:59:59Z","bp":100,"ap":101,"bs":1,"as":2,"bx":"V","ax":"V"}}"#.utf8))
    }
}
private func acceptedEquityWrite() async throws -> AcceptedProviderPayload<EquityRecord> {
    let provider = try AlpacaIEXProvider(apiKey: Data("SYNTHETIC_KEY".utf8), secret: Data("SYNTHETIC_SECRET".utf8),
        evidenceRef: "synthetic-write-evidence", licenseRef: "synthetic-write-license",
        transport: EquityWriteTransport(), clock: EquityWriteClock())
    let rights = EntitlementSnapshot(providerID: "alpaca", feedID: "iex", version: "synthetic-write-rights.v1",
        evidenceRef: "synthetic-write-evidence", licenseRef: "synthetic-write-license", capabilities: [.quote], usages: [.replay],
        validFrom: equityWriteNow.addingTimeInterval(-60), validThrough: equityWriteNow.addingTimeInterval(60))
    let request = ProviderRequest(providerID: "alpaca", feedID: "iex", resourceID: "MSFT", capability: .quote,
        mode: .latest, usage: .replay, configurationVersion: AlpacaIEXProvider.configurationVersion,
        entitlementVersion: rights.version, requestedAt: equityWriteNow)
    return try await EquityDataClient(provider: provider, entitlement: rights).fetch(request)
}

/// A real SQLite callback holds the GRDB serial queue before the first source INSERT.
/// The test waits for explicit arrival, cancels, and then releases; no timing assumption.
private final class EquitySQLWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdQueue() {
        condition.lock()
        entered = true
        let current = waiters; waiters = []
        condition.unlock()
        current.forEach { $0.resume() }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitForQueue() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { condition.unlock(); continuation.resume(); return }
            waiters.append(continuation); condition.unlock()
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private actor EquityWriteEntryGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation; started = true
            let current = waiters; waiters = []; current.forEach { $0.resume() }
        }
    }
    func waitForEntry() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { let current = paused; paused = nil; current?.resume() }
}

@Suite struct EquityWriteCancellationTests {
    @Test func cancellationBeforeActorEntryRejectsAcceptedPageWithoutChangingRevision() async throws {
        let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
        let accepted = try await acceptedEquityWrite(), revision = await store.revision(), gate = EquityWriteEntryGate()
        let operation = Task {
            await gate.pause()
            return try await store.ingestEquity(accepted, expectedRevision: revision)
        }
        await gate.waitForEntry(); operation.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await store.equityPages(symbol: "MSFT").isEmpty)
        #expect(await store.revision() == revision)
    }

    @Test func cancellationInsideGRDBQueueRollsBackAllRowsAndRetainsOriginalRetryRevision() async throws {
        let database = try DatabaseStore(path: ":memory:"), store = try BusinessDataStore(database: database)
        let accepted = try await acceptedEquityWrite(), revision = await store.revision(), gate = EquitySQLWriteGate()
        try database.transaction { db in
            db.add(function: DatabaseFunction("synthetic_equity_write_gate", argumentCount: 0) { _ in
                gate.holdQueue(); return 0
            })
            try db.execute(sql: """
                CREATE TRIGGER synthetic_equity_write_pause BEFORE INSERT ON p1_source_documents
                BEGIN SELECT synthetic_equity_write_gate(); END
                """)
        }
        let operation = Task { try await store.ingestEquity(accepted, expectedRevision: revision) }
        await gate.waitForQueue()
        operation.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        let counts = try database.read { db in
            try ["p1_source_documents", "p1_equity_records", "p1_equity_pages"].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + table)!
            }
        }
        #expect(counts == [0, 0, 0])
        #expect(await store.revision() == revision)
        try database.transaction { try $0.execute(sql: "DROP TRIGGER synthetic_equity_write_pause") }
        let retry = try await store.ingestEquity(accepted, expectedRevision: revision)
        #expect(retry.insertedDocuments == 1 && retry.insertedRecords == 1 && retry.insertedPages == 1)
        #expect(retry.revision != revision)
    }
}
