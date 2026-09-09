import Testing
@testable import Baton

@MainActor
struct PairingPresentationCoordinatorTests {
    @Test func completedPairingNavigatesOnlyOnceAfterTheDelay() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        #expect(!coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        #expect(coordinator.navigationSessionID == nil)

        let task = coordinator.completionTask
        await delay.release()
        await task?.value

        #expect(coordinator.navigationSessionID == "session-1")
        #expect(coordinator.pairingSheetDidDismiss() == "session-1")
        #expect(coordinator.pairingSheetDidDismiss() == nil)
    }

    @Test func cancelledOrRescannedPairingCannotUseAnOldDelay() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "old-session", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        let task = coordinator.completionTask
        coordinator.discardPairingFlow()
        coordinator.beginPairingFlow()

        await delay.release()
        await task?.value

        #expect(coordinator.completedSessionID == nil)
        #expect(coordinator.navigationSessionID == nil)
    }

    @Test func backgroundingDuringSuccessPreventsNavigation() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        let task = coordinator.completionTask
        #expect(coordinator.sceneActivityChanged(isActive: false, isBackground: true))

        await delay.release()
        await task?.value

        #expect(coordinator.completedSessionID == nil)
        #expect(coordinator.navigationSessionID == nil)
    }

    @Test func inactiveSuccessWaitsForActiveBeforeNavigating() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: false, sceneIsBackground: false))
        let task = coordinator.completionTask

        await delay.release()
        await task?.value

        #expect(coordinator.completedSessionID == "session-1")
        #expect(coordinator.navigationSessionID == nil)
        #expect(!coordinator.sceneActivityChanged(isActive: true, isBackground: false))
        #expect(coordinator.navigationSessionID == "session-1")
    }

    @Test func temporaryInactiveStatePreservesSuccessUntilActive() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        let task = coordinator.completionTask
        #expect(!coordinator.sceneActivityChanged(isActive: false, isBackground: false))

        await delay.release()
        await task?.value

        #expect(coordinator.completedSessionID == "session-1")
        #expect(coordinator.navigationSessionID == nil)
        #expect(!coordinator.sceneActivityChanged(isActive: true, isBackground: false))
        #expect(coordinator.navigationSessionID == "session-1")
    }

    @Test func releaseNotesWaitForPairingNavigationAndResumeAfterFailedPairingCancels() async {
        let delay = ControlledDelay()
        let coordinator = PairingPresentationCoordinator { await delay.wait() }
        let safeHome = ReleaseNotePresentationContext(
            sceneIsActive: true,
            isAtHome: true,
            isScannerPresented: false,
            isAboutPresented: false,
            isEndConfirmationPresented: false,
            isBusy: false,
            isWaitingForApproval: false
        )

        coordinator.beginPairingFlow()
        #expect(!coordinator.canPresentReleaseNotes(in: safeHome))
        coordinator.discardPairingFlow()
        #expect(coordinator.canPresentReleaseNotes(in: safeHome))

        coordinator.beginPairingFlow()
        #expect(coordinator.acceptCompletedPairing(sessionID: "session-1", isSheetPresented: true, sceneIsActive: true, sceneIsBackground: false))
        let task = coordinator.completionTask
        await delay.release()
        await task?.value

        #expect(!coordinator.canPresentReleaseNotes(in: safeHome))
        #expect(coordinator.pairingSheetDidDismiss() == "session-1")
        #expect(coordinator.canPresentReleaseNotes(in: safeHome))
    }

}

private actor ControlledDelay {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
