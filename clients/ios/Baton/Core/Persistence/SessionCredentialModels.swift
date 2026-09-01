import Foundation

/// The proof and request metadata needed to claim an already-approved pairing.
/// This is intentionally Keychain-only: losing it means the user must scan again.
struct PendingPairingCredential: Codable, Equatable {
    let document: PairingDocument
    let request: PendingPairingRequest
    let deviceID: String
    let deviceProof: String
}

struct SessionCredential: Codable, Equatable {
    let accessToken: String
    let deviceID: String
    /// The server-issued session identifier used for remote revocation.
    let sessionID: String
    let service: ServiceDescriptor
    let conversation: ConversationDescriptor
    let conversationEndpoint: URL
    let canEndConversation: Bool

    enum CodingKeys: String, CodingKey {
        case accessToken, deviceID, sessionID, service, conversation, conversationEndpoint, canEndConversation
    }

    init(accessToken: String, deviceID: String, sessionID: String, service: ServiceDescriptor, conversation: ConversationDescriptor, conversationEndpoint: URL, canEndConversation: Bool = false) {
        self.accessToken = accessToken
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.service = service
        self.conversation = conversation
        self.conversationEndpoint = conversationEndpoint
        self.canEndConversation = canEndConversation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        service = try container.decode(ServiceDescriptor.self, forKey: .service)
        conversation = try container.decode(ConversationDescriptor.self, forKey: .conversation)
        conversationEndpoint = try container.decode(URL.self, forKey: .conversationEndpoint)
        canEndConversation = try container.decodeIfPresent(Bool.self, forKey: .canEndConversation) ?? false
    }

    /// A device session is replaceable; a saved-list item represents the
    /// server conversation at one service origin. Keep this stable when the
    /// same conversation is paired again and receives a new session ID.
    nonisolated var conversationKey: String {
        let scheme = conversationEndpoint.scheme?.lowercased() ?? ""
        let host = conversationEndpoint.host?.lowercased() ?? ""
        let port = conversationEndpoint.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)|\(conversation.id)"
    }

    /// Every authenticated response must remain bound to the Conversation
    /// originally granted by this credential, even behind a same-origin proxy.
    func ownsConversation(id: String) -> Bool {
        conversation.id == id
    }
}

/// Keychain-backed metadata for a Conversation the user has explicitly joined.
/// The credential remains private to persistence and transport; views consume the
/// derived summary instead. Ordering is local-only and never changes server state.
struct StoredConversationSession: Codable, Equatable, Identifiable {
    let credential: SessionCredential
    /// The last local or remote message activity. This retained coding key
    /// predates the distinction between opening a saved session and actual
    /// conversation activity.
    let lastActivatedAt: Date
    /// The atomic server boundary last accepted while this conversation was
    /// actually open. It is local UI metadata, not a replacement for history.
    let lastReadCursor: EventCursor?
    /// Updated with `lastReadCursor`, never by a list availability probe.
    let lastSuccessfulSyncAt: Date?
    /// The newest cursor observed by an availability probe. Keeping this
    /// separate from `lastReadCursor` lets the list show a local update marker
    /// without claiming that the user has opened the conversation.
    let latestObservedCursor: EventCursor?
    /// A device-only label. It never changes the server Conversation title.
    let localTitle: String?
    /// A device-only list preference. Pinned Conversations stay above the
    /// normal recent-session order without changing server state.
    let isPinned: Bool

    var id: String { credential.conversationKey }

    init(
        credential: SessionCredential,
        lastActivatedAt: Date = .now,
        lastReadCursor: EventCursor? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        latestObservedCursor: EventCursor? = nil,
        localTitle: String? = nil,
        isPinned: Bool = false
    ) {
        self.credential = credential
        self.lastActivatedAt = lastActivatedAt
        self.lastReadCursor = lastReadCursor
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.latestObservedCursor = latestObservedCursor
        self.localTitle = localTitle
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case credential, lastActivatedAt, lastReadCursor, lastSuccessfulSyncAt, latestObservedCursor, localTitle, isPinned
    }

    /// Existing Keychain entries predate read-state metadata. Decode them as
    /// an unknown baseline rather than rejecting the user's saved sessions.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credential = try container.decode(SessionCredential.self, forKey: .credential)
        lastActivatedAt = try container.decode(Date.self, forKey: .lastActivatedAt)
        lastReadCursor = try container.decodeIfPresent(EventCursor.self, forKey: .lastReadCursor)
        lastSuccessfulSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt)
        latestObservedCursor = try container.decodeIfPresent(EventCursor.self, forKey: .latestObservedCursor)
        localTitle = try container.decodeIfPresent(String.self, forKey: .localTitle)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func markingRead(cursor: EventCursor, at date: Date) -> Self {
        Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: cursor,
            lastSuccessfulSyncAt: date,
            latestObservedCursor: cursor,
            localTitle: localTitle,
            isPinned: isPinned
        )
    }

    func recordingObserved(cursor: EventCursor) -> Self {
        guard latestObservedCursor.map({ cursor.sequence > $0.sequence }) ?? true else { return self }
        return Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: lastReadCursor,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestObservedCursor: cursor,
            localTitle: localTitle,
            isPinned: isPinned
        )
    }

    func recordingInteraction(at date: Date) -> Self {
        Self(
            credential: credential,
            lastActivatedAt: date,
            lastReadCursor: lastReadCursor,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestObservedCursor: latestObservedCursor,
            localTitle: localTitle,
            isPinned: isPinned
        )
    }

    func renamingLocally(to title: String?) -> Self {
        Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: lastReadCursor,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestObservedCursor: latestObservedCursor,
            localTitle: title,
            isPinned: isPinned
        )
    }

    func settingPinned(_ pinned: Bool) -> Self {
        Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: lastReadCursor,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestObservedCursor: latestObservedCursor,
            localTitle: localTitle,
            isPinned: pinned
        )
    }
}

