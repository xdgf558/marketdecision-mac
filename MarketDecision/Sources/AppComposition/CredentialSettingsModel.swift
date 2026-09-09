import Foundation
import Observation
import SecuritySupport

/// Shared between settings windows. It holds status only, never an editable or stored secret.
@MainActor @Observable public final class CredentialSettingsModel {
    public enum Presence: Sendable { case unknown, absent, saved }
    public private(set) var presence: Presence = .unknown
    public private(set) var isBusy = false
    public private(set) var revision = UUID()
    public private(set) var message: String?
    public private(set) var hasError = false
    private let store: any CredentialStorage
    private let reference = "reserved-data-service"

    public init(store: any CredentialStorage) { self.store = store }

    public func refresh() async {
        guard !isBusy else { return }
        revision = UUID()
        isBusy = true
        defer { isBusy = false }
        do {
            presence = try await store.contains(reference: reference) ? .saved : .absent
            message = nil
            hasError = false
        } catch { fail("无法检查钥匙串状态。请解锁设备后重试。") }
    }

    @discardableResult public func save(_ secret: String, expectedRevision: UUID? = nil) async -> Bool {
        guard !isBusy, presence != .unknown, expectedRevision == nil || expectedRevision == revision else { return false }
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请输入凭据，不能只包含空白。"
            hasError = true
            return false
        }
        revision = UUID()
        isBusy = true
        defer { isBusy = false }
        do {
            // Preserve the supplied bytes; do not silently trim a credential.
            try await store.save(Data(secret.utf8), reference: reference)
            presence = .saved
            message = "凭据已保存到本机钥匙串；尚未验证服务连接。"
            hasError = false
            return true
        } catch {
            fail("保存失败，未确认凭据是否已保存。请检查钥匙串状态后重试。")
            return false
        }
    }

    @discardableResult public func delete(expectedRevision: UUID? = nil) async -> Bool {
        guard !isBusy, presence == .saved, expectedRevision == nil || expectedRevision == revision else { return false }
        revision = UUID()
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.delete(reference: reference)
            presence = .absent
            message = "本机凭据已删除。"
            hasError = false
            return true
        } catch {
            fail("删除失败，未确认凭据是否已删除。请检查钥匙串状态后重试。")
            return false
        }
    }

    private func fail(_ text: String) {
        presence = .unknown
        message = text
        hasError = true
    }
}
