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
        sceneIsActive: Bool
    ) -> Bool {
        self.isSceneActive = sceneIsActive
        guard isPairingFlowActive,
              isSheetPresented,
              sceneIsActive,
              completedSessionID == nil,
              navigationSessionID == nil else { return false }

        let generation = UUID()
        completionGeneration = generation
        completedSessionID = sessionID
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            await completionDelay()
            guard !Task.isCancelled else { return }
            finishCompletion(sessionID: sessionID, generation: generation)
        }
        return true
    }

    /// A successful card must never navigate after the app leaves the foreground.
    @discardableResult
    func sceneActivityChanged(isActive: Bool) -> Bool {
        isSceneActive = isActive
        guard !isActive, completedSessionID != nil else { return false }
        discardPairingFlow()
        return true
    }

    func discardPairingFlow() {
        completionGeneration = UUID()
        completionTask?.cancel()
        completionTask = nil
        completedSessionID = nil
        navigationSessionID = nil
        isPairingFlowActive = false
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
              navigationSessionID == nil,
              isSceneActive else { return }
        completionTask = nil
        navigationSessionID = sessionID
    }

    private static func oneSecondDelay() async {
        try? await Task.sleep(for: .seconds(1))
    }
}
