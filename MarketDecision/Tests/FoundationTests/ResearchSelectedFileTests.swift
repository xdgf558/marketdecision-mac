import Foundation
import Darwin
import Testing
@testable import AppComposition

private struct SelectedFileFixture {
    let directory: URL
    let file: URL
    init(_ bytes: Data = Data()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("selected-file-\(UUID())")
        file = directory.appendingPathComponent("research.zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class SelectedFileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0, chunks = 0
    private var descriptor: Int32?
    private var descriptorClosedAtEnd = false
    func begin() { lock.lock(); starts += 1; lock.unlock() }
    func end() {
        lock.lock(); defer { lock.unlock() }
        stops += 1
        if let descriptor { descriptorClosedAtEnd = Darwin.fcntl(descriptor, F_GETFD) == -1 && errno == EBADF }
    }
    func read(_ descriptor: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.descriptor = descriptor; chunks += 1
        return chunks == 1
    }
    func state() -> (starts: Int, stops: Int, chunks: Int, closed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops, chunks, descriptorClosedAtEnd)
    }
    func access(acquired: Bool = true) -> ResearchSelectedFile.Access {
        .init(begin: { _ in self.begin(); return acquired }, end: { _ in self.end() })
    }
}

@Suite struct ResearchSelectedFileTests {
    @Test func copiesOrdinaryBytesAndDoesNotRetainFileMapping() async throws {
        let original = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
        let fixture = try SelectedFileFixture(original); defer { fixture.remove() }
        let bytes = try await ResearchSelectedFile.read(fixture.file)
        try Data([9]).write(to: fixture.file)
        #expect(bytes == original)
        #expect(try Data(contentsOf: fixture.file) == Data([9]))
        // A literal percent sequence in a filename is not an encoded NUL.
        let literal = fixture.directory.appendingPathComponent("literal%00.zip")
        try original.write(to: literal)
        #expect(try await ResearchSelectedFile.read(literal) == original)
    }

    @Test func rejectsNonLocalURLsBeforeAcquiringAccess() async throws {
        let probe = SelectedFileProbe()
        for text in ["https://example.invalid/research.zip", "file://remote.example/research.zip", "file:///tmp/research.zip?query", "file:///tmp/research%00.zip"] {
            let url = try #require(URL(string: text))
            await #expect(throws: ResearchSelectedFile.ReadError.nonLocalFile, "\(text)") {
                try await ResearchSelectedFile.read(url, maximumBytes: 8, access: probe.access())
            }
        }
        #expect(probe.state().starts == 0)
    }

