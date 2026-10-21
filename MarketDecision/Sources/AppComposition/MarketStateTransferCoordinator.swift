import Foundation

/// One AppEnvironment coordinates only its own visible pages. SQLite revisions
/// remain the final cross-process write boundary; this is not a process lock.
@MainActor protocol MarketStateTransferParticipant: AnyObject {
    var marketStateTransferRefreshNeeded: Bool { get }
    func beginMarketStateTransfer(_ id: UUID)
    func refreshMarketStateTransfer(_ id: UUID) async
    func endMarketStateTransfer(_ id: UUID)
}
@MainActor public final class MarketStateTransferCoordinator {
    private final class Registration {
        weak var page: (any MarketStateTransferParticipant)?
        var token: UUID?
        init(_ page: any MarketStateTransferParticipant) { self.page = page }
    }
    private var registrations: [Registration] = []
    private var operation: UUID?
    var isTransferring: Bool { operation != nil }
    public nonisolated init() {}
    func register(_ page: any MarketStateTransferParticipant) {
        registrations.removeAll { $0.page == nil }
        guard !registrations.contains(where: { $0.page === page }) else { return }
        let registration = Registration(page)
        if let operation { registration.token = operation; page.beginMarketStateTransfer(operation) }
        registrations.append(registration)
    }
    func begin(excluding initiator: any MarketStateTransferParticipant) -> UUID? {
        guard operation == nil else { return nil }
        let id = UUID(); operation = id
        registrations.removeAll { $0.page == nil }
        for registration in registrations where registration.page !== initiator {
            registration.token = id; registration.page?.beginMarketStateTransfer(id)
        }
        return id
    }
    func finish(_ id: UUID) async {
        guard operation == id else { return }
        // Re-evaluate after every await: a page can register or reappear while
        // another participant is refreshing. No page releases the reservation early.
        while let registration = registrations.first(where: { $0.token == id && $0.page?.marketStateTransferRefreshNeeded == true }) {
            // Cleanup/refresh must finish even if the initiating view task was cancelled.
            if let page = registration.page { await Task { await page.refreshMarketStateTransfer(id) }.value }
        }
        for registration in registrations where registration.token == id {
            registration.page?.endMarketStateTransfer(id); registration.token = nil
        }
        operation = nil; registrations.removeAll { $0.page == nil }
    }
}