/// Non-secret session data intended for a future conversation switcher.
struct ConversationSessionSummary: Equatable, Identifiable {
    let id: String
    let service: ServiceDescriptor
    let conversation: ConversationDescriptor
    let lastActivatedAt: Date
    let lastSuccessfulSyncAt: Date?
    let hasUnreadUpdates: Bool
    let displayTitle: String
    let localTitle: String?
    let isPinned: Bool

    init(_ stored: StoredConversationSession) {
        id = stored.id
        service = stored.credential.service
        conversation = stored.credential.conversation
        lastActivatedAt = stored.lastActivatedAt
        lastSuccessfulSyncAt = stored.lastSuccessfulSyncAt
        displayTitle = stored.localTitle ?? stored.credential.conversation.title
        localTitle = stored.localTitle
        isPinned = stored.isPinned
        if let lastReadCursor = stored.lastReadCursor,
           let latestObservedCursor = stored.latestObservedCursor {
            hasUnreadUpdates = latestObservedCursor.sequence > lastReadCursor.sequence
        } else {
            hasUnreadUpdates = false
        }
    }
}

enum ConversationSessionIndex {
    static func upserting(
        _ credential: SessionCredential,
        into sessions: [StoredConversationSession],
        at date: Date = .now
    ) -> [StoredConversationSession] {
        let existing = sessions.first { $0.id == credential.conversationKey }
        // A replacement device session is a distinct authorization boundary:
        // do not carry read metadata from the old credential into it.
        let replacement = StoredConversationSession(
            credential: credential,
            // Reopening a saved session is navigation, not a new interaction.
            // Keep its position until the conversation has a new message.
            lastActivatedAt: existing?.credential == credential
                ? existing.map(\.lastActivatedAt) ?? date
                : date,
            lastReadCursor: existing?.credential == credential ? existing?.lastReadCursor : nil,
            lastSuccessfulSyncAt: existing?.credential == credential ? existing?.lastSuccessfulSyncAt : nil,
            latestObservedCursor: existing?.credential == credential ? existing?.latestObservedCursor : nil,
            localTitle: existing?.localTitle,
            isPinned: existing?.isPinned ?? false
        )
        return sorted([replacement] + sessions.filter { $0.id != replacement.id })
    }

    static func removing(
        conversationKey: String,
        from sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sessions.filter { $0.id != conversationKey }
    }

    static func deduplicating(_ sessions: [StoredConversationSession]) -> [StoredConversationSession] {
        sorted(sessions)
            .reduce(into: [StoredConversationSession]()) { result, session in
                if !result.contains(where: { $0.id == session.id }) { result.append(session) }
            }
    }

    static func markingRead(
        for credential: SessionCredential,
        cursor: EventCursor,
        at date: Date,
        in sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sessions.map { session in
            session.id == credential.conversationKey && session.credential == credential
                ? session.markingRead(cursor: cursor, at: date)
                : session
        }
    }

    static func recordingObserved(
        for credential: SessionCredential,
        cursor: EventCursor,
        in sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sessions.map { session in
            session.id == credential.conversationKey && session.credential == credential
                ? session.recordingObserved(cursor: cursor)
                : session
        }
    }

    static func recordingInteraction(
        for credential: SessionCredential,
        at date: Date,
        in sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sorted(sessions.map { session in
            session.id == credential.conversationKey && session.credential == credential
                ? session.recordingInteraction(at: date)
                : session
        })
    }

    static func renamingLocally(
        conversationKey: String,
        to title: String?,
        in sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sessions.map { $0.id == conversationKey ? $0.renamingLocally(to: title) : $0 }
    }

    static func settingPinned(
        conversationKey: String,
        to pinned: Bool,
        in sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sorted(sessions.map { $0.id == conversationKey ? $0.settingPinned(pinned) : $0 })
    }

    private static func sorted(_ sessions: [StoredConversationSession]) -> [StoredConversationSession] {
        sessions.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            if $0.lastActivatedAt != $1.lastActivatedAt { return $0.lastActivatedAt > $1.lastActivatedAt }
            return $0.id < $1.id
        }
    }
}

/// Snapshot acceptance is deliberately stricter than credential equality: a
/// saved credential may remain selected while its conversation has been
/// suspended. Keeping this predicate pure makes the lifecycle boundary
/// independently testable.
enum ConversationSessionSyncValidity {
    static func acceptsSnapshot(
        for candidate: SessionCredential,
        activeCredential: SessionCredential?,
        maintainsConnection: Bool,
        isTaskCancelled: Bool
    ) -> Bool {
        maintainsConnection && !isTaskCancelled && activeCredential == candidate
    }
}
