import Foundation

/// One AppEnvironment coordinates only its own visible pages. SQLite revisions
/// remain the final cross-process write boundary; this is not a process lock.
@MainActor protocol OptionTransferParticipant: AnyObject {
    var optionTransferRefreshNeeded: Bool { get }
    func beginOptionTransfer(_ id: UUID)
    func refreshOptionTransfer(_ id: UUID) async
    func endOptionTransfer(_ id: UUID)
}
@MainActor public final class OptionTransferCoordinator {
    private final class Registration {
        weak var page: (any OptionTransferParticipant)?
        var token: UUID?
        init(_ page: any OptionTransferParticipant) { self.page = page }
    }
    private var registrations: [Registration] = []
    private var operation: UUID?
    var isTransferring: Bool { operation != nil }
    public nonisolated init() {}
    func register(_ page: any OptionTransferParticipant) {
        registrations.removeAll { $0.page == nil }
        guard !registrations.contains(where: { $0.page === page }) else { return }
        let registration = Registration(page)
        if let operation { registration.token = operation; page.beginOptionTransfer(operation) }
        registrations.append(registration)
    }
    func begin(excluding initiator: any OptionTransferParticipant) -> UUID? {
        guard operation == nil else { return nil }
        let id = UUID(); operation = id
        registrations.removeAll { $0.page == nil }
        for registration in registrations where registration.page !== initiator {
            registration.token = id; registration.page?.beginOptionTransfer(id)
        }
        return id
    }
    func finish(_ id: UUID) async {
        guard operation == id else { return }
        // Re-evaluate after every await: a page can register or reappear while
        // another participant is refreshing. No page releases the reservation early.
        while let registration = registrations.first(where: { $0.token == id && $0.page?.optionTransferRefreshNeeded == true }) {
            // Cleanup/refresh must finish even if the initiating view task was cancelled.
            if let page = registration.page { await Task { await page.refreshOptionTransfer(id) }.value }
        }
        for registration in registrations where registration.token == id {
            registration.page?.endOptionTransfer(id); registration.token = nil
        }
        operation = nil; registrations.removeAll { $0.page == nil }
    }
}
