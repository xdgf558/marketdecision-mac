import Foundation

/// One AppEnvironment coordinates only its own visible pages. SQLite revisions
/// remain the final cross-process write boundary; this is not a process lock.
@MainActor protocol LedgerTransferParticipant: AnyObject {
    var ledgerTransferRefreshNeeded: Bool { get }
    func beginLedgerTransfer(_ id: UUID)
    func refreshLedgerTransfer(_ id: UUID) async
    func endLedgerTransfer(_ id: UUID)
}
@MainActor public final class LedgerTransferCoordinator {
    private final class Registration {
        weak var page: (any LedgerTransferParticipant)?
        var token: UUID?
        init(_ page: any LedgerTransferParticipant) { self.page = page }
    }
    private var registrations: [Registration] = []
    private var operation: UUID?
    var isTransferring: Bool { operation != nil }
    public nonisolated init() {}
    func register(_ page: any LedgerTransferParticipant) {
        registrations.removeAll { $0.page == nil }
        guard !registrations.contains(where: { $0.page === page }) else { return }
        let registration = Registration(page)
        if let operation { registration.token = operation; page.beginLedgerTransfer(operation) }
        registrations.append(registration)
    }
    func begin(excluding initiator: any LedgerTransferParticipant) -> UUID? {
        guard operation == nil else { return nil }
        let id = UUID(); operation = id
        registrations.removeAll { $0.page == nil }
        for registration in registrations where registration.page !== initiator {
            registration.token = id; registration.page?.beginLedgerTransfer(id)
        }
        return id
    }
    func finish(_ id: UUID) async {
        guard operation == id else { return }
        // Re-evaluate after every await: a page can register or reappear while
        // another participant is refreshing. No page releases the reservation early.
        while let registration = registrations.first(where: { $0.token == id && $0.page?.ledgerTransferRefreshNeeded == true }) {
            // Cleanup/refresh must finish even if the initiating view task was cancelled.
            if let page = registration.page { await Task { await page.refreshLedgerTransfer(id) }.value }
        }
        for registration in registrations where registration.token == id {
            registration.page?.endLedgerTransfer(id); registration.token = nil
        }
        operation = nil; registrations.removeAll { $0.page == nil }
    }
}
