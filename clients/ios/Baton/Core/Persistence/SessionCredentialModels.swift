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
}
