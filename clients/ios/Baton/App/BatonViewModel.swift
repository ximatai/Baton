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
    case available
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
    /// Ordered by most recently activated. Only the selected session owns an SSE
    /// connection; summaries intentionally contain no session credential.
    @Published private(set) var savedSessions: [ConversationSessionSummary] = []
    @Published private(set) var sessionAvailability: [String: ConversationAvailability] = [:]
    /// The selected conversation's Keychain-backed outbox, with in-memory
    /// delivery state. No message content is duplicated outside Keychain.
    @Published private(set) var pendingOutbox: [OutboxItemPresentation] = []
    /// Owns the in-memory, authenticated media cache for the selected
    /// conversation. Views receive this narrow loader, never a credential.
    @Published private(set) var imageLoader: BatonImageLoader?

    private let api = BatonAPIClient()
    private let speechInput = SpeechInputService()
    private var credential: SessionCredential?
    private var streamTask: Task<Void, Never>?
    private var pairingPollTask: Task<Void, Never>?
    private var pendingPairing: PendingPairingCredential?
    private var reducer = ConversationEventReducer()
    private var lastPairingURL: String?
    private var shouldMaintainConnection = false
    private var reconnectAttempt = 0
    private var outboxRetryTask: Task<Void, Never>?
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
        guard let credential else { return }
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
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
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
        Task {
            var capturedCredential: SessionCredential?
            do {
                guard let session = try KeychainStore.loadSessions().first(where: { $0.id == id }) else { return }
                capturedCredential = session.credential
                sessionAvailability[id] = .checking
                try await api.revoke(
                    endpoint: session.credential.conversationEndpoint,
                    token: session.credential.accessToken,
                    deviceID: session.credential.deviceID,
                    sessionID: session.credential.sessionID
                )
                removeSavedSessionLocally(session.credential)
            } catch {
                // Disconnect means this device must stop retaining access even
                // when the server cannot be reached. The user is told that a
                // remote revocation could not be confirmed.
                if let capturedCredential, removeSavedSessionLocally(capturedCredential) {
                    errorMessage = String(localized: "未能通知服务端，已仅从本机断开；远端会话可能仍有效。")
                }
            }
        }
    }

    func endSavedSession(id: String) {
        Task {
            var capturedCredential: SessionCredential?
            do {
                guard let session = try KeychainStore.loadSessions().first(where: { $0.id == id }) else { return }
                capturedCredential = session.credential
                sessionAvailability[id] = .checking
                try await api.endConversation(
                    endpoint: session.credential.conversationEndpoint,
                    token: session.credential.accessToken,
                    idempotencyKey: UUID()
                )
                removeSavedSessionLocally(session.credential)
            } catch {
                if isConversationClosed(error) {
                    if let capturedCredential { removeSavedSessionLocally(capturedCredential) }
                } else {
                    if let capturedCredential { handleSavedSessionOperationFailure(error, session: capturedCredential) }
                }
            }
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
        shouldMaintainConnection = false; streamTask?.cancel(); streamTask = nil
        isConnected = false; connectionStatus = String(localized: "正在撤销服务器会话…"); errorMessage = nil
        Task {
            do {
                try await api.revoke(endpoint: credential.conversationEndpoint, token: credential.accessToken, deviceID: credential.deviceID, sessionID: credential.sessionID)
                removeLocalSession(matching: credential)
            } catch {
                if isConversationClosed(error) {
                    closeConversation(matching: credential)
                } else if isInvalidToken(error) {
                    // The user explicitly chose to disconnect this device. A
                    // server-side revocation that already happened has the
                    // same intended local result.
                    removeLocalSession(matching: credential)
                } else {
                    // The explicit user action still has a useful local
                    // meaning when a server cannot be reached: this device
                    // discards its credential and queued messages.
                    if removeLocalSession(matching: credential) {
                        connectionStatus = String(localized: "已仅从本机断开")
                        errorMessage = "\(String(localized: "未能通知服务端；远端会话可能仍有效。"))\n\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func refreshAndStream(resetBackoff: Bool = true) {
        guard let credential else { return }
        if resetBackoff { reconnectAttempt = 0 }
        streamTask?.cancel(); isBusy = true; connectionStatus = String(localized: "正在同步会话…"); isConnected = false; errorMessage = nil
        Task {
            do {
                guard try await loadSnapshot(using: credential) else { return }
                startEventStream(using: credential)
            } catch { handleSessionFailure(error, for: credential) }
        }
    }

    private func loadSnapshot(using credential: SessionCredential) async throws -> Bool {
        let snapshot = try await api.snapshot(endpoint: credential.conversationEndpoint, token: credential.accessToken)
        guard credential == self.credential else { return false }
        // A same-origin proxy must not be able to substitute a different
        // conversation for the credential selected by the user.
        guard credential.ownsConversation(id: snapshot.id) else {
            throw CompanionAPIError.invalidResponse
        }
        // These assignments are intentionally adjacent on MainActor: the event
        // cursor and message list describe the same server-side instant.
        guard reducer.replaceSnapshot(snapshot) else { throw CompanionAPIError.invalidResponse }
        messages = reducer.messages
        conversation = ConversationDescriptor(id: snapshot.id, title: snapshot.title, agentName: snapshot.agentName)
        restoreActiveRun(from: snapshot)
        return true
    }

    private func startEventStream(using credential: SessionCredential) {
        guard credential == self.credential else { return }
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
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
        let persistenceError = removedCredential.flatMap { removePersistedSession($0) }
        credential = nil; conversation = nil; messages = []; reducer = ConversationEventReducer(); imageLoader = nil
        pendingOutbox = []; outboxStates = [:]
        activeRunID = nil; agentActivity = .idle; isConnected = false; isBusy = false; connectionStatus = String(localized: "尚未连接"); errorMessage = persistenceError
        endIdempotencyKey = nil
        return persistenceError == nil
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
                        conversationEndpoint: pending.document.endpoints.conversation
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
        streamTask?.cancel(); streamTask = nil
        outboxRetryTask?.cancel(); outboxRetryTask = nil
        speechInput.discardTranscript()
        composerText = ""
        credential = selectedCredential
        pendingOutbox = []; outboxStates = [:]
        imageLoader = BatonImageLoader(endpoint: selectedCredential.conversationEndpoint, token: selectedCredential.accessToken) { [weak self] in
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
            refreshAndStream()
        } catch {
            shouldMaintainConnection = false
            connectionStatus = String(localized: "会话恢复失败")
            errorMessage = error.localizedDescription
        }
    }

    private func updateSavedSessions(_ sessions: [StoredConversationSession]) {
        savedSessions = sessions
            .sorted { $0.lastActivatedAt > $1.lastActivatedAt }
            .map(ConversationSessionSummary.init)
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
            _ = try await api.snapshot(
                endpoint: session.credential.conversationEndpoint,
                token: session.credential.accessToken,
                timeout: 8
            )
            return (session, .available)
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
        case .available:
            sessionAvailability[session.id] = .available
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
