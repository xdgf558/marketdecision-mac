import Foundation

/// Secret reads are a separate capability. Presence checks never retrieve credential bytes.
public protocol CredentialReadingStorage: CredentialStorage {
    func read(reference: String) async throws -> Data?
}

extension CredentialStore: CredentialReadingStorage {}

public enum EquityCredentialError: Error, Sendable { case invalidEnvelope }

/// One atomic Keychain item owns both halves; no separately replaceable key/secret records.
/// This value has no textual/logging representation and is never part of a research report.
public struct EquityCredentials: Sendable, Codable {
    public static let reference = "alpaca-iex-equity-credentials.v1"
    public let format: String
    public let apiKey: Data
    public let secret: Data

    public init(apiKey: String, secret: String) throws {
        format = "equity-credentials.v1"
        self.apiKey = Data(apiKey.utf8); self.secret = Data(secret.utf8)
        try validate()
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 4_096 else { throw EquityCredentialError.invalidEnvelope }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: bytes) }
        catch { throw EquityCredentialError.invalidEnvelope }
        try result.validate()
        return result
    }

    public func validate() throws {
        guard format == "equity-credentials.v1", [apiKey, secret].allSatisfy({ bytes in
            guard (4...256).contains(bytes.count), let text = String(data: bytes, encoding: .utf8) else { return false }
            return text.range(of: #"^[A-Za-z0-9_-]{4,256}\z"#, options: .regularExpression) != nil
        }) else { throw EquityCredentialError.invalidEnvelope }
    }
}
