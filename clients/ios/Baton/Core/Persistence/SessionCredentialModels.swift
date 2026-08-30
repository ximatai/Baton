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
    var conversationKey: String {
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

    var id: String { credential.conversationKey }

    init(credential: SessionCredential, lastActivatedAt: Date = .now) {
        self.credential = credential
        self.lastActivatedAt = lastActivatedAt
    }
}

/// Non-secret session data intended for a future conversation switcher.
struct ConversationSessionSummary: Equatable, Identifiable {
    let id: String
    let service: ServiceDescriptor
    let conversation: ConversationDescriptor
    let lastActivatedAt: Date

    init(_ stored: StoredConversationSession) {
        id = stored.id
        service = stored.credential.service
        conversation = stored.credential.conversation
        lastActivatedAt = stored.lastActivatedAt
    }
}

enum ConversationSessionIndex {
    static func upserting(
        _ credential: SessionCredential,
        into sessions: [StoredConversationSession],
        at date: Date = .now
    ) -> [StoredConversationSession] {
        let replacement = StoredConversationSession(credential: credential, lastActivatedAt: date)
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
