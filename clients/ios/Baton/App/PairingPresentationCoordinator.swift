import Combine
import Foundation

struct ReleaseNotePresentationContext {
    let sceneIsActive: Bool
    let isAtHome: Bool
    let isScannerPresented: Bool
    let isAboutPresented: Bool
    let isEndConfirmationPresented: Bool
    let isBusy: Bool
    let isWaitingForApproval: Bool
}

/// Owns only presentation timing around a successfully completed pairing.
/// Pairing itself remains entirely in `BatonViewModel`.
@MainActor
final class PairingPresentationCoordinator: ObservableObject {
    typealias CompletionDelay = @Sendable () async -> Void

    @Published private(set) var completedSessionID: String?
    @Published private(set) var navigationSessionID: String?

    private let completionDelay: CompletionDelay
    private(set) var completionTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var isPairingFlowActive = false
    private var isSceneActive = true
    private var completionDelayFinished = false

    init(completionDelay: @escaping CompletionDelay = PairingPresentationCoordinator.oneSecondDelay) {
        self.completionDelay = completionDelay
    }

    deinit {
        completionTask?.cancel()
    }

    var isPresentingCompletion: Bool {
        completedSessionID != nil
    }

    func beginPairingFlow() {
        discardPairingFlow()
        isPairingFlowActive = true
    }

    /// Returns true only when a server-published successful completion is accepted.
    @discardableResult
    func acceptCompletedPairing(
        sessionID: String,
        isSheetPresented: Bool,
        sceneIsActive: Bool,
        sceneIsBackground: Bool
    ) -> Bool {
        self.isSceneActive = sceneIsActive
        guard isPairingFlowActive,
              isSheetPresented,
              !sceneIsBackground,
              completedSessionID == nil,
              navigationSessionID == nil else { return false }

        let generation = UUID()
        completionGeneration = generation
        completedSessionID = sessionID
        completionDelayFinished = false
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            await completionDelay()
            guard !Task.isCancelled else { return }
            completionDelayFinished = true
            finishCompletion(sessionID: sessionID, generation: generation)
        }
        return true
    }

    /// Temporary interruptions preserve the success card. Entering the background
    /// clears it so an old completion can never navigate on a later foreground.
    @discardableResult
    func sceneActivityChanged(isActive: Bool, isBackground: Bool) -> Bool {
        isSceneActive = isActive
        if isBackground, completedSessionID != nil {
            discardPairingFlow()
            return true
        }
        if isActive,
           completionDelayFinished,
           let sessionID = completedSessionID {
            finishCompletion(sessionID: sessionID, generation: completionGeneration)
        }
        return false
    }

    func discardPairingFlow() {
        completionGeneration = UUID()
        completionTask?.cancel()
        completionTask = nil
        completedSessionID = nil
        navigationSessionID = nil
        isPairingFlowActive = false
        completionDelayFinished = false
    }

    /// Consumes the single navigation request after the pairing sheet has closed.
    func pairingSheetDidDismiss() -> String? {
        let sessionID = navigationSessionID
        discardPairingFlow()
        return sessionID
    }

    func canPresentReleaseNotes(in context: ReleaseNotePresentationContext) -> Bool {
        context.sceneIsActive &&
            context.isAtHome &&
            !context.isScannerPresented &&
            !context.isAboutPresented &&
            !context.isEndConfirmationPresented &&
            !context.isBusy &&
            !context.isWaitingForApproval &&
            !isPairingFlowActive &&
            completedSessionID == nil &&
            navigationSessionID == nil
    }

    private func finishCompletion(sessionID: String, generation: UUID) {
        guard completionGeneration == generation,
              completedSessionID == sessionID,
              navigationSessionID == nil else { return }
        completionTask = nil
        guard isSceneActive else { return }
        navigationSessionID = sessionID
    }

    private static func oneSecondDelay() async {
        try? await Task.sleep(for: .seconds(1))
    }
}
