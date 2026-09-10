import Foundation
import Observation
import DataContracts
import SecuritySupport

/// Shared production state for the native workspace and Settings scene.
/// Preparation, quotes and credential settings receive the same closed-event log.
@MainActor @Observable public final class WorkspaceModel {
    public private(set) var credentials: CredentialSettingsModel?
    public private(set) var quote: Quote?
    public private(set) var isLoading = false
    public private(set) var isPreparing = false
    public private(set) var initializationError: String?
    public private(set) var message: String?
    private var environment: AppEnvironment?
    private let log: SafeLog
    private let prepareEnvironment: @Sendable (SafeLog) async throws -> AppEnvironment

    public init(log: SafeLog = SafeLog(),
                prepareEnvironment: @escaping @Sendable (SafeLog) async throws -> AppEnvironment = {
                    try await AppEnvironment.prepareLocal(log: $0)
                }) {
        self.log = log
        self.prepareEnvironment = prepareEnvironment
    }

    /// False means this invocation did not complete a refresh, including busy/cancelled calls.
    /// A prior quote never makes a failed invocation successful.
    @discardableResult public func refresh() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        message = nil
        defer { isLoading = false }
        if environment == nil {
            isPreparing = true
            initializationError = nil
            do {
                try Task.checkCancellation()
                let ready = try await prepareEnvironment(log)
                try Task.checkCancellation()
                environment = ready
                credentials = ready.makeCredentialSettings()
            } catch {
                // Cancellation is owned by this refresh task. A provider or factory may
                // use CancellationError as an ordinary failure without cancelling us.
                let cancelled = Task.isCancelled
                log.write(cancelled ? .localPreparationCancelled : .localPreparationFailed)
                initializationError = cancelled ? "初始化已取消，请重试。" : "本地数据暂时不可用，请重试。"
                message = initializationError
                isPreparing = false
                return false
            }
            isPreparing = false
        }
        guard let environment else { return false }
        do {
            try Task.checkCancellation()
            let received = try await environment.quotes.quote(for: "DEMO")
            // A provider may ignore cancellation. Never publish its late result.
            try Task.checkCancellation()
            quote = received
            message = "演示数据已刷新"
            return true
        } catch {
            quote = nil
            let cancelled = Task.isCancelled
            log.write(cancelled ? .providerRequestCancelled : .providerRequestFailed)
            message = cancelled ? "刷新已取消" : "演示数据暂时不可用，请重试。"
            return false
        }
    }
}
