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
    @Published private(set) var selectedImageCount = 0
    @Published private(set) var isImportingImages = false
    private let imageDrafts: ImageDraftCoordinator
    private var imageSendTask: Task<Void, Never>?
    private var imageSendGeneration = UUID()
    private var imageImportGeneration = UUID()
    private var imageImportCredential: SessionCredential?
    private var imageImportTask: Task<Void, Never>?
    @Published private(set) var imageSendProgress: String?
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
    @Published private(set) var isSendingMessage = false
    /// Pairing completion is an event, including rejoining the active conversation.
    @Published private(set) var completedPairingSessionID: String?
    /// Owns the in-memory, authenticated media cache for the selected
    /// conversation. Views receive this narrow loader, never a credential.
    @Published private(set) var imageLoader: BatonImageLoader?
    @Published private(set) var selectionStates: [String: SelectionInteractionState] = [:]

    private let api: BatonAPIClient
    private let speechInput = SpeechInputService()
    private var credential: SessionCredential?
    private var composerBeforeVoiceInput: String?
    private var acceptsSpeechTranscript = true
    /// Snapshot work is separate from SSE and must share its lifecycle: a
    /// suspended conversation cannot become read when an old response lands.
    private var snapshotTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var pairingConnectTask: Task<Void, Never>?
    private var pairingPollTask: Task<Void, Never>?
    private var pendingPairing: PendingPairingCredential?
    private var reducer = ConversationEventReducer()
    private var lastPairingURL: String?
    private var shouldMaintainConnection = false
    private var reconnectAttempt = 0
    /// This UUID exists only while the current in-memory draft remains
    /// unchanged. It lets an explicit retry after an ambiguous response reuse
    /// the protocol's idempotency key without a durable queue.
    private var draftMessageText: String?
    private var draftMessageIdentity: String?
    private var draftMessageID: UUID?
    private var pendingUnknownMessage: (credential: SessionCredential, content: [MessageContent], id: UUID)?
    @Published private(set) var isMessageOutcomeUnknown = false
    private var mediaPrefetchTask: Task<Void, Never>?
    private var cacheRestoreTask: Task<Void, Never>?
    /// A replica lease belongs to the active device session. Recreating this
    /// store for every snapshot would invalidate the media loader's lease and
    /// turn its persistent image cache into a permanent miss.
    private var activeConversationStore: ConversationLocalStore?
    /// Retained until this End operation reaches a terminal local outcome, so
    /// an explicit retry after a lost response remains server-idempotent.
    private var endIdempotencyKey: UUID?
    private var selectionDraft: (interactionID: String, optionID: String, clientMessageID: UUID)?
    /// Snapshot saves are sequenced so an older detached write cannot finish
    /// after a newer one and restore stale conversation state on relaunch.
    private var persistenceTask: Task<Void, Never>?
    private let deviceID: String
    private var cancellables = Set<AnyCancellable>()

    var canSend: Bool {
        isConnected
            && credential != nil
            && activeRequiredSelection == nil
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImageCount > 0)
            && !isBusy
            && !isImportingImages
            && !isSendingMessage && !isMessageOutcomeUnknown
    }
    var isComposerDisabled: Bool { !isConnected || isBusy || isImportingImages || isSendingMessage || isMessageOutcomeUnknown || activeRequiredSelection != nil }
    var isSelectionRequired: Bool { activeRequiredSelection != nil }
    var composerUnavailableMessage: String? {
        guard credential != nil else { return String(localized: "此对话已不可用") }
        if activeRequiredSelection != nil { return String(localized: "请先完成选择") }
        guard !isConnected else { return nil }
        return isBusy
            ? String(localized: "正在连接，暂不能发送消息")
            : String(localized: "当前离线，暂不能发送消息")
    }
    var composerUnavailableSymbolName: String {
        guard credential != nil else { return "exclamationmark.circle" }
        if activeRequiredSelection != nil { return "checklist" }
        return "wifi.slash"
    }
    var isUnencryptedTransport: Bool {
        guard let endpoint = credential?.conversationEndpoint else { return false }
        return !BatonTransportPolicy.isEncrypted(endpoint)
    }

    var imageUploadLimit: Int { credential?.imageUploadPolicy?.maxItemsPerMessage ?? 0 }
    var selectedImageDrafts: [ImageDraftCoordinator.Draft] { imageDrafts.drafts }
    func selectedImageData(_ draft: ImageDraftCoordinator.Draft) -> Data? { try? imageDrafts.data(for: draft) }

    func removeSelectedPhotos(force: Bool = false) {
        guard force || (!isSendingMessage && !isMessageOutcomeUnknown) else { return }
        imageDrafts.clear()
        selectedImageCount = 0
        draftMessageIdentity = nil
    }

    func removeSelectedPhoto(id: UUID) {
        guard !isSendingMessage, !isImportingImages, !isMessageOutcomeUnknown else { return }
        imageDrafts.remove(id: id)
        selectedImageCount = imageDrafts.drafts.count
        draftMessageIdentity = nil
    }

    /// Starts a picker import lease. Results from a dismissed picker are
    /// ignored after this conversation changes or is suspended.
    func beginPhotoImport() -> UUID {
        guard !isMessageOutcomeUnknown else { return imageImportGeneration }
        imageImportTask?.cancel()
        imageImportGeneration = UUID()
        imageImportCredential = credential
        isImportingImages = true
        return imageImportGeneration
    }

    func acceptSelectedPhotos(_ data: [Data], lease: UUID) {
        guard lease == imageImportGeneration,
              imageImportCredential == credential,
              !Task.isCancelled,
              let policy = credential?.imageUploadPolicy,
              !isSendingMessage,
              !isMessageOutcomeUnknown else { return }
        guard !data.isEmpty else { isImportingImages = false; return }
        imageImportTask = Task.detached { [weak self, data, policy] in
            let normalized = Result { try ImageDraftCoordinator.normalizeImages(data, policy: policy) }
            await MainActor.run {
                guard let self, lease == self.imageImportGeneration, self.imageImportCredential == self.credential else { return }
                self.isImportingImages = false
                self.imageImportTask = nil
                do {
                    try self.imageDrafts.importNormalized(try normalized.get())
                    self.selectedImageCount = self.imageDrafts.drafts.count
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
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

    private var activeRequiredSelection: MessageSelection? {
        messages
            .lazy
            .flatMap(\.content)
            .compactMap(\.selection)
            .first { selection in
                selection.inputPolicy == .selectionRequired
                    && selectionStates[selection.interactionID]?.status == .open
            }
    }

    init(api: BatonAPIClient = BatonAPIClient(), imageDrafts: ImageDraftCoordinator? = nil) {
        self.api = api
        self.imageDrafts = imageDrafts ?? ImageDraftCoordinator()
        KeychainStore.deleteRetiredOutbox()
        let key = "baton.device-id"
        if let stored = UserDefaults.standard.string(forKey: key) { deviceID = stored }
        else { let newID = "ios_\(UUID().uuidString.lowercased())"; UserDefaults.standard.set(newID, forKey: key); deviceID = newID }

        speechInput.$state
            .receive(on: RunLoop.main)
            .assign(to: &$voiceState)
        speechInput.$transcript
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.acceptsSpeechTranscript else { return }
                self.composerText = $0
            }
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
        pairingConnectTask?.cancel()
        completedPairingSessionID = nil
        beginBusy(String(localized: "正在创建本地 Pairing…"))
        pairingConnectTask = Task { [weak self, api] in
            do {
                let url = try await api.createLocalPairing()
                try Task.checkCancellation()
                await self?.connect(url: url)
            } catch is CancellationError {
                return
            } catch {
                self?.failConnection(error)
            }
            self?.pairingConnectTask = nil
        }
    }

    func connect(pairingURL: String) {
        guard let url = URL(string: pairingURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { errorMessage = CompanionAPIError.invalidPairingURL.localizedDescription; return }
        pairingConnectTask?.cancel()
        completedPairingSessionID = nil
        beginBusy(String(localized: "正在发现服务…"))
        pairingConnectTask = Task { [weak self] in
            await self?.connect(url: url)
            guard !Task.isCancelled else { return }
            self?.pairingConnectTask = nil
        }
    }

    private func connect(url: URL) async {
        do {
            lastPairingURL = url.absoluteString
            let document = try await api.discover(pairingURL: url)
            try Task.checkCancellation()
            connectionStatus = String(format: String(localized: "正在请求加入 %@…"), locale: .current, document.service.name)
            let deviceProof = try makeDeviceProof()
            let request = try await api.join(document, deviceID: deviceID, deviceName: UIDevice.current.name, deviceProof: deviceProof)
            try Task.checkCancellation()
            let pending = PendingPairingCredential(document: document, request: request, deviceID: deviceID, deviceProof: deviceProof)
            // Persist before polling: an app termination after browser approval must not
            // strand a proof-bound token that this device is entitled to claim.
            try KeychainStore.savePending(pending)
            beginWaitingForApproval(pending)
        } catch is CancellationError {
            // Explicit cancellation must not turn into a visible connection failure.
        } catch { failConnection(error) }
    }

    /// Cancels only the local wait. The server-side request remains harmless because
    /// it cannot be claimed without the proof that is deleted here.
    func cancelPendingPairing() {
        pairingConnectTask?.cancel(); pairingConnectTask = nil
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
        if isMessageOutcomeUnknown { retryUnknownMessage(); return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let credential else { return }
        let frozenDrafts = imageDrafts.drafts
        let identity = text + "\u{1F}" + frozenDrafts.map(\.id.uuidString).joined(separator: ",")
        if draftMessageText != text || draftMessageIdentity != identity {
            draftMessageText = text
            draftMessageIdentity = identity
            draftMessageID = UUID()
        }
        guard let clientMessageID = draftMessageID else { return }
        isSendingMessage = true
        imageSendGeneration = UUID()
        let sendGeneration = imageSendGeneration
        acceptsSpeechTranscript = false
        speechInput.discardTranscript()
        imageSendProgress = frozenDrafts.isEmpty ? String(localized: "正在发送消息…") : String(localized: "正在上传图片…")
        imageSendTask = Task { [weak self, api] in
            var submittedContent: [MessageContent] = []
            defer {
                if self?.credential == credential, self?.imageSendGeneration == sendGeneration {
                    self?.isSendingMessage = false
                    self?.imageSendTask = nil
                    self?.imageSendProgress = nil
                }
            }
            do {
                guard let self else { return }
                guard !Task.isCancelled, self.credential == credential, self.imageSendGeneration == sendGeneration else { return }
                var expiryRetries = 0
                let message: ConversationMessage
                while true {
                    var content: [MessageContent] = text.isEmpty ? [] : [.text(text)]
                    do {
                        if !frozenDrafts.isEmpty {
                            guard let policy = credential.imageUploadPolicy else { throw CompanionAPIError.invalidResponse }
                            for (index, initialDraft) in frozenDrafts.enumerated() {
                                try Task.checkCancellation()
                                guard self.acceptsImageSend(credential, generation: sendGeneration) else { return }
                                guard let draft = self.imageDrafts.draft(id: initialDraft.id) else { return }
                                self.imageSendProgress = String(format: String(localized: "正在上传图片 %d/%d…"), index + 1, frozenDrafts.count)
                                if let mediaID = draft.stagedMediaID { content.append(.imageReference(mediaID)); continue }
                                let bytes = try self.imageDrafts.data(for: draft)
                                let staged = try await api.uploadImage(endpoint: credential.conversationEndpoint, token: credential.accessToken, data: bytes, mimeType: draft.mimeType, idempotencyKey: draft.uploadID)
                                guard self.acceptsImageSend(credential, generation: sendGeneration) else { return }
                                guard staged.byteSize <= policy.maxBytesPerItem, staged.width * staged.height <= policy.maxPixelsPerItem, policy.mimeTypes.contains(staged.mimeType) else { throw CompanionAPIError.invalidResponse }
                                self.imageDrafts.markStaged(staged.mediaID, for: draft.id)
                                content.append(.imageReference(staged.mediaID))
                            }
                        }
                        guard self.acceptsImageSend(credential, generation: sendGeneration) else { return }
                        self.imageSendProgress = String(localized: "正在发送消息…")
                        submittedContent = content
                        // Retain the immutable commit before starting I/O. A
                        // cancellation can race a request that reached the
                        // server, so it cannot make this draft editable again.
                        self.pendingUnknownMessage = (credential, content, clientMessageID)
                        message = try await api.send(endpoint: credential.conversationEndpoint, token: credential.accessToken, content: content, clientMessageID: clientMessageID)
                        guard self.acceptsImageSend(credential, generation: sendGeneration) else { return }
                        break
                    } catch CompanionAPIError.server(let status, let code, _) where status == 410 && code == "media_expired" && expiryRetries == 0 {
                        // A 410 is the server's explicit proof that no staged ref
                        // was usable. Rebuild refs from the retained files while
                        // preserving this message UUID; never do this for an
                        // uncertain network/send outcome.
                        expiryRetries += 1
                        guard self.acceptsImageSend(credential, generation: sendGeneration) else { return }
                        // The explicit 410 proves this particular commit did
                        // not succeed. Do not let a later upload failure turn
                        // its obsolete refs into an "unknown" message.
                        submittedContent = []
                        self.pendingUnknownMessage = nil
                        self.imageDrafts.resetUploads()
                        continue
                    }
                }
                guard !Task.isCancelled, self.credential == credential, self.imageSendGeneration == sendGeneration else { return }
                self.merge(message)
                self.composerText = ""
                self.draftMessageText = nil
                self.draftMessageIdentity = nil
                self.draftMessageID = nil
                self.pendingUnknownMessage = nil
                self.isMessageOutcomeUnknown = false
                self.removeSelectedPhotos(force: true)
                self.errorMessage = nil
            } catch {
                guard let self else { return }
                guard self.credential == credential, self.imageSendGeneration == sendGeneration else { return }
                if self.isConversationClosed(error) || self.isInvalidToken(error) {
                    self.discardTerminatedActiveSession(error, matching: credential)
                } else if !submittedContent.isEmpty && (Task.isCancelled || self.isUnknownMessageOutcome(error)) {
                    // The service may have committed this exact request. Keep
                    // immutable content and UUID until the user confirms it.
                    self.pendingUnknownMessage = (credential, submittedContent, clientMessageID)
                    self.isMessageOutcomeUnknown = true
                    self.errorMessage = String(localized: "发送结果未确认。请重试确认发送结果。")
                } else if !Task.isCancelled, self.imageSendGeneration == sendGeneration {
                    // A protocol-level 4xx is a definitive non-commit, so a
                    // later explicit send must begin from a fresh local state.
                    self.pendingUnknownMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func retryUnknownMessage() {
        guard isConnected,
              let pending = pendingUnknownMessage,
              pending.credential == credential,
              !isSendingMessage else { return }
        isSendingMessage = true
        imageSendGeneration = UUID()
        let sendGeneration = imageSendGeneration
        imageSendProgress = String(localized: "正在发送消息…")
        imageSendTask = Task { [weak self, api] in
            defer {
                if self?.credential == pending.credential, self?.imageSendGeneration == sendGeneration {
                    self?.isSendingMessage = false; self?.imageSendTask = nil; self?.imageSendProgress = nil
                }
            }
            do {
                let message = try await api.send(endpoint: pending.credential.conversationEndpoint, token: pending.credential.accessToken, content: pending.content, clientMessageID: pending.id)
                guard self?.acceptsImageSend(pending.credential, generation: sendGeneration) == true else { return }
                self?.merge(message); self?.composerText = ""; self?.draftMessageText = nil; self?.draftMessageIdentity = nil; self?.draftMessageID = nil
                self?.pendingUnknownMessage = nil; self?.isMessageOutcomeUnknown = false; self?.removeSelectedPhotos(force: true); self?.errorMessage = nil
            } catch {
                guard let self,
                      self.credential == pending.credential,
                      self.imageSendGeneration == sendGeneration else { return }
                if self.isConversationClosed(error) || self.isInvalidToken(error) {
                    self.discardTerminatedActiveSession(error, matching: pending.credential)
                } else if case CompanionAPIError.server(let status, let code, _) = error,
                          status == 410, code == "media_expired",
                          self.acceptsImageSend(pending.credential, generation: sendGeneration) {
                    self.imageDrafts.resetUploads()
                    self.pendingUnknownMessage = nil
                    self.isMessageOutcomeUnknown = false
                    self.isSendingMessage = false
                    self.imageSendTask = nil
                    self.imageSendProgress = nil
                    // send() retains draftMessageID, so the regenerated refs
                    // are submitted with the original client_message_id.
                    self.send()
                } else if !Task.isCancelled, self.acceptsImageSend(pending.credential, generation: sendGeneration) {
                    if self.isUnknownMessageOutcome(error) {
                        self.errorMessage = String(localized: "发送结果未确认。请重试确认发送结果。")
                    } else {
                        // A contract-level 4xx is a definite non-commit.
                        self.pendingUnknownMessage = nil
                        self.isMessageOutcomeUnknown = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func isUnknownMessageOutcome(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let error = error as? CompanionAPIError, case let .server(status, _, _) = error { return status >= 500 }
        return true
    }

    /// This cancels only local media work. It never calls runs/:cancel because
    /// a message request that already reached the service remains service fact.
    func cancelImageSend() {
        guard isSendingMessage else { return }
        if let pending = pendingUnknownMessage, pending.credential == credential {
            // The commit has already begun.  Preserve it synchronously so the
            // user cannot create a second message before cancellation reaches
            // URLSession and its task's catch block.
            isMessageOutcomeUnknown = true
            errorMessage = String(localized: "发送结果未确认。请重试确认发送结果。")
        }
        imageSendGeneration = UUID()
        imageSendTask?.cancel()
        imageSendTask = nil
        isSendingMessage = false
        imageSendProgress = nil
    }

    private func acceptsImageSend(_ expectedCredential: SessionCredential, generation: UUID) -> Bool {
        !Task.isCancelled && credential == expectedCredential && imageSendGeneration == generation
    }

    func select(_ selection: MessageSelection, option: MessageSelectionOption) {
        guard isConnected,
              credential != nil,
              !isBusy,
              !isMessageOutcomeUnknown,
              !isSendingMessage,
              selectionStates[selection.interactionID]?.status == .open,
              selection.options.contains(where: { $0.id == option.id }) else { return }
        let clientMessageID: UUID
        if let selectionDraft,
           selectionDraft.interactionID == selection.interactionID,
           selectionDraft.optionID == option.id {
            clientMessageID = selectionDraft.clientMessageID
        } else {
            clientMessageID = UUID()
            selectionDraft = (selection.interactionID, option.id, clientMessageID)
        }
        guard let credential else { return }
        isSendingMessage = true
        Task { [weak self, api] in
            defer {
                if self?.credential == credential {
                    self?.isSendingMessage = false
                }
            }
            do {
                let message = try await api.sendSelection(
                    endpoint: credential.conversationEndpoint,
                    token: credential.accessToken,
                    interactionID: selection.interactionID,
                    optionID: option.id,
                    clientMessageID: clientMessageID
                )
                guard self?.credential == credential else { return }
                self?.resolveSelectionLocally(interactionID: selection.interactionID, optionID: option.id)
                self?.merge(message)
                self?.selectionDraft = nil
                self?.errorMessage = nil
            } catch {
                guard self?.credential == credential, let self else { return }
                if self.isConversationClosed(error) || self.isInvalidToken(error) {
                    self.discardTerminatedActiveSession(error, matching: credential)
                } else if case let CompanionAPIError.server(_, code, _) = error, code == "selection_resolved" {
                    self.reconnect()
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
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

    /// Stops live work when the user returns to the list. Opening the item
    /// makes a fresh snapshot and SSE connection instead of pretending the
    /// conversation is still live.
    func suspendActiveConversation() {
        guard credential != nil else { return }
        cancelVoiceInput()
        // A paused scene may not keep uploading or turn a late upload into a
        // new server message. The retained draft is retried only by a later
        // explicit Send action.
        cancelImageSend()
        imageImportGeneration = UUID()
        imageImportCredential = nil
        imageImportTask?.cancel(); imageImportTask = nil
        isImportingImages = false
        shouldMaintainConnection = false
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        // Returning to the list is not a credential boundary. Preserve the
        // selected session's decoded media so reopening the same conversation
        // cannot inherit a cancelled load as a visible failure.
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
            // keep credentials, durable history, or media on the phone or
            // keep the entry visible in its local list.
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

    // Internal test seam: production still reaches this path only after
    // Keychain-backed pairing/session activation.
    func activateForTesting(_ credential: SessionCredential) {
        if let current = self.credential, current != credential {
            imageSendGeneration = UUID()
            imageSendTask?.cancel(); imageSendTask = nil
            isSendingMessage = false
            imageSendProgress = nil
            clearMessageDraftForDifferentSession()
        }
        self.credential = credential
        isConnected = true
        isBusy = false
        connectionStatus = "test"
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
        selectionStates = reducer.selectionStates
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
        selectionStates = reducer.selectionStates
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

    private func resolveSelectionLocally(interactionID: String, optionID: String) {
        guard reducer.resolveSelectionLocally(interactionID: interactionID, optionID: optionID) else { return }
        selectionStates = reducer.selectionStates
    }

    private func recordConversationInteraction(for credential: SessionCredential) {
        do {
            updateSavedSessions(try KeychainStore.recordConversationInteraction(credential: credential))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func removeLocalSession(matching expectedCredential: SessionCredential? = nil) -> Bool {
        guard expectedCredential == nil || credential == expectedCredential else { return false }
        let removedCredential = credential
        cancelVoiceInput()
        shouldMaintainConnection = false
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        persistenceTask?.cancel(); persistenceTask = nil
        imageSendGeneration = UUID(); imageSendTask?.cancel(); imageSendTask = nil
        removeSelectedPhotos(force: true)
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
        credential = nil; conversation = nil; messages = []; selectionStates = [:]; reducer = ConversationEventReducer(); imageLoader = nil; activeConversationStore = nil
        isSendingMessage = false
        draftMessageText = nil; draftMessageIdentity = nil; draftMessageID = nil
        pendingUnknownMessage = nil; isMessageOutcomeUnknown = false
        selectionDraft = nil
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
            cancelVoiceInput()
            isConnected = false; connectionStatus = String(localized: "连接已中断"); if let error { errorMessage = error.localizedDescription }
            return
        }
        let delay = min(1 << reconnectAttempt, 16)
        reconnectAttempt += 1
        cancelVoiceInput()
        isConnected = false; connectionStatus = String(localized: "连接中断，正在重连…"); if let error { errorMessage = error.localizedDescription }
        try? await Task.sleep(for: .seconds(delay))
        guard shouldMaintainConnection else { return }
        refreshAndStream(resetBackoff: false)
    }

    private func beginBusy(_ text: String) { isBusy = true; errorMessage = nil; connectionStatus = text }
    private func failConnection(_ error: Error) {
        cancelVoiceInput()
        isBusy = false
        isConnected = false
        connectionStatus = String(localized: "连接失败")
        errorMessage = error.localizedDescription
    }

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
                        canEndConversation: pending.document.capabilities.conversationEnd,
                        imageUploadPolicy: pending.document.imageUploadPolicy
                    )
                    // The only point at which a SessionCredential is written.
                    updateSavedSessions(try KeychainStore.upsertSession(newCredential))
                    KeychainStore.deletePending()
                    pendingPairing = nil; isWaitingForApproval = false
                    pendingServiceName = nil; pendingConversationTitle = nil; pendingApprovalURL = nil; pendingApprovalMode = nil
                    isBusy = false
                    activateSession(newCredential)
                    completedPairingSessionID = newCredential.conversationKey
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
            eventCursor: cached.cursor,
            selectionStates: cached.selectionStates
        )
        guard reducer.replaceSnapshot(snapshot) else { return }
        messages = reducer.messages
        selectionStates = reducer.selectionStates
        conversation = cached.conversation
        activeRunID = nil
        agentActivity = .idle
    }

    private func persistActiveConversation() {
        guard credential != nil,
              let conversation,
              let cursor = reducer.cursor,
              let store = activeConversationStore else { return }
        let currentMessages = messages
        let currentSelectionStates = Array(selectionStates.values)
        persistenceTask?.cancel()
        let previousTask = persistenceTask
        persistenceTask = Task {
            _ = await previousTask?.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                try? store.saveSnapshot(
                    conversation: conversation,
                    messages: currentMessages,
                    cursor: cursor,
                    selectionStates: currentSelectionStates
                )
            }.value
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
        guard !isComposerDisabled, !voiceState.isWorking else { return }
        acceptsSpeechTranscript = true
        composerBeforeVoiceInput = composerText
        speechInput.start(initialText: composerText)
    }

    func endVoiceInput() {
        guard voiceState.isWorking else { return }
        speechInput.stop()
        composerBeforeVoiceInput = nil
    }

    func cancelVoiceInput() {
        acceptsSpeechTranscript = false
        let originalText = composerBeforeVoiceInput
        composerBeforeVoiceInput = nil
        speechInput.discardTranscript()
        if let originalText { composerText = originalText }
    }

    func dismissVoiceIssue() { speechInput.dismissIssue() }

    private func activateSession(_ selectedCredential: SessionCredential) {
        let reopensActiveSession = credential == selectedCredential
        snapshotTask?.cancel(); snapshotTask = nil
        streamTask?.cancel(); streamTask = nil
        mediaPrefetchTask?.cancel(); mediaPrefetchTask = nil
        cacheRestoreTask?.cancel(); cacheRestoreTask = nil
        imageSendGeneration = UUID(); imageSendTask?.cancel(); imageSendTask = nil
        imageImportGeneration = UUID(); imageImportCredential = nil
        imageImportTask?.cancel(); imageImportTask = nil
        isImportingImages = false
        if !reopensActiveSession {
            clearMessageDraftForDifferentSession()
        }
        if !reopensActiveSession { imageLoader?.invalidate() }
        acceptsSpeechTranscript = false
        speechInput.discardTranscript()
        // Publish the title before the session identity used for navigation.
        conversation = selectedCredential.conversation
        credential = selectedCredential
        isSendingMessage = false
        let localStore: ConversationLocalStore
        if reopensActiveSession, let activeConversationStore, imageLoader != nil {
            localStore = activeConversationStore
        } else {
            localStore = ConversationLocalStore(credential: selectedCredential)
            activeConversationStore = localStore
            imageLoader = BatonImageLoader(endpoint: selectedCredential.conversationEndpoint, token: selectedCredential.accessToken, localStore: localStore) { [weak self] in
                self?.discardTerminatedActiveSession(detail: String(localized: "媒体访问凭据已失效，请重新连接。"), matching: selectedCredential)
            }
        }
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

    private func clearMessageDraftForDifferentSession() {
        removeSelectedPhotos(force: true)
        composerText = ""
        draftMessageText = nil
        draftMessageIdentity = nil
        draftMessageID = nil
        pendingUnknownMessage = nil
        isMessageOutcomeUnknown = false
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
