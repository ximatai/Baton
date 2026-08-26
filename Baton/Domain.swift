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

struct BatonEvent: Decodable { let id: String; let sequence: Int?; let type: String; let data: JSONValue }

/// Pure conversation state machine. Networking stays in the view model, which
/// makes atomic snapshot/cursor behavior and duplicate SSE handling testable.
struct ConversationEventReducer: Equatable {
    private(set) var messages: [ConversationMessage] = []
    private(set) var cursor: EventCursor?
    private var seenEventIDs: Set<String> = []
    private var seenOrder: [String] = []
    private let maxSeenEvents = 512

    mutating func replaceSnapshot(_ snapshot: ConversationSnapshot) {
        messages = snapshot.messages.sorted { $0.createdAt < $1.createdAt }
        cursor = snapshot.eventCursor
        seenEventIDs.removeAll(keepingCapacity: true)
        seenOrder.removeAll(keepingCapacity: true)
    }

    /// Returns true when the server asks the caller to obtain a fresh atomic
    /// snapshot. The control event itself is intentionally not remembered as a
    /// normal conversation event.
    mutating func apply(_ event: BatonEvent) -> Bool {
        if event.type == "conversation.resync" { return true }
        if seenEventIDs.contains(event.id) { return false }
        if let sequence = event.sequence, let cursor, sequence <= cursor.sequence { return false }

        remember(event.id)
        if let sequence = event.sequence { cursor = EventCursor(id: event.id, sequence: sequence) }
        else if cursor?.id != event.id { cursor = EventCursor(id: event.id, sequence: cursor?.sequence ?? 0) }

        switch event.type {
        case "message.created":
            if let message = decodeMessage(event.data) { mergeMessage(message) }
        case "message.delta":
            guard let data = event.data.object, let id = data["message_id"]?.string, let delta = data["delta"]?.string else { break }
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].append(delta: delta) }
            else {
                messages.append(ConversationMessage(id: id, clientMessageID: nil, conversationID: "", role: .assistant, content: [MessageContent(type: "text", text: delta)], createdAt: ISO8601DateFormatter().string(from: Date()), status: "streaming"))
            }
        case "message.completed":
            if let id = event.data.object?["message_id"]?.string, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].status = event.data.object?["status"]?.string ?? "completed"
            }
        case "message.failed":
            if let id = event.data.object?["message_id"]?.string, let index = messages.firstIndex(where: { $0.id == id }) { messages[index].status = "failed" }
        default:
            break
        }
        return false
    }

    mutating func mergeMessage(_ message: ConversationMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else { messages.append(message); messages.sort { $0.createdAt < $1.createdAt } }
    }

    private mutating func remember(_ id: String) {
        seenEventIDs.insert(id); seenOrder.append(id)
        if seenOrder.count > maxSeenEvents {
            let removed = seenOrder.removeFirst()
            seenEventIDs.remove(removed)
        }
    }

    private func decodeMessage(_ value: JSONValue) -> ConversationMessage? {
        guard JSONSerialization.isValidJSONObject(value.foundationValue), let data = try? JSONSerialization.data(withJSONObject: value.foundationValue) else { return nil }
        return try? JSONDecoder().decode(ConversationMessage.self, from: data)
    }
}
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) } }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var foundationValue: Any { switch self { case .string(let v): v; case .number(let v): v; case .bool(let v): v; case .object(let v): v.mapValues(\.foundationValue); case .array(let v): v.map(\.foundationValue); case .null: NSNull() } }
}
