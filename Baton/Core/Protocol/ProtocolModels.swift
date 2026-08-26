import Foundation

struct ServiceDescriptor: Codable, Equatable { let id: String; let name: String; let iconURL: URL?; enum CodingKeys: String, CodingKey { case id, name; case iconURL = "icon_url" } }
struct ConversationDescriptor: Codable, Equatable { let id: String; let title: String; let agentName: String?; enum CodingKeys: String, CodingKey { case id, title; case agentName = "agent_name" } }
struct PairingEndpoints: Codable, Equatable {
    let join: URL
    let approval: URL
    let conversation: URL
}
struct PairingDocument: Codable, Equatable {
    let protocolVersion: String; let pairingID: String; let expiresAt: String; let service: ServiceDescriptor; let conversation: ConversationDescriptor; let endpoints: PairingEndpoints
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol"; case pairingID = "pairing_id"; case expiresAt = "expires_at"; case service, conversation, endpoints }
}
struct MessageContent: Codable, Equatable { let type: String; let text: String? }
enum MessageRole: String, Codable { case user, assistant }
struct ConversationMessage: Codable, Identifiable, Equatable {
    let id: String; let clientMessageID: String?; let conversationID: String; let role: MessageRole; var content: [MessageContent]; let createdAt: String; var status: String
    enum CodingKeys: String, CodingKey { case id, role, content, status; case clientMessageID = "client_message_id"; case conversationID = "conversation_id"; case createdAt = "created_at" }
    var text: String { content.compactMap(\.text).joined() }
    mutating func append(delta: String) { if content.isEmpty { content = [MessageContent(type: "text", text: delta)] } else { content[0] = MessageContent(type: content[0].type, text: (content[0].text ?? "") + delta) } }
}
struct EventCursor: Codable, Equatable {
    let id: String
    let sequence: Int
}

struct ConversationSnapshot: Codable {
    let id: String
    let title: String
    let agentName: String?
    let messages: [ConversationMessage]
    let eventCursor: EventCursor

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case agentName = "agent_name"
        case eventCursor = "event_cursor"
    }
}
struct PairingJoinRequest: Encodable {
    let deviceID: String
    let deviceName: String
    let deviceProof: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case deviceProof = "device_proof"
    }
}

struct PendingPairingRequest: Codable, Equatable {
    let pairingID: String
    let requestID: String
    let pollURL: URL
    let retryAfterSeconds: Int

    enum CodingKeys: String, CodingKey {
        case pairingID = "pairing_id"
        case requestID = "request_id"
        case pollURL = "poll_url"
        case retryAfterSeconds = "retry_after_seconds"
    }
}

struct PairingStatus: Codable, Equatable {
    let pairingID: String
    let requestID: String
    let status: String
    let retryAfterSeconds: Int?
    let accessToken: String?
    let deviceID: String?
    /// Required by Companion Profile 1.0. `nil` is accepted only for the
    /// temporary local fixture, which still exposes the legacy `current` URL.
    let sessionID: String?
    let conversation: ConversationDescriptor?

    enum CodingKeys: String, CodingKey {
        case pairingID = "pairing_id"
        case requestID = "request_id"
        case status
        case retryAfterSeconds = "retry_after_seconds"
        case accessToken = "access_token"
        case deviceID = "device_id"
        case sessionID = "session_id"
        case conversation
    }
}

struct BatonEvent: Decodable { let id: String; let sequence: Int?; let type: String; let data: JSONValue }
