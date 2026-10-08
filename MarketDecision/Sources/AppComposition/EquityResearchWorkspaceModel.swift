import Foundation
import Observation
import CoreDomain
import DataContracts
import SecuritySupport
import FundamentalsEngine

@MainActor @Observable public final class EquityResearchWorkspaceModel {
    public enum Presence: Sendable { case unknown, absent, saved }
    public enum CredentialAction: Sendable, Equatable { case replace, delete }
    public struct Confirmation: Identifiable, Equatable {
        public let id: UUID
        public let action: CredentialAction
        fileprivate let revision, session, draftRevision: UUID
    }
    public var keyDraft = "" { didSet { invalidateDraftConfirmation() } }
    public var secretDraft = "" { didSet { invalidateDraftConfirmation() } }
    public var symbolDraft = "" { didSet { if symbolDraft != oldValue { cancelFetch() } } }
    public var classIDDraft = "" { didSet { if classIDDraft != oldValue { cancelFetch() } } }
    public var selectedSide: SECReferencePriceSide = .bid { didSet { if selectedSide != oldValue { cancelFetch() } } }
    public var rightsAssertion = "" { didSet { if rightsAssertion != oldValue { cancelFetch() } } }
    public var rightsEvidence = "" { didSet { if rightsEvidence != oldValue { cancelFetch() } } }
    public var rightsEvidenceReference = "" { didSet { if rightsEvidenceReference != oldValue { cancelFetch() } } }
    public var rightsLicenseReference = "" { didSet { if rightsLicenseReference != oldValue { cancelFetch() } } }
    public var rightsConfirmed = false { didSet { if rightsConfirmed != oldValue { cancelFetch() } } }
    public var includeDailyBars = false { didSet { if includeDailyBars != oldValue { cancelFetch() } } }
    public var barsStart: Date { didSet { if barsStart != oldValue { cancelFetch() } } }
    public var barsEnd: Date { didSet { if barsEnd != oldValue { cancelFetch() } } }
    public private(set) var presence: Presence = .unknown
    public private(set) var isCredentialBusy = false
    public private(set) var credentialMessage: String?
    public private(set) var hasCredentialError = false
    public private(set) var confirmation: Confirmation?
    public private(set) var isFetching = false
    public private(set) var result: EquityResearchCapture?
    public private(set) var fetchMessage: String?
    public private(set) var hasFetchError = false
    /// Local package/signature readiness only; this is not supplier or account certification.
    public let networkAvailable: Bool
    public var networkUnavailableMessage: String? {
        networkAvailable ? nil : "当前构建未具备已批准且通过签名检查的独立行情服务，行情读取已停用。本机凭据管理仍可使用。"
    }
    @ObservationIgnored private let store: any CredentialReadingStorage
    @ObservationIgnored private let acquisition: EquityResearchAcquisition
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private var credentialRevision: UUID?
    @ObservationIgnored private var credentialOperation: UUID?
    @ObservationIgnored private var draftRevision = UUID()
    @ObservationIgnored private var fetchOperation: UUID?
    @ObservationIgnored private var fetchTask: Task<EquityResearchCapture, Error>?

