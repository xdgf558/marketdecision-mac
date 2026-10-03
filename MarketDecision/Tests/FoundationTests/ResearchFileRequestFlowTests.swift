import Foundation
import Testing
import AppComposition

@Suite struct ResearchFileRequestFlowTests {
    @Test func cancellationWinsFailureInEitherCallbackOrder() throws {
        for cancelFirst in [true, false] {
            var flow = ResearchFileRequestFlow()
            let begun1 = flow.begin()
            let id = try #require(begun1)
            var displayed = "pending"
            if cancelFirst {
                if flow.receive(.cancelled, for: id) { displayed = "cancelled" }
                if flow.receive(.failed, for: id) { displayed = "permission failure" }
            } else {
                if flow.receive(.failed, for: id) { displayed = "permission failure" }
                if flow.receive(.cancelled, for: id) { displayed = "cancelled" }
            }
            #expect(displayed == "cancelled")
            #expect(!flow.isBusy)
            let result2 = flow.receive(.cancelled, for: id)
            #expect(!result2)
            let result3 = flow.receive(.failed, for: id)
            #expect(!result3)
            let result4 = flow.receive(.succeeded, for: id)
            #expect(!result4)
            let result5 = flow.selectFile(for: id)
            #expect(!result5)
        }
    }
    @Test func obsoletePanelCallbacksCannotCompleteNewRequestOrReopenAfterDismiss() throws {
        var flow = ResearchFileRequestFlow()
        let begun6 = flow.begin()
        let old = try #require(begun6)
        let result7 = flow.receive(.failed, for: old)
        #expect(result7)
        let begun8 = flow.begin()
        let fresh = try #require(begun8)
        let result9 = flow.receive(.cancelled, for: old)
        #expect(!result9)
        let result10 = flow.receive(.failed, for: old)
        #expect(!result10)
        flow.finish(for: old)
        #expect(flow.isPending(fresh))
        flow.dismiss()
        let result11 = flow.receive(.succeeded, for: fresh)
        #expect(!result11)
        let result12 = flow.receive(.cancelled, for: fresh)
        #expect(!result12)
        let result13 = flow.selectFile(for: fresh)
        #expect(!result13)
        #expect(!flow.isBusy)
    }
    @Test func importSelectionAndCleanupBelongToExactlyOneRequest() throws {
        var flow = ResearchFileRequestFlow()
        let begun14 = flow.begin()
        let id = try #require(begun14)
        let result15 = flow.begin()
        #expect(result15 == nil)
        let result16 = flow.selectFile(for: id)
        #expect(result16)
        let result17 = flow.selectFile(for: id)
        #expect(!result17)
        #expect(flow.isBusy)
        let result18 = flow.receive(.cancelled, for: id)
        #expect(result18)
        let begun19 = flow.begin()
        let fresh = try #require(begun19)
        flow.finish(for: id)
        #expect(flow.isPending(fresh))
        let result20 = flow.selectFile(for: fresh)
        #expect(result20)
        flow.finish(for: fresh)
        #expect(!flow.isBusy)
        let result21 = flow.selectFile(for: fresh)
        #expect(!result21)
    }
    @Test func successfulExportCannotBeRelabelledCancelledOrFailed() throws {
        var flow = ResearchFileRequestFlow()
        let begun22 = flow.begin()
        let id = try #require(begun22)
        let result23 = flow.receive(.succeeded, for: id)
        #expect(result23)
        let result24 = flow.receive(.failed, for: id)
        #expect(!result24)
        let result25 = flow.receive(.cancelled, for: id)
        #expect(!result25)
        let result26 = flow.receive(.succeeded, for: id)
        #expect(!result26)
        #expect(!flow.isBusy)
    }
}
