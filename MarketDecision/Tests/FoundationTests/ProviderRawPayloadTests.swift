import Foundation
import Testing
import DataContracts
import DataProviders

private func rawPayloadSnapshot(_ bytes: Data, reference: String = "raw/synthetic-snapshot") throws -> ProviderRawPayload {
    try .init(reference: reference, mediaType: "application/json", bytes: bytes,
        storageAvailableAt: Date(timeIntervalSince1970: 1_800_000_000),
        evidenceRef: "synthetic-snapshot-evidence", licenseRef: "synthetic-test-only")
}

@Suite struct ProviderRawPayloadTests {
    @Test func externallyMutableNoCopyDataCannotChangeOwnedBytesOrStoredHash() throws {
        let count = 128
        let memory = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 65, count: count)
        let borrowed = Data(bytesNoCopy: memory, count: count, deallocator: .none)
        let payload = try rawPayloadSnapshot(borrowed)
        let original = Data(repeating: 65, count: count)
        let originalHash = "b6ac3cc10386331c765f04f041c147d0f278f2aed8eaa021e2d0057fc6f6ff9e"
        #expect(payload.bytes == original && payload.contentHash == originalHash)

        memory.storeBytes(of: UInt8(66), as: UInt8.self)
        // Prove that this fixture is an externally mutable view, not an ordinary COW copy.
        #expect(borrowed[0] == 66)
        #expect(payload.bytes == original && payload.contentHash == originalHash)
        #expect(payload.contentHash == digest(payload.bytes))
    }

    @Test func mutableNSDataOwnerAndExposedDataCopiesCannotMutateSnapshot() throws {
        let owner = NSMutableData(data: Data(repeating: 65, count: 128))
        let borrowed = Data(bytesNoCopy: owner.mutableBytes, count: owner.length, deallocator: .none)
        let payload = try rawPayloadSnapshot(borrowed)
        let before = payload.contentHash
        owner.mutableBytes.storeBytes(of: UInt8(90), as: UInt8.self)
        #expect(borrowed[0] == 90)
        #expect(payload.bytes[0] == 65 && payload.contentHash == before)

        var exportedCopy = payload.bytes
        exportedCopy[1] = 67
        #expect(exportedCopy[1] == 67 && payload.bytes[1] == 65)
        #expect(payload.contentHash == digest(payload.bytes))
        // Keep the external owner alive until the borrowed no-copy view is no longer used.
        withExtendedLifetime(owner) {}
    }

    @Test func hashBindsExactContentIndependentlyOfReference() throws {
        let original = Data(repeating: 65, count: 128)
        var changed = original
        changed[0] = 66
        let first = try rawPayloadSnapshot(original)
        let same = try rawPayloadSnapshot(original, reference: "raw/another-retrieval")
        let other = try rawPayloadSnapshot(changed)
        #expect(first.contentHash == same.contentHash)
        #expect(first.contentHash == "b6ac3cc10386331c765f04f041c147d0f278f2aed8eaa021e2d0057fc6f6ff9e")
        #expect(other.contentHash == "9c11365846d5b686742c415a49cf8d4a716fb94461df43567a20ad7215183055")
        #expect(first.contentHash != other.contentHash)
    }
}