    public init(store: any CredentialReadingStorage, acquisition: EquityResearchAcquisition, networkAvailable: Bool,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.acquisition = acquisition; self.clock = clock; self.networkAvailable = networkAvailable
        // Construction does no Keychain, database, provider or transport operation.
        let now = clock()
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86_400) * 86_400 - 86_400)
        barsEnd = end; barsStart = end.addingTimeInterval(-30 * 86_400)
    }
    public var canSaveCredentials: Bool {
        !isCredentialBusy && presence != .unknown && (try? EquityCredentials(apiKey: keyDraft, secret: secretDraft)) != nil
    }
    public var canDeleteCredentials: Bool { !isCredentialBusy && presence == .saved }
    public var canFetch: Bool { networkAvailable && !isCredentialBusy && !isFetching && presence == .saved && rightsConfirmed }

    public func appear() { session = UUID(); confirmation = nil }
    public func disappear() {
        session = nil; confirmation = nil
        keyDraft = ""; secretDraft = ""
        cancelFetch()
    }

    @discardableResult public func checkCredentials() async -> Bool {
        guard let session, !isCredentialBusy else { return false }
        cancelFetch(); confirmation = nil
        let operation = UUID(); credentialOperation = operation; isCredentialBusy = true
        defer { if credentialOperation == operation { credentialOperation = nil; isCredentialBusy = false } }
        do {
            let revision = try await acquisition.beginCredentialUpdate(expectedRevision: nil)
            do {
                let present = try await store.contains(reference: EquityCredentials.reference)
                await acquisition.endCredentialUpdate(revision)
                guard self.session == session else { presence = .unknown; credentialRevision = nil; return false }
                credentialRevision = revision; presence = present ? .saved : .absent
                credentialMessage = present ? "本机凭据已保存；尚未验证账户或数据权限。" : "尚未保存行情账户凭据。"
                hasCredentialError = false
                return true
            } catch {
                await acquisition.endCredentialUpdate(revision)
                throw error
            }
        } catch {
            credentialRevision = nil; presence = .unknown
            if self.session == session { credentialFailure("无法检查钥匙串状态，请解锁设备后重新检查。") }
            return false
        }
    }

    /// Only an explicit button/menu action calls this; Return in a text field is not persistence.
    public func requestSaveCredentials() async {
        guard let session, canSaveCredentials, let revision = credentialRevision else { return }
        if presence == .saved {
            confirmation = Confirmation(id: UUID(), action: .replace, revision: revision, session: session, draftRevision: draftRevision)
        } else { await writeCredentials(delete: false, revision: revision, session: session) }
    }
    public func requestDeleteCredentials() {
        guard let session, canDeleteCredentials, let revision = credentialRevision else { return }
        confirmation = Confirmation(id: UUID(), action: .delete, revision: revision, session: session, draftRevision: draftRevision)
    }
    public func respondToConfirmation(id: UUID, confirmed: Bool) async {
        guard let value = confirmation, value.id == id else { return }
        confirmation = nil
        guard confirmed, value.session == session, value.revision == credentialRevision,
              value.draftRevision == draftRevision, !isCredentialBusy else { return }
        await writeCredentials(delete: value.action == .delete, revision: value.revision, session: value.session)
    }

    private func writeCredentials(delete: Bool, revision: UUID, session: UUID) async {
        let bytes: Data
        do { bytes = delete ? Data() : try EquityCredentials(apiKey: keyDraft, secret: secretDraft).encoded() }
        catch { credentialMessage = "请输入有效的 API ID 和 Secret；不会自动修剪或修改凭据。"; hasCredentialError = true; return }
        cancelFetch(); confirmation = nil
        let operation = UUID(); credentialOperation = operation; isCredentialBusy = true
        defer { if credentialOperation == operation { credentialOperation = nil; isCredentialBusy = false } }
        do {
            let next = try await acquisition.beginCredentialUpdate(expectedRevision: revision)
            do {
                if delete { try await store.delete(reference: EquityCredentials.reference) }
                else { try await store.save(bytes, reference: EquityCredentials.reference) }
                await acquisition.endCredentialUpdate(next)
                guard self.session == session else { presence = .unknown; credentialRevision = nil; return }
                presence = delete ? .absent : .saved; credentialRevision = next
                keyDraft = ""; secretDraft = ""
                credentialMessage = delete ? "本机行情凭据已删除。" : "API ID 和 Secret 已作为一份凭据保存；未认证供应商权限。"
                hasCredentialError = false
            } catch {
                await acquisition.endCredentialUpdate(next)
                throw error
            }
        } catch {
            presence = .unknown; credentialRevision = nil
            if self.session == session { credentialFailure("操作未确认完成。请先检查钥匙串状态，再重新发起操作。") }
        }
    }

    public func fetch() async {
        // Guard the model entry as well as the button: no credential bytes, provider or XPC
        // connection are needed to discover a missing/unsealed helper.
        guard networkAvailable else {
            if session != nil { fetchMessage = networkUnavailableMessage; hasFetchError = true }
            return
        }
        guard let session, canFetch, let revision = credentialRevision else {
            if self.session != nil { fetchMessage = "请先检查已保存凭据，并明确确认本次本地读取与留存权利。"; hasFetchError = true }
            return
        }
        let rights: SECCapturedPriceRights
        do {
            guard !rightsEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EquityResearchError.invalidInput }
            let date = try MillisecondInstant(flooring: clock()).date
            // Fifteen minutes is a local action window, NOT a claimed provider license expiry.
            rights = try SECCapturedPriceRights(entitlementVersion: "local-replay-" + UUID().uuidString,
                evidenceReference: rightsEvidenceReference, licenseReference: rightsLicenseReference,
                recordedAt: date, validFrom: date, validThrough: date.addingTimeInterval(15 * 60),
                assertion: rightsAssertion, evidenceBytes: Data(rightsEvidence.utf8))
        } catch {
            fetchMessage = "请填写完整的权利声明、证据文字及来源引用；不会据此认证账户或供应商。"; hasFetchError = true
            return
        }
        let symbol = symbolDraft, classID = classIDDraft, side = selectedSide
        let bars = includeDailyBars ? DateRange(start: barsStart, end: barsEnd) : nil
        let operation = UUID(), acquisition = acquisition, store = store
        result = nil; fetchMessage = nil; hasFetchError = false; isFetching = true; fetchOperation = operation
        let task = Task { try await acquisition.capture(symbol: symbol, classID: classID, side: side,
            rights: rights, bars: bars, credentialStore: store, expectedCredentialRevision: revision) }
        fetchTask = task
        defer {
            if fetchOperation == operation { fetchOperation = nil; fetchTask = nil; isFetching = false }
        }
        do {
            let capture = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard self.session == session, fetchOperation == operation, credentialRevision == revision else { return }
            result = capture
            if capture.quoteEvidence == nil {
                fetchMessage = "响应已留存；报价为空或不满足参考价条件，未生成估值参考。"
            } else if !capture.dailyBarsComplete {
                fetchMessage = "已取得 IEX 参考报价；日线达到本次分页上限，仍为部分数据。"
            } else { fetchMessage = "已留存 IEX 报价与来源；仅供显式选择的当前捕获参考，不具备实时、PIT 或账本资格。" }
            hasFetchError = false
        } catch {
            guard self.session == session, fetchOperation == operation else { return }
            result = nil
            if error is CancellationError {
                fetchMessage = "本次读取已取消；取消前已提交的来源页可能保留。"; hasFetchError = false
            } else {
                fetchMessage = "本次行情读取未完成。请检查凭据、权利证据或连接后重试；已提交来源页可能保留。"; hasFetchError = true
                if error is EquityCredentialError || (error as? EquityResearchError) == .missingCredentials || (error as? EquityResearchError) == .staleCredentials || (error as? ProviderFailure) == .authInvalid {
                    credentialRevision = nil; presence = .unknown
                }
            }
        }
    }

    public func cancelFetch() {
        let wasFetching = isFetching
        fetchTask?.cancel(); fetchTask = nil; fetchOperation = nil; isFetching = false; result = nil
        if wasFetching, session != nil { fetchMessage = "本次读取已取消；取消前已提交的来源页可能保留。"; hasFetchError = false }
    }

    private func invalidateDraftConfirmation() { draftRevision = UUID(); confirmation = nil }
    private func credentialFailure(_ text: String) { credentialMessage = text; hasCredentialError = true }
}
