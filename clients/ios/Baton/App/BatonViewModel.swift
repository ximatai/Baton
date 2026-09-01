import Foundation
import Combine
import Security
import UIKit

/// Presentation state derived exclusively from standard Baton run/message events.
/// It intentionally exposes activity, not an agent's private reasoning content.
enum AgentActivity: Equatable {
    case idle
    case thinking
    case responding

    var message: String? {
        switch self {
        case .idle: nil
        case .thinking: String(localized: "智能体正在思考…")
        case .responding: String(localized: "智能体正在回复…")
        }
    }

    var symbolName: String {
        switch self {
        case .idle: ""
        case .thinking: "sparkles"
        case .responding: "text.line.first.and.arrowtriangle.forward"
        }
    }
}

/// Availability is deliberately an on-demand observation, not a background
/// presence signal. A list refresh reads each saved conversation once.
enum ConversationAvailability: Equatable {
    case checking
    case available
    case unavailable
}

private enum SessionAvailabilityProbe {
    /// This cursor is only a list observation; it never advances the user's
    /// read boundary.
    case available(EventCursor)
    case unavailable
    /// A response which proves that this locally held credential or
    /// conversation can no longer be used. Unlike a transport failure, it
    /// should not leave a dead entry in the saved-session list.
    case terminal
}

@MainActor
final class BatonViewModel: ObservableObject {
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var conversation: ConversationDescriptor?
    @Published var composerText = ""
    @Published private(set) var activeRunID: String?
    @Published private(set) var agentActivity: AgentActivity = .idle
    @Published private(set) var connectionStatus = String(localized: "尚未连接")
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var isWaitingForApproval = false
    @Published private(set) var pendingServiceName: String?
    @Published private(set) var pendingConversationTitle: String?
    @Published private(set) var pendingApprovalURL: URL?
    @Published private(set) var pendingApprovalMode: PairingApprovalMode?
    @Published private(set) var voiceState: SpeechInputService.State = .idle
    /// Pinned sessions first, then by most recent message interaction. Only
    /// the selected session owns an SSE connection; summaries intentionally
    /// contain no session credential.
    @Published private(set) var savedSessions: [ConversationSessionSummary] = []
    @Published private(set) var sessionAvailability: [String: ConversationAvailability] = [:]
    /// Failures from explicit list operations belong to the affected local
    /// action, not to the whole Conversation list or connection state.
    @Published private(set) var sessionActionError: String?
    /// The selected conversation's Keychain-backed outbox, with in-memory
    /// delivery state. No message content is duplicated outside Keychain.
    @Published private(set) var pendingOutbox: [OutboxItemPresentation] = []
    /// Owns the in-memory, authenticated media cache for the selected
    /// conversation. Views receive this narrow loader, never a credential.
    @Published private(set) var imageLoader: BatonImageLoader?

    private let api = BatonAPIClient()
    private let speechInput = SpeechInputService()
    private var credential: SessionCredential?
    /// Snapshot work is separate from SSE and must share its lifecycle: a
    /// suspended conversation cannot become read when an old response lands.
    private var snapshotTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var pairingPollTask: Task<Void, Never>?
    private var pendingPairing: PendingPairingCredential?
    private var reducer = ConversationEventReducer()
    private var lastPairingURL: String?
    private var shouldMaintainConnection = false
    private var reconnectAttempt = 0
    private var outboxRetryTask: Task<Void, Never>?
    private var mediaPrefetchTask: Task<Void, Never>?
    private var cacheRestoreTask: Task<Void, Never>?
    private var outboxStates: [String: OutboxDeliveryState] = [:]
    /// A persisted request may have one active delivery chain at most. This
    /// prevents an explicit retry and connection flush from POSTing together.
    private var outboxDeliveryRegistry = OutboxDeliveryRegistry()
    /// Retained until this End operation reaches a terminal local outcome, so
    /// an explicit retry after a lost response remains server-idempotent.
    private var endIdempotencyKey: UUID?
    private let deviceID: String
    private var cancellables = Set<AnyCancellable>()

    var canSend: Bool {
        credential != nil
            && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }
    var isComposerDisabled: Bool { isBusy }
    var isUnencryptedTransport: Bool {
        guard let endpoint = credential?.conversationEndpoint else { return false }
        return !BatonTransportPolicy.isEncrypted(endpoint)
    }
    var isAutoApprovedPairing: Bool { pendingApprovalMode == .auto }
    var activeSessionID: String? { credential?.conversationKey }
    var canEndActiveConversation: Bool { credential?.canEndConversation == true }
    var activeConversationTitle: String {
        guard let credential else { return conversation?.title ?? "Baton" }
        if let localTitle = savedSessions.first(where: { $0.id == credential.conversationKey })?.localTitle {
            return localTitle
        }
        return conversation?.title ?? credential.conversation.title
    }

