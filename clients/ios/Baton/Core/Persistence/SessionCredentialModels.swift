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

    var id: String { credential.conversationKey }

    init(
        credential: SessionCredential,
        lastActivatedAt: Date = .now,
        lastReadCursor: EventCursor? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        latestObservedCursor: EventCursor? = nil
    ) {
        self.credential = credential
        self.lastActivatedAt = lastActivatedAt
        self.lastReadCursor = lastReadCursor
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.latestObservedCursor = latestObservedCursor
    }

    private enum CodingKeys: String, CodingKey {
        case credential, lastActivatedAt, lastReadCursor, lastSuccessfulSyncAt, latestObservedCursor
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
    }

    func markingRead(cursor: EventCursor, at date: Date) -> Self {
        Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: cursor,
            lastSuccessfulSyncAt: date,
            latestObservedCursor: cursor
        )
    }

    func recordingObserved(cursor: EventCursor) -> Self {
        guard latestObservedCursor.map({ cursor.sequence > $0.sequence }) ?? true else { return self }
        return Self(
            credential: credential,
            lastActivatedAt: lastActivatedAt,
            lastReadCursor: lastReadCursor,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            latestObservedCursor: cursor
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

    init(_ stored: StoredConversationSession) {
        id = stored.id
        service = stored.credential.service
        conversation = stored.credential.conversation
        lastActivatedAt = stored.lastActivatedAt
        lastSuccessfulSyncAt = stored.lastSuccessfulSyncAt
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
            lastActivatedAt: date,
            lastReadCursor: existing?.credential == credential ? existing?.lastReadCursor : nil,
            lastSuccessfulSyncAt: existing?.credential == credential ? existing?.lastSuccessfulSyncAt : nil,
            latestObservedCursor: existing?.credential == credential ? existing?.latestObservedCursor : nil
        )
        return ([replacement] + sessions.filter { $0.id != replacement.id })
            .sorted { $0.lastActivatedAt > $1.lastActivatedAt }
    }

    static func removing(
        conversationKey: String,
        from sessions: [StoredConversationSession]
    ) -> [StoredConversationSession] {
        sessions.filter { $0.id != conversationKey }
    }

    static func deduplicating(_ sessions: [StoredConversationSession]) -> [StoredConversationSession] {
        sessions
            .sorted { $0.lastActivatedAt > $1.lastActivatedAt }
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

/// An unsent message is Keychain-backed before its request begins. It is only
/// replayed when the exact saved session and conversation are restored.
struct PendingOutboxMessage: Codable, Equatable, Identifiable {
    let clientMessageID: String
    let text: String
    let conversationID: String
    let conversationEndpoint: URL
    let sessionID: String
    let deviceID: String

    var id: String { clientMessageID }

    init(clientMessageID: UUID = UUID(), text: String, credential: SessionCredential) {
        self.clientMessageID = clientMessageID.uuidString
        self.text = text
        conversationID = credential.conversation.id
        conversationEndpoint = credential.conversationEndpoint
        sessionID = credential.sessionID
        deviceID = credential.deviceID
    }

    func belongs(to credential: SessionCredential) -> Bool {
        conversationID == credential.conversation.id &&
            conversationEndpoint == credential.conversationEndpoint &&
            sessionID == credential.sessionID &&
            deviceID == credential.deviceID
    }

    func belongs(toConversationOf credential: SessionCredential) -> Bool {
        conversationID == credential.conversation.id &&
            conversationEndpoint.scheme?.lowercased() == credential.conversationEndpoint.scheme?.lowercased() &&
            conversationEndpoint.host?.lowercased() == credential.conversationEndpoint.host?.lowercased() &&
            conversationEndpoint.port == credential.conversationEndpoint.port
    }
}
