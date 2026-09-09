import Foundation
import Security

public enum CredentialError: Error { case invalidReference, status(OSStatus) }
/// Logical Security module uses a distinct Swift module name to avoid Apple's Security framework collision.
public actor CredentialStore {
    private let service: String
    public init(service: String = "local.marketdecision.credentials") { self.service = service }
    private func query(_ reference: String) throws -> [String: Any] {
        guard !reference.isEmpty else { throw CredentialError.invalidReference }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: reference, kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false]
    }
    public func save(_ secret: Data, reference: String) throws {
        let match = try query(reference)
        let attributes: [String: Any] = [kSecValueData as String: secret, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd(match.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw CredentialError.status(result) }
        } else if status != errSecSuccess { throw CredentialError.status(status) }
    }
    public func read(reference: String) throws -> Data? {
        var match = try query(reference); match[kSecReturnData as String] = true; match[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(match as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw CredentialError.status(result) }
        guard let data = value as? Data else { throw CredentialError.status(errSecDecode) }
        return data
    }
    /// Read back the actual stored accessibility; do not infer it from the write request.
    public func isDeviceOnlyWhileUnlocked(reference: String) throws -> Bool {
        var match = try query(reference)
        match[kSecReturnAttributes as String] = true
        match[kSecMatchLimit as String] = kSecMatchLimitOne
        match[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var value: CFTypeRef?
        let result = SecItemCopyMatching(match as CFDictionary, &value)
        guard result == errSecSuccess else { throw CredentialError.status(result) }
        guard let attributes = value as? [String: Any] else { throw CredentialError.status(errSecDecode) }
        return attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    }
    public func delete(reference: String) throws {
        let result = SecItemDelete(try query(reference) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CredentialError.status(result) }
    }
}