    init() {
        let key = "baton.device-id"
        if let stored = UserDefaults.standard.string(forKey: key) { deviceID = stored }
        else { let newID = "ios_\(UUID().uuidString.lowercased())"; UserDefaults.standard.set(newID, forKey: key); deviceID = newID }

        speechInput.$state
            .receive(on: RunLoop.main)
            .assign(to: &$voiceState)
        speechInput.$transcript
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.composerText = $0 }
            .store(in: &cancellables)
    }

    func restoreSavedSessionIfPossible() {
        guard credential == nil else { return }
        do {
            let sessions = try KeychainStore.loadSessions()
            updateSavedSessions(sessions)
            if !sessions.isEmpty {
                // Cold launch stays on the list, but gives its availability
                // indicators real data without opening a long-lived stream.
                Task { [weak self] in await self?.refreshSessionAvailability() }
            } else if let pending = try KeychainStore.loadPending() {
                beginWaitingForApproval(pending)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func connectLocalDemo() {
        beginBusy(String(localized: "正在创建本地 Pairing…"))
        Task {
            do { let url = try await api.createLocalPairing(); await connect(url: url) }
            catch { failConnection(error) }
        }
    }

    func connect(pairingURL: String) {
        guard let url = URL(string: pairingURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { errorMessage = CompanionAPIError.invalidPairingURL.localizedDescription; return }
        beginBusy(String(localized: "正在发现服务…"))
        Task { await connect(url: url) }
    }

    private func connect(url: URL) async {
        do {
            lastPairingURL = url.absoluteString
            let document = try await api.discover(pairingURL: url)
            connectionStatus = String(format: String(localized: "正在请求加入 %@…"), locale: .current, document.service.name)
            let deviceProof = try makeDeviceProof()
            let request = try await api.join(document, deviceID: deviceID, deviceName: UIDevice.current.name, deviceProof: deviceProof)
            let pending = PendingPairingCredential(document: document, request: request, deviceID: deviceID, deviceProof: deviceProof)
            // Persist before polling: an app termination after browser approval must not
            // strand a proof-bound token that this device is entitled to claim.
            try KeychainStore.savePending(pending)
            beginWaitingForApproval(pending)
        } catch { failConnection(error) }
    }

    /// Cancels only the local wait. The server-side request remains harmless because
    /// it cannot be claimed without the proof that is deleted here.
    func cancelPendingPairing() {
        pairingPollTask?.cancel(); pairingPollTask = nil
        pendingPairing = nil; KeychainStore.deletePending()
        isWaitingForApproval = false; isBusy = false
        pendingServiceName = nil; pendingConversationTitle = nil; pendingApprovalURL = nil; pendingApprovalMode = nil
        lastPairingURL = nil
        if let credential {
            isConnected = true
            connectionStatus = "\(String(localized: "已连接")) · \(credential.service.name)"
            errorMessage = nil
        } else {
            isConnected = false
            connectionStatus = String(localized: "已取消等待网页确认")
            errorMessage = nil
        }
    }

    func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let credential else { return }
        let pending = PendingOutboxMessage(text: text, credential: credential)
        speechInput.discardTranscript()
        composerText = ""
        Task {
            do {
                try appendOutbox(pending)
                refreshOutboxPresentation(for: credential)
                errorMessage = nil
                await startDelivery(pending, using: credential)
            } catch {
                // The text has already left the composer by explicit user action;
                // do not let a failed persistence attempt make a sent transcript
                // reappear as if it were still unsent.
                errorMessage = "\(String(localized: "消息未能安全暂存，请重新输入。"))\n\(error.localizedDescription)"
            }
        }
    }

    /// Retries the exact persisted request. It never creates a new UUID or
    /// changes text: after an ambiguous network failure, either action could
    /// produce a second server-side message with different semantics.
    func retryOutboxMessage(id: String) {
        guard let credential else { return }
        Task {
            do {
                guard let pending = try KeychainStore.loadOutbox().first(where: {
                    $0.clientMessageID == id && $0.belongs(to: credential)
                }) else { return }
                guard outboxStates[id]?.canRetry ?? true else { return }
                errorMessage = nil
                await startDelivery(pending, using: credential)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Discard is local-only and requires an explicit UI confirmation. It does
    /// not attempt cancellation because the original request may already have
    /// reached the service.
    func discardOutboxMessage(id: String) {
        guard let credential else { return }
        do {
            let remaining = try KeychainStore.loadOutbox().filter {
                !($0.clientMessageID == id && $0.belongs(to: credential))
            }
            try KeychainStore.saveOutbox(remaining)
            outboxStates[id] = nil
            refreshOutboxPresentation(for: credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel(runID: String) {
        guard let credential else { return }
        Task {
            do { try await api.cancel(endpoint: credential.conversationEndpoint, token: credential.accessToken, runID: runID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func endConversation() {
        guard let credential, credential.canEndConversation else { return }
        let idempotencyKey = endIdempotencyKey ?? UUID()
        endIdempotencyKey = idempotencyKey
        Task {
            do {
                try await api.endConversation(endpoint: credential.conversationEndpoint, token: credential.accessToken, idempotencyKey: idempotencyKey)
                closeConversation(matching: credential)
            } catch {
                // The server may have ended the conversation but the original
                // response was lost. Its explicit terminal code is authoritative.
                if isConversationClosed(error) || isInvalidToken(error) {
                    closeConversation(matching: credential)
                }
                else { errorMessage = error.localizedDescription }
            }
        }
    }

    func reconnect() {
        guard credential != nil else { retryLastConnection(); return }
        shouldMaintainConnection = true
        refreshAndStream()
    }

    /// Stops live work when the user returns to the list. The credential and
    /// outbox stay in Keychain; opening the item will make a fresh snapshot and
    /// SSE connection instead of pretending the conversation is still live.
    func suspendActiveConversation() {
        guard credential != nil else { return }
        shouldMaintainConnection = false
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        imageLoader?.invalidate()
        activeRunID = nil
        agentActivity = .idle
        isBusy = false
        isConnected = false
        connectionStatus = String(localized: "已暂停")
        errorMessage = nil
    }

    func availability(for sessionID: String) -> ConversationAvailability? {
        sessionAvailability[sessionID]
    }

    /// A pull-to-refresh probe fetches one authenticated snapshot per saved
    /// conversation. It intentionally never opens SSE or starts an Agent run.
    func refreshSessionAvailability() async {
        let sessions: [StoredConversationSession]
        do {
            sessions = try KeychainStore.loadSessions()
            updateSavedSessions(sessions)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        for session in sessions {
            sessionAvailability[session.id] = .checking
        }
        await withTaskGroup(of: (StoredConversationSession, SessionAvailabilityProbe).self) { group in
            var remainingSessions = sessions.makeIterator()

            for _ in 0..<min(3, sessions.count) {
                guard let session = remainingSessions.next() else { break }
                group.addTask { [api] in
                    await Self.probeAvailability(of: session, api: api)
                }
            }

            while let (session, result) = await group.next() {
                applyAvailabilityProbe(result, for: session)
                if let session = remainingSessions.next() {
                    group.addTask { [api] in
                        await Self.probeAvailability(of: session, api: api)
                    }
                }
            }
        }
    }

    func refreshSessionAvailability(sessionID: String) async {
        do {
            guard let session = try KeychainStore.loadSessions().first(where: { $0.id == sessionID }) else { return }
            await refreshAvailability(of: session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectSavedSession(id: String) {
        sessionActionError = nil
        errorMessage = nil
        do {
            guard let session = try KeychainStore.loadSessions().first(where: { $0.id == id }) else { return }
            // This is a device-data operation first. A dead server must not
            // keep credentials, durable history, media, or outbox items on
            // the phone or keep the entry visible in its local list.
            guard removeSavedSessionLocally(session.credential) else {
                sessionActionError = errorMessage ?? String(localized: "本地会话清理失败")
                errorMessage = nil
                return
            }
            revokeRemoteSessionBestEffort(session.credential)
        } catch {
            sessionActionError = error.localizedDescription
        }
    }

    /// Future conversation switchers call this with a summary's id. Switching
    /// tears down only the previously active transport; all other credentials and
    /// queued messages remain isolated in Keychain.
    func activateSavedSession(id: String) {
        do {
            guard let session = try KeychainStore.loadSessions().first(where: { $0.id == id }) else {
                errorMessage = String(localized: "该会话已不在本机保存列表中。")
                return
            }
            if credential?.conversationKey == session.id {
                reconnect()
                return
            }
            activateSession(session.credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSavedSession(id: String, title: String) {
        sessionActionError = nil
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let session = try KeychainStore.loadSessions().first(where: { $0.id == id }) else { return }
            let localTitle = trimmed.isEmpty || trimmed == session.credential.conversation.title ? nil : trimmed
            updateSavedSessions(try KeychainStore.renameConversationLocally(conversationKey: id, title: localTitle))
        } catch {
            sessionActionError = error.localizedDescription
        }
    }

    func setSavedSessionPinned(id: String, pinned: Bool) {
        sessionActionError = nil
        do {
            updateSavedSessions(try KeychainStore.setConversationPinnedLocally(
                conversationKey: id,
                pinned: pinned
            ))
        } catch {
            sessionActionError = error.localizedDescription
        }
    }

    func dismissSessionActionError() {
        sessionActionError = nil
    }

    func retryLastConnection() {
        if let pendingPairing { beginWaitingForApproval(pendingPairing) }
        else if let lastPairingURL { connect(pairingURL: lastPairingURL) }
        else {
            connectionStatus = String(localized: "尚未连接")
            errorMessage = String(localized: "请重新扫描网页中的二维码。")
        }
    }

    func disconnect() {
        guard let credential else { cancelPendingPairing(); return }
        guard removeLocalSession(matching: credential) else { return }
        revokeRemoteSessionBestEffort(credential)
    }

    /// Remote revocation is deliberately best-effort. Once the user removes a
    /// Conversation from this device, no credential is retained for a retry.
    private func revokeRemoteSessionBestEffort(_ session: SessionCredential) {
        Task { [api] in
            _ = try? await api.revoke(
                endpoint: session.conversationEndpoint,
                token: session.accessToken,
                deviceID: session.deviceID,
                sessionID: session.sessionID
            )
        }
    }

    private func refreshAndStream(resetBackoff: Bool = true) {
        guard let credential else { return }
        if resetBackoff { reconnectAttempt = 0 }
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); isBusy = true; connectionStatus = String(localized: "正在同步会话…"); isConnected = false; errorMessage = nil
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard try await self.loadSnapshot(using: credential) else { return }
                self.startEventStream(using: credential)
            } catch { self.handleSessionFailure(error, for: credential) }
        }
    }

    private func loadSnapshot(using credential: SessionCredential) async throws -> Bool {
        let snapshot = try await api.snapshot(endpoint: credential.conversationEndpoint, token: credential.accessToken)
        guard acceptsActiveSnapshot(for: credential) else { return false }
        // A same-origin proxy must not be able to substitute a different
        // conversation for the credential selected by the user.
        guard credential.ownsConversation(id: snapshot.id) else {
            throw CompanionAPIError.invalidResponse
        }
        // These assignments are intentionally adjacent on MainActor: the event
        // cursor and message list describe the same server-side instant.
        guard reducer.replaceSnapshot(snapshot) else { throw CompanionAPIError.invalidResponse }
        // URLSession cancellation is cooperative. Check the ownership boundary
        // again immediately before mutable UI/Keychain state is touched.
        guard acceptsActiveSnapshot(for: credential) else { return false }
        messages = reducer.messages
        conversation = ConversationDescriptor(id: snapshot.id, title: snapshot.title, agentName: snapshot.agentName)
        restoreActiveRun(from: snapshot)
        // An accepted snapshot is the sole persistent read boundary. In
        // particular, availability probes and SSE delivery never reach here.
        updateSavedSessions(try KeychainStore.markConversationRead(
            credential: credential,
            cursor: snapshot.eventCursor
        ))
        persistActiveConversation()
        prefetchMedia(in: messages, using: credential)
        return true
    }

    private func acceptsActiveSnapshot(for candidate: SessionCredential) -> Bool {
        ConversationSessionSyncValidity.acceptsSnapshot(
            for: candidate,
            activeCredential: credential,
            maintainsConnection: shouldMaintainConnection,
            isTaskCancelled: Task.isCancelled
        )
    }

    private func startEventStream(using credential: SessionCredential) {
        guard acceptsActiveSnapshot(for: credential) else { return }
        streamTask?.cancel(); isBusy = false; isConnected = true; connectionStatus = "\(String(localized: "已连接")) · \(credential.service.name)"
        sessionAvailability[credential.conversationKey] = .available
        let startAfter = reducer.cursor?.id
        refreshOutboxPresentation(for: credential)
        outboxRetryTask?.cancel()
        outboxRetryTask = Task { [weak self] in await self?.flushOutbox(using: credential) }
        streamTask = Task { [weak self, api] in
            do {
                for try await event in api.events(endpoint: credential.conversationEndpoint, token: credential.accessToken, lastEventID: startAfter) {
                    guard !Task.isCancelled else { return }
                    if await self?.apply(event, for: credential) == true { return }
                }
                await self?.streamEnded(nil, for: credential)
            } catch { await self?.streamEnded(error, for: credential) }
        }
    }

    private func apply(_ event: BatonEvent, for credential: SessionCredential) async -> Bool {
        guard credential == self.credential else { return true }
        if event.type == "conversation.resync" {
            await resynchronize(using: credential)
            return true
        }
        if event.type == "message.created",
           let message = decodeMessage(event.data),
           !credential.ownsConversation(id: message.conversationID) {
            handleSessionFailure(CompanionAPIError.invalidResponse, for: credential)
            return true
        }
        let mustResync = reducer.apply(event)
        messages = reducer.messages
        if mustResync {
            await resynchronize(using: credential)
            return true
        }
        // A terminal event still has to prove continuity. A conflicting or
        // out-of-order close must resynchronize, never discard credentials.
        if event.type == "conversation.closed" {
            discardTerminatedActiveSession(detail: String(localized: "服务端已结束此对话。"), matching: credential)
            return true
        }
        switch event.type {
        case "message.created":
            recordConversationInteraction(for: credential)
            if let message = decodeMessage(event.data),
               let id = message.clientMessageID,
               let pending = try? KeychainStore.loadOutbox().first(where: {
                   $0.clientMessageID == id && $0.belongs(to: credential)
               }) {
                removeOutbox(pending, using: credential)
            }
        case "message.delta":
            if activeRunID != nil { agentActivity = .responding }
        case "message.failed":
            agentActivity = .idle
            errorMessage = event.data.object?["message"]?.string ?? "生成失败。"
        case "run.started":
            activeRunID = event.data.object?["run_id"]?.string
            agentActivity = .thinking
        case "run.completed", "run.cancelled":
            activeRunID = nil
            agentActivity = .idle
        default: break
        }
        // Streaming deltas are deliberately not written one character at a
        // time. A completed message or the next accepted server snapshot
        // persists the same source-of-truth result.
        if event.type != "message.delta" {
            persistActiveConversation()
            prefetchMedia(in: messages, using: credential)
        }
        return false
    }

    private func resynchronize(using credential: SessionCredential) async {
        do {
            guard credential == self.credential else { return }
            connectionStatus = String(localized: "正在重新同步会话…")
            guard try await loadSnapshot(using: credential) else { return }
            startEventStream(using: credential)
        } catch {
            handleSessionFailure(error, for: credential)
        }
    }

    private func restoreActiveRun(from snapshot: ConversationSnapshot) {
        guard let run = ActiveRun.current(in: snapshot.activeRuns) else {
            activeRunID = nil
            agentActivity = .idle
            return
        }
        activeRunID = run.id
        agentActivity = .thinking
    }

    private func merge(_ message: ConversationMessage) {
        reducer.mergeMessage(message)
        messages = reducer.messages
        if let credential { recordConversationInteraction(for: credential) }
        persistActiveConversation()
        if let credential { prefetchMedia(in: messages, using: credential) }
    }

    private func recordConversationInteraction(for credential: SessionCredential) {
        do {
            updateSavedSessions(try KeychainStore.recordConversationInteraction(credential: credential))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendOutbox(_ message: PendingOutboxMessage) throws {
        var outbox = try KeychainStore.loadOutbox()
        guard !outbox.contains(where: { $0.clientMessageID == message.clientMessageID }) else { return }
        outbox.append(message)
        try KeychainStore.saveOutbox(outbox)
    }

    private func removeOutbox(_ pending: PendingOutboxMessage, using credential: SessionCredential) {
        do {
            let remaining = try KeychainStore.loadOutbox().filter {
                !($0 == pending && $0.belongs(to: credential))
            }
            try KeychainStore.saveOutbox(remaining)
            outboxStates[pending.clientMessageID] = nil
            refreshOutboxPresentation(for: credential)
        } catch {
            // Retention is safe: retrying this same UUID is idempotent.
            errorMessage = error.localizedDescription
        }
    }

    private func deliver(_ pending: PendingOutboxMessage, using credential: SessionCredential, attemptsRemaining: Int) async {
        guard pending.belongs(to: credential), credential == self.credential else { return }
        do {
            guard try isOutboxMessagePersisted(pending, for: credential) else { return }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        setOutboxState(.sending, for: pending, credential: credential)
        do {
            guard let id = UUID(uuidString: pending.clientMessageID) else { throw CompanionAPIError.invalidResponse }
            let message = try await api.send(endpoint: credential.conversationEndpoint, token: credential.accessToken, text: pending.text, clientMessageID: id)
            // A request may finish after a session switch or local discard.
            // Neither may merge stale data into the selected conversation.
            guard credential == self.credential,
                  try isOutboxMessagePersisted(pending, for: credential) else { return }
            merge(message)
            removeOutbox(pending, using: credential)
        } catch {
            guard credential == self.credential else { return }
            do {
                guard try isOutboxMessagePersisted(pending, for: credential) else { return }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            if isConversationClosed(error) || isInvalidToken(error) {
                discardTerminatedActiveSession(error, matching: credential)
                return
            }
            let nextState = OutboxPresentation.stateAfterFailure(
                attemptsRemaining: attemptsRemaining,
                maintainsConnection: shouldMaintainConnection
            )
            setOutboxState(nextState, for: pending, credential: credential)
            guard nextState == .retrying else {
                errorMessage = "\(String(localized: "消息已安全暂存，将在下次连接时以原始请求重试。"))\n\(error.localizedDescription)"
                return
            }
            let delay = min(1 << max(4 - attemptsRemaining, 0), 8)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await deliver(pending, using: credential, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func flushOutbox(using credential: SessionCredential) async {
        do {
            for message in try KeychainStore.loadOutbox().filter({ $0.belongs(to: credential) }) {
                guard !Task.isCancelled else { return }
                await startDelivery(message, using: credential)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startDelivery(_ pending: PendingOutboxMessage, using credential: SessionCredential) async {
        guard outboxDeliveryRegistry.claim(pending) else { return }
        defer { outboxDeliveryRegistry.release(pending) }
        await deliver(pending, using: credential, attemptsRemaining: 3)
    }

    private func isOutboxMessagePersisted(
        _ pending: PendingOutboxMessage,
        for credential: SessionCredential
    ) throws -> Bool {
        OutboxPresentation.contains(pending, in: try KeychainStore.loadOutbox(), for: credential)
    }

    private func setOutboxState(
        _ state: OutboxDeliveryState,
        for pending: PendingOutboxMessage,
        credential: SessionCredential
    ) {
        guard pending.belongs(to: credential), credential == self.credential else { return }
        outboxStates[pending.clientMessageID] = state
        refreshOutboxPresentation(for: credential)
    }

    private func refreshOutboxPresentation(for credential: SessionCredential) {
        do {
            let messages = try KeychainStore.loadOutbox().filter { $0.belongs(to: credential) }
            let knownIDs = Set(messages.map(\.clientMessageID))
            outboxStates = outboxStates.filter { knownIDs.contains($0.key) }
            pendingOutbox = OutboxPresentation.items(from: messages, states: outboxStates)
        } catch {
            pendingOutbox = []
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func removeLocalSession(matching expectedCredential: SessionCredential? = nil) -> Bool {
        guard expectedCredential == nil || credential == expectedCredential else { return false }
        let removedCredential = credential
        shouldMaintainConnection = false
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        imageLoader?.invalidate()
        let persistenceError = removedCredential.flatMap { removePersistedSession($0) }
        guard persistenceError == nil else {
            // Do not present the device as disconnected while its Keychain
            // credential or its durable replica may still be present. The
            // user can retry the same explicit disconnect safely.
            connectionStatus = String(localized: "本地会话清理失败")
            errorMessage = persistenceError
            return false
        }
        credential = nil; conversation = nil; messages = []; reducer = ConversationEventReducer(); imageLoader = nil
        pendingOutbox = []; outboxStates = [:]
        activeRunID = nil; agentActivity = .idle; isConnected = false; isBusy = false; connectionStatus = String(localized: "尚未连接"); errorMessage = persistenceError
        endIdempotencyKey = nil
        return true
    }

    private func closeConversation(matching credential: SessionCredential? = nil) {
        guard removeLocalSession(matching: credential) else { return }
        connectionStatus = String(localized: "对话已结束")
    }

    private func isInvalidToken(_ error: Error) -> Bool {
        (error as? CompanionAPIError)?.invalidatesSessionCredential == true
    }

    private func isConversationClosed(_ error: Error) -> Bool {
        (error as? CompanionAPIError)?.closesConversation == true
    }

    private func handleSessionFailure(_ error: Error, for credential: SessionCredential) {
        guard credential == self.credential else { return }
        if isConversationClosed(error) || isInvalidToken(error) { discardTerminatedActiveSession(error, matching: credential) }
        else { failConnection(error) }
    }

    private func decodeMessage(_ value: JSONValue) -> ConversationMessage? {
        guard let message = value.object?["message"],
              JSONSerialization.isValidJSONObject(message.foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: message.foundationValue) else { return nil }
        return try? JSONDecoder().decode(ConversationMessage.self, from: data)
    }

    private func streamEnded(_ error: Error?, for credential: SessionCredential) async {
        guard credential == self.credential, shouldMaintainConnection, !Task.isCancelled else { return }
        if let error, isConversationClosed(error) || isInvalidToken(error) {
            discardTerminatedActiveSession(error, matching: credential)
            return
        }
        guard reconnectAttempt < 5 else {
            activeRunID = nil; agentActivity = .idle
            isConnected = false; connectionStatus = String(localized: "连接已中断"); if let error { errorMessage = error.localizedDescription }
            return
        }
        let delay = min(1 << reconnectAttempt, 16)
        reconnectAttempt += 1
        isConnected = false; connectionStatus = String(localized: "连接中断，正在重连…"); if let error { errorMessage = error.localizedDescription }
        try? await Task.sleep(for: .seconds(delay))
        guard shouldMaintainConnection else { return }
        refreshAndStream(resetBackoff: false)
    }

    private func beginBusy(_ text: String) { isBusy = true; errorMessage = nil; connectionStatus = text }
    private func failConnection(_ error: Error) { isBusy = false; isConnected = false; connectionStatus = String(localized: "连接失败"); errorMessage = error.localizedDescription }

    private func beginWaitingForApproval(_ pending: PendingPairingCredential) {
        pairingPollTask?.cancel()
        pendingPairing = pending
        isWaitingForApproval = true; isBusy = true; isConnected = false
        pendingServiceName = pending.document.service.name
        pendingConversationTitle = pending.document.conversation.title
        pendingApprovalURL = pending.document.endpoints.approval
        pendingApprovalMode = pending.document.approvalMode
        errorMessage = nil
        connectionStatus = pairingWaitStatus(for: pending.document)
        pairingPollTask = Task { [weak self, api] in
            await self?.pollUntilPairingResolved(pending, api: api)
        }
    }

    private func pollUntilPairingResolved(_ pending: PendingPairingCredential, api: BatonAPIClient) async {
        do {
            while !Task.isCancelled {
                let status = try await api.pairingStatus(pending.request, deviceProof: pending.deviceProof)
                switch status.status {
                case "pending":
                    let seconds = min(max(status.retryAfterSeconds ?? pending.request.retryAfterSeconds, 1), 10)
                    connectionStatus = pairingWaitStatus(for: pending.document)
                    try await Task.sleep(for: .seconds(seconds))
                case "approved":
                    guard let token = status.accessToken,
                          let issuedDeviceID = status.deviceID,
                          let issuedSessionID = status.sessionID,
                          let issuedConversation = status.conversation,
                          issuedDeviceID == pending.deviceID,
                          issuedConversation.id == pending.document.conversation.id else {
                        throw CompanionAPIError.invalidResponse
                    }
                    let newCredential = SessionCredential(
                        accessToken: token,
                        deviceID: issuedDeviceID,
                        sessionID: issuedSessionID,
                        service: pending.document.service,
                        conversation: issuedConversation,
                        conversationEndpoint: pending.document.endpoints.conversation,
                        canEndConversation: pending.document.capabilities.conversationEnd
                    )
                    // The only point at which a SessionCredential is written.
                    updateSavedSessions(try KeychainStore.upsertSession(newCredential))
                    KeychainStore.deletePending()
                    pendingPairing = nil; isWaitingForApproval = false
                    pendingServiceName = nil; pendingConversationTitle = nil; pendingApprovalURL = nil; pendingApprovalMode = nil
                    isBusy = false
                    activateSession(newCredential)
                    pairingPollTask = nil
                    return
                case "rejected":
                    clearPendingAfterTerminalResult(status: "网页拒绝了此设备的加入请求。")
                    return
                default:
                    throw CompanionAPIError.invalidResponse
                }
            }
        } catch is CancellationError {
            // Local cancellation deliberately keeps UI state untouched; the initiator
            // decides whether it is a retry (resume) or an explicit user cancellation.
        } catch {
            guard !Task.isCancelled else { return }
            if isTerminalPairingError(error) {
                clearPendingAfterTerminalResult(status: error.localizedDescription)
            } else {
                // Keep the proof in Keychain so a retry/relaunch can claim a later
                // approval after transient network failure.
                isBusy = false; isConnected = false
                connectionStatus = String(localized: "等待网页确认时连接中断")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearPendingAfterTerminalResult(status: String) {
        pairingPollTask?.cancel(); pairingPollTask = nil
        pendingPairing = nil; KeychainStore.deletePending()
        isWaitingForApproval = false; isBusy = false
        pendingServiceName = nil; pendingConversationTitle = nil; pendingApprovalURL = nil; pendingApprovalMode = nil
        lastPairingURL = nil
        if let credential {
            isConnected = true
            connectionStatus = "\(String(localized: "已连接")) · \(credential.service.name)"
            errorMessage = status
        } else {
            isConnected = false
            connectionStatus = status
            errorMessage = status
        }
    }

    private func isTerminalPairingError(_ error: Error) -> Bool {
        guard case let CompanionAPIError.server(status, code, _) = error else { return false }
        return status == 410 || code == "pairing_expired" || code == "invalid_device_proof" || code == "request_not_found"
    }

    private func pairingWaitStatus(for document: PairingDocument) -> String {
        switch document.approvalMode {
        case .manual: "等待网页确认 \(document.service.name) 的设备请求…"
        case .auto: "\(document.service.name) 正在自动接入此设备…"
        }
    }

    private func restoreCachedConversation(from store: ConversationLocalStore, using credential: SessionCredential) async {
        let cached = await Task.detached(priority: .userInitiated) {
            try? store.loadSnapshot(for: credential)
        }.value
        guard let cached else { return }
        let snapshot = ConversationSnapshot(
            id: cached.conversation.id,
            title: cached.conversation.title,
            agentName: cached.conversation.agentName,
            messages: cached.messages,
            eventCursor: cached.cursor
        )
        guard reducer.replaceSnapshot(snapshot) else { return }
        messages = reducer.messages
        conversation = cached.conversation
        activeRunID = nil
        agentActivity = .idle
    }

    private func persistActiveConversation() {
        guard let credential,
              let conversation,
              let cursor = reducer.cursor else { return }
        let store = ConversationLocalStore(credential: credential)
        let currentMessages = messages
        Task.detached(priority: .utility) {
            try? store.saveSnapshot(conversation: conversation, messages: currentMessages, cursor: cursor)
        }
    }

    private func prefetchMedia(in messages: [ConversationMessage], using credential: SessionCredential) {
        guard let imageLoader else { return }
        let images = Dictionary(
            messages.flatMap { $0.content.compactMap(\.image) }.map { ($0.mediaID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values
        guard !images.isEmpty else { return }
        mediaPrefetchTask?.cancel()
        mediaPrefetchTask = Task { [weak self, imageLoader] in
            for image in images {
                guard !Task.isCancelled, self?.credential == credential else { return }
                _ = try? await imageLoader.image(for: image)
            }
        }
    }

    private func makeDeviceProof() throws -> String {
        let byteCount = 32
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func beginVoiceInput() {
        guard !voiceState.isWorking else { return }
        speechInput.start(initialText: composerText)
    }

    func endVoiceInput() {
        guard voiceState.isWorking else { return }
        speechInput.stop()
    }

    func dismissVoiceIssue() { speechInput.dismissIssue() }

    private func activateSession(_ selectedCredential: SessionCredential) {
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        imageLoader?.invalidate()
        speechInput.discardTranscript()
        composerText = ""
        credential = selectedCredential
        pendingOutbox = []; outboxStates = [:]
        let localStore = ConversationLocalStore(credential: selectedCredential)
        imageLoader = BatonImageLoader(endpoint: selectedCredential.conversationEndpoint, token: selectedCredential.accessToken, localStore: localStore) { [weak self] in
            self?.discardTerminatedActiveSession(detail: String(localized: "媒体访问凭据已失效，请重新连接。"), matching: selectedCredential)
        }
        conversation = selectedCredential.conversation
        messages = []
        reducer = ConversationEventReducer()
        activeRunID = nil
        agentActivity = .idle
        isConnected = false
        isBusy = false
        shouldMaintainConnection = true
        reconnectAttempt = 0
        endIdempotencyKey = nil
        errorMessage = nil

        do {
            updateSavedSessions(try KeychainStore.upsertSession(selectedCredential))
            refreshOutboxPresentation(for: selectedCredential)
            cacheRestoreTask = Task { [weak self] in
                guard let self else { return }
                await self.restoreCachedConversation(from: localStore, using: selectedCredential)
                guard self.credential == selectedCredential, !Task.isCancelled else { return }
                self.refreshAndStream()
            }
        } catch {
            shouldMaintainConnection = false
            connectionStatus = String(localized: "会话恢复失败")
            errorMessage = error.localizedDescription
        }
    }

    private func updateSavedSessions(_ sessions: [StoredConversationSession]) {
        // KeychainStore returns ConversationSessionIndex's canonical order:
        // pinned items first, then each group by most recent activation.
        // Do not apply a second recency-only sort here or it would erase the
        // user's device-local pinning preference.
        savedSessions = sessions.map(ConversationSessionSummary.init)
        sessionAvailability = sessionAvailability.filter { key, _ in
            savedSessions.contains { $0.id == key }
        }
    }

    private func refreshAvailability(of session: StoredConversationSession) async {
        sessionAvailability[session.id] = .checking
        applyAvailabilityProbe(await Self.probeAvailability(of: session, api: api).1, for: session)
    }

    private static func probeAvailability(
        of session: StoredConversationSession,
        api: BatonAPIClient
    ) async -> (StoredConversationSession, SessionAvailabilityProbe) {
        do {
            let snapshot = try await api.snapshot(
                endpoint: session.credential.conversationEndpoint,
                token: session.credential.accessToken,
                timeout: 8
            )
            guard snapshot.id == session.credential.conversation.id else {
                return (session, .unavailable)
            }
            return (session, .available(snapshot.eventCursor))
        } catch {
            return (session, isTerminalSavedSessionError(error) ? .terminal : .unavailable)
        }
    }

    private func applyAvailabilityProbe(_ result: SessionAvailabilityProbe, for session: StoredConversationSession) {
        // Ignore a delayed probe after the same Conversation has been paired
        // again and its stored device session has been replaced.
        guard let current = try? KeychainStore.loadSessions().first(where: { $0.id == session.id }),
              current.credential == session.credential else { return }
        switch result {
        case let .available(cursor):
            sessionAvailability[session.id] = .available
            do {
                // A list probe may show newer server state, but it is not an
                // open/read action and therefore never changes sync time.
                updateSavedSessions(try KeychainStore.recordObservedConversationCursor(
                    credential: session.credential,
                    cursor: cursor
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
        case .unavailable:
            sessionAvailability[session.id] = .unavailable
        case .terminal:
            removeSavedSessionLocally(session.credential)
        }
    }

    @discardableResult
    private func removeSavedSessionLocally(_ session: SessionCredential) -> Bool {
        if credential?.conversationKey == session.conversationKey {
            return removeLocalSession(matching: session)
        }
        do {
            guard let saved = try KeychainStore.loadSessions().first(where: { $0.id == session.conversationKey }),
                  saved.credential == session else { return false }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if let error = removePersistedSession(session) {
            errorMessage = error
            return false
        }
        return true
    }

    private func removePersistedSession(_ session: SessionCredential) -> String? {
        do {
            guard let saved = try KeychainStore.loadSessions().first(where: { $0.id == session.conversationKey }) else { return nil }
            // The same Conversation can be paired again with a replacement
            // device session while an earlier request is still in flight.
            guard saved.credential == session else { return nil }
            try ConversationLocalStore(credential: session).invalidateAndRemoveAll()
            updateSavedSessions(try KeychainStore.removeConversation(conversationKey: session.conversationKey))
            let retainedOutbox = try KeychainStore.loadOutbox().filter { !$0.belongs(toConversationOf: session) }
            try KeychainStore.saveOutbox(retainedOutbox)
            return nil
        } catch {
            // Never claim that a device-only session was erased if Keychain
            // persistence failed; other saved conversations remain untouched.
            return error.localizedDescription
        }
    }

    private func handleSavedSessionOperationFailure(_ error: Error, session: SessionCredential) {
        if Self.isTerminalSavedSessionError(error) {
            removeSavedSessionLocally(session)
        } else {
            sessionAvailability[session.conversationKey] = .unavailable
            errorMessage = error.localizedDescription
        }
    }

    private func discardTerminatedActiveSession(_ error: Error, matching credential: SessionCredential) {
        discardTerminatedActiveSession(detail: error.localizedDescription, matching: credential)
    }

    private func discardTerminatedActiveSession(detail: String, matching credential: SessionCredential) {
        guard removeLocalSession(matching: credential) else { return }
        connectionStatus = String(localized: "会话已不可用")
        errorMessage = detail
    }

    private static func isTerminalSavedSessionError(_ error: Error) -> Bool {
        guard case let CompanionAPIError.server(status, code, _) = error else { return false }
        return status == 401 || status == 410 || code == "invalid_token" || code == "session_revoked" || code == "conversation_closed" || code == "conversation_not_found"
    }
}
