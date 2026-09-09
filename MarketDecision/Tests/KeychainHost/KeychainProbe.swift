import Foundation

// Built with the production CredentialStore.swift in a separately signed macOS host.
@main struct KeychainProbe {
    static func main() async throws {
        let store = CredentialStore(service: "local.marketdecision.probe." + UUID().uuidString)
        let reference = "disposable-synthetic-fixture"
        enum ProbeFailure: Error { case mismatch }
        do {
            guard try await store.read(reference: reference) == nil else { throw ProbeFailure.mismatch }
            try await store.save(Data("synthetic-initial".utf8), reference: reference)
            guard try await store.read(reference: reference) == Data("synthetic-initial".utf8),
                  try await store.isDeviceOnlyWhileUnlocked(reference: reference) else { throw ProbeFailure.mismatch }
            guard try await store.protection(reference: reference).synchronizable == false else { throw ProbeFailure.mismatch }
            print("PASS create/read/device-only accessibility/synchronization disabled")
            try await store.save(Data("synthetic-replacement".utf8), reference: reference)
            guard try await store.read(reference: reference) == Data("synthetic-replacement".utf8) else { throw ProbeFailure.mismatch }
            print("PASS update/read")
            try await store.delete(reference: reference)
            guard try await store.read(reference: reference) == nil else { throw ProbeFailure.mismatch }
            try await store.delete(reference: reference)
            print("PASS delete/missing/idempotent delete")
        } catch {
            do { try await store.delete(reference: reference) }
            catch { print("FAIL fixture cleanup; retain this run for investigation") }
            // No credential values or arbitrary error descriptions are logged.
            if case CredentialError.status(let status) = error { print("FAIL Keychain OSStatus \(status)") }
            throw error
        }
    }
}
