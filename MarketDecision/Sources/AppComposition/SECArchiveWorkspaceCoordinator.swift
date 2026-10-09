import Foundation

/// Shared only by copies of one AppEnvironment. Pages retain their own selection
/// and replay state; this coordinates archive invalidation, not cross-process UI.
@MainActor public final class SECArchiveWorkspaceCoordinator {
    private final class Registration {
        weak var workspace: SECResearchWorkspaceModel?
        var token: UUID?
        var reloaded = false
        init(_ workspace: SECResearchWorkspaceModel) { self.workspace = workspace }
    }
    private var registrations: [Registration] = []
    private var operation: UUID?
    var isRestoring: Bool { operation != nil }

    public nonisolated init() {}

    func register(_ workspace: SECResearchWorkspaceModel) {
        registrations.removeAll { $0.workspace == nil }
        guard !registrations.contains(where: { $0.workspace === workspace }) else { return }
        let registration = Registration(workspace)
        // A page opened while another page commits or refreshes must join the
        // existing reservation before its first load/import action can run.
        if operation != nil { registration.token = workspace.beginArchiveRestore() }
        registrations.append(registration)
    }

    func begin() -> UUID? {
        registrations.removeAll { $0.workspace == nil }
        guard operation == nil,
              registrations.allSatisfy({ $0.workspace?.archiveRestoreInProgress != true }) else { return nil }
        let token = UUID(); operation = token
        for registration in registrations {
            registration.reloaded = false
            registration.token = registration.workspace?.beginArchiveRestore()
        }
        return token
    }

    func finish(_ token: UUID) async {
        guard operation == token else { return }
        // Re-read the registry after every suspension. Registration during a
        // previous page's refresh, and pages that leave then reappear during
        // another reload, participate in this same completion cycle.
        while let registration = registrations.first(where: {
            $0.token != nil && $0.workspace != nil
                && (!$0.reloaded || $0.workspace?.archiveRefreshNeeded == true)
        }) {
            registration.reloaded = true
            if let workspace = registration.workspace, let pageToken = registration.token {
                await workspace.finishArchiveRestore(pageToken, releaseReservation: false)
            }
        }
        // No page is released while another page is still loading. This final
        // synchronous pass cannot race registration or a new confirm action.
        for registration in registrations {
            if let pageToken = registration.token { registration.workspace?.endArchiveRestore(pageToken) }
            registration.token = nil
        }
        operation = nil
        registrations.removeAll { $0.workspace == nil }
    }
}
