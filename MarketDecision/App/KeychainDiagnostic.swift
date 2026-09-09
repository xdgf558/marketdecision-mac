#if DEBUG
import Foundation
import SecuritySupport

/// Explicit diagnostic mode in the actual app executable; no UI, real keys, or business database.
enum KeychainDiagnostic {
    enum Failure: Error { case arguments, mismatch }
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 4, arguments[1] == "--keychain-diagnostic",
              let runID = UUID(uuidString: arguments[3]),
              ["create", "resume", "absent", "cleanup"].contains(arguments[2]) else {
            print("FAIL diagnostic arguments")
            return 2
        }
        let store = CredentialStore(service: "local.marketdecision.app-diagnostic." + runID.uuidString)
        let reference = "synthetic-only"
        let initial = Data("synthetic-initial".utf8)
        let replacement = Data("synthetic-replacement".utf8)
        do {
            switch arguments[2] {
            case "create":
                guard try await store.read(reference: reference) == nil else { throw Failure.mismatch }
                try await store.save(initial, reference: reference)
                guard try await store.read(reference: reference) == initial else { throw Failure.mismatch }
                try await checkProtection(store, reference)
                try await store.save(replacement, reference: reference)
                guard try await store.read(reference: reference) == replacement else { throw Failure.mismatch }
                try await checkProtection(store, reference)
                print("PASS app create/read/update/protection pid=\(ProcessInfo.processInfo.processIdentifier)")
            case "resume":
                guard try await store.read(reference: reference) == replacement else { throw Failure.mismatch }
                try await checkProtection(store, reference)
                try await store.delete(reference: reference)
                guard try await store.read(reference: reference) == nil else { throw Failure.mismatch }
                print("PASS app restart/read/protection/delete pid=\(ProcessInfo.processInfo.processIdentifier)")
            case "absent":
                guard try await store.read(reference: reference) == nil else { throw Failure.mismatch }
                print("PASS app restart/absence pid=\(ProcessInfo.processInfo.processIdentifier)")
            default:
                try await store.delete(reference: reference)
                guard try await store.read(reference: reference) == nil else { throw Failure.mismatch }
                print("PASS app fixture cleanup")
            }
            return 0
        } catch {
            if case CredentialError.status(let status) = error { print("FAIL app Keychain OSStatus \(status)") }
            else { print("FAIL app diagnostic assertion") }
            return 1
        }
    }
    private static func checkProtection(_ store: CredentialStore, _ reference: String) async throws {
        let attributes = try await store.protection(reference: reference)
        guard attributes.deviceOnlyWhileUnlocked, !attributes.synchronizable else { throw Failure.mismatch }
    }
}
#endif