    @Test func rejectsDirectorySymbolicLinkAndFIFOWithoutBlocking() async throws {
        let fixture = try SelectedFileFixture(Data([1])); defer { fixture.remove() }
        let link = fixture.directory.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        await #expect(throws: ResearchSelectedFile.ReadError.nonRegularFile) {
            try await ResearchSelectedFile.read(fixture.directory)
        }
        do {
            _ = try await ResearchSelectedFile.read(link)
            Issue.record("A symbolic link was accepted")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(ELOOP))
        }
        let fifo = fixture.directory.appendingPathComponent("fifo.zip")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: ResearchSelectedFile.ReadError.nonRegularFile) {
            try await ResearchSelectedFile.read(fifo)
        }
    }

    @Test func enforcesExactSizeBoundaryIncludingEmptyFile() async throws {
        let fixture = try SelectedFileFixture(); defer { fixture.remove() }
        #expect(ResearchSelectedFile.maximumBytes == 2_147_483_648)
        #expect(try await ResearchSelectedFile.read(fixture.file, maximumBytes: 0).isEmpty)
        let exact = Data(repeating: 7, count: 8)
        try exact.write(to: fixture.file)
        #expect(try await ResearchSelectedFile.read(fixture.file, maximumBytes: 8) == exact)
        let probe = SelectedFileProbe()
        await #expect(throws: ResearchSelectedFile.ReadError.resourceLimit) {
            try await ResearchSelectedFile.read(fixture.file, maximumBytes: 7, access: probe.access())
        }
        #expect(probe.state().starts == 1 && probe.state().stops == 1)
    }

    @Test func growingFileCannotBypassLimitCheckedBeforeReading() async throws {
        let fixture = try SelectedFileFixture(Data(repeating: 1, count: 65_536)); defer { fixture.remove() }
        let probe = SelectedFileProbe()
        await #expect(throws: ResearchSelectedFile.ReadError.resourceLimit) {
            try await ResearchSelectedFile.read(fixture.file, maximumBytes: 65_536,
                access: probe.access(), didReadChunk: { descriptor in
                    if probe.read(descriptor) {
                        let writer = try FileHandle(forWritingTo: fixture.file); defer { try? writer.close() }
                        try writer.seekToEnd(); try writer.write(contentsOf: Data([2]))
                    }
                })
        }
        #expect(probe.state().stops == 1 && probe.state().closed)
    }

    @Test func truncationDuringReadIsRejected() async throws {
        let fixture = try SelectedFileFixture(Data(repeating: 1, count: 80_000)); defer { fixture.remove() }
        let probe = SelectedFileProbe()
        await #expect(throws: ResearchSelectedFile.ReadError.changedDuringRead) {
            try await ResearchSelectedFile.read(fixture.file, maximumBytes: 80_000,
                didReadChunk: { descriptor in
                    if probe.read(descriptor) {
                        let writer = try FileHandle(forWritingTo: fixture.file); defer { try? writer.close() }
                        try writer.truncate(atOffset: 1)
                    }
                })
        }
    }

    @Test func preCancelledReadNeverAcquiresSecurityScope() async throws {
        let fixture = try SelectedFileFixture(Data([1])); defer { fixture.remove() }
        let probe = SelectedFileProbe()
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ResearchSelectedFile.read(fixture.file, maximumBytes: 8, access: probe.access())
        }
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(probe.state().starts == 0 && probe.state().stops == 0)
    }

    @Test func parentCancellationClosesDescriptorAndReleasesScopeBeforeReturning() async throws {
        // Holding this post-read hook tests the next cooperative cancellation boundary,
        // not the ability to interrupt a blocked filesystem syscall.
        let fixture = try SelectedFileFixture(Data(repeating: 1, count: 150_000)); defer { fixture.remove() }
        let probe = SelectedFileProbe()
        let arrival = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let pending = Task {
            // An early read failure must end the arrival wait as well.
            defer { arrival.signal() }
            return try await ResearchSelectedFile.read(fixture.file, maximumBytes: 150_000,
                access: probe.access(), didReadChunk: { descriptor in
                    if probe.read(descriptor) {
                        arrival.signal()
                        // Only the parent releases this wait, after cancelling.
                        release.wait()
                    }
                })
        }
        defer {
            pending.cancel()
            arrival.signal()
            release.signal()
        }
        // Cancel independently of the cooperative pool occupied by the read hook.
        let scopeHeldWhileBlocked = await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                arrival.wait()
                pending.cancel()
                let state = probe.state()
                let scopeHeld = state.starts == 1 && state.stops == 0
                release.signal()
                finished.resume(returning: scopeHeld)
            }
        }
        #expect(scopeHeldWhileBlocked)
        await #expect(throws: CancellationError.self) { try await pending.value }
        let state = probe.state()
        #expect(state.starts == 1 && state.stops == 1 && state.chunks == 1 && state.closed)
    }

    @Test func unscopedLocalAccessAndOriginalFailureArePreserved() async throws {
        let fixture = try SelectedFileFixture(Data([1, 2])); defer { fixture.remove() }
        let probe = SelectedFileProbe()
        #expect(try await ResearchSelectedFile.read(fixture.file, maximumBytes: 8, access: probe.access(acquired: false)) == Data([1, 2]))
        do {
            _ = try await ResearchSelectedFile.read(fixture.directory.appendingPathComponent("missing.zip"),
                maximumBytes: 8, access: probe.access(acquired: false))
            Issue.record("A missing file was accepted")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT))
            #expect(!(error is CancellationError))
        }
        #expect(probe.state().starts == 2 && probe.state().stops == 0)
    }

    @Test func deniedFilePreservesAccessErrorAndReleasesScope() async throws {
        let fixture = try SelectedFileFixture(Data([1])); defer { fixture.remove() }
        #expect(Darwin.chmod(fixture.file.path, 0) == 0)
        defer { Darwin.chmod(fixture.file.path, 0o600) }
        let probe = SelectedFileProbe()
        do {
            _ = try await ResearchSelectedFile.read(fixture.file, maximumBytes: 8, access: probe.access())
            Issue.record("An unreadable file was accepted")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(EACCES))
            #expect(!(error is CancellationError))
        }
        #expect(probe.state().starts == 1 && probe.state().stops == 1)
    }
}
