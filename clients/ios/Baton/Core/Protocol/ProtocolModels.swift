import Foundation

struct ServiceDescriptor: Codable, Equatable { let id: String; let name: String; let iconURL: URL?; enum CodingKeys: String, CodingKey { case id, name; case iconURL = "icon_url" } }
struct ConversationDescriptor: Codable, Equatable { let id: String; let title: String; let agentName: String?; enum CodingKeys: String, CodingKey { case id, title; case agentName = "agent_name" } }
struct PairingEndpoints: Codable, Equatable {
    let join: URL
    let approval: URL
    let conversation: URL
}

/// Server-declared Conversation behavior. This is discovery metadata, not a
/// device permission or a request for the phone to enable a capability.
struct BatonCapabilities: Codable, Equatable {
    let text: Bool
    let markdown: Bool
    let streaming: Bool
    let image: Bool

    init(text: Bool = true, markdown: Bool = false, streaming: Bool = false, image: Bool = false) {
        self.text = text
        self.markdown = markdown
        self.streaming = streaming
        self.image = image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(Bool.self, forKey: .text) ?? false
        markdown = try container.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
    }
}

enum PairingApprovalMode: String, Codable, Equatable {
    case manual
    case auto
}

struct PairingDocument: Codable, Equatable {
    let protocolVersion: String
    let pairingID: String
    let expiresAt: String
    let service: ServiceDescriptor
    let conversation: ConversationDescriptor
    let endpoints: PairingEndpoints
    let capabilities: BatonCapabilities
    /// Absent on pre-policy services; manual preserves the original V1 behavior.
    let approvalMode: PairingApprovalMode

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case pairingID = "pairing_id"
        case expiresAt = "expires_at"
        case service, conversation, endpoints, capabilities
        case approvalMode = "approval_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        pairingID = try container.decode(String.self, forKey: .pairingID)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        service = try container.decode(ServiceDescriptor.self, forKey: .service)
        conversation = try container.decode(ConversationDescriptor.self, forKey: .conversation)
        endpoints = try container.decode(PairingEndpoints.self, forKey: .endpoints)
        capabilities = try container.decode(BatonCapabilities.self, forKey: .capabilities)
        guard capabilities.text else {
            throw DecodingError.dataCorruptedError(forKey: .capabilities, in: container, debugDescription: "Baton requires capabilities.text to be true.")
        }
        approvalMode = try container.decodeIfPresent(PairingApprovalMode.self, forKey: .approvalMode) ?? .manual
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(pairingID, forKey: .pairingID)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(service, forKey: .service)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(approvalMode, forKey: .approvalMode)
    }
}

struct MessageImage: Codable, Equatable, Identifiable {
    let url: URL
    let mimeType: String
    let width: Int
    let height: Int
    let alt: String

    var id: URL { url }

    enum CodingKeys: String, CodingKey {
        case url, width, height, alt
        case mimeType = "mime_type"
    }

    var isPlausible: Bool {
        BatonImageFormat.isSupported(mimeType) && width > 0 && height > 0
    }
}

/// Ordered Conversation content. Unknown items stay explicit rather than being
/// silently coerced to text, so future server content cannot run as markup or
/// be mistaken for a supported image.
enum MessageContent: Codable, Equatable {
    case text(String)
    case image(MessageImage)
    case unsupported(type: String, alt: String?)

    private enum CodingKeys: String, CodingKey { case type, text, url, mimeType = "mime_type", width, height, alt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            guard let image = try? MessageImage(from: decoder), image.isPlausible,
                  BatonTransportPolicy.permits(image.url), image.url.user == nil, image.url.password == nil else {
                self = .unsupported(type: type, alt: try? container.decodeIfPresent(String.self, forKey: .alt))
                return
            }
            self = .image(image)
        default:
            self = .unsupported(type: type, alt: try? container.decodeIfPresent(String.self, forKey: .alt))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(image):
            try container.encode("image", forKey: .type)
            try container.encode(image.url, forKey: .url)
            try container.encode(image.mimeType, forKey: .mimeType)
            try container.encode(image.width, forKey: .width)
            try container.encode(image.height, forKey: .height)
            try container.encode(image.alt, forKey: .alt)
        case let .unsupported(type, alt):
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(alt, forKey: .alt)
        }
    }

    var text: String? {
        guard case let .text(text) = self else { return nil }
        return text
    }

    var image: MessageImage? {
        guard case let .image(image) = self else { return nil }
        return image
    }
}

enum BatonImageFormat {
    static let supportedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    static func isSupported(_ mimeType: String) -> Bool {
        supportedMIMETypes.contains(mimeType.lowercased())
    }
}

enum MessageRole: String, Codable { case user, assistant }
struct ConversationMessage: Codable, Identifiable, Equatable {
    let id: String; let clientMessageID: String?; let conversationID: String; let role: MessageRole; var content: [MessageContent]; let createdAt: String; var status: String
    enum CodingKeys: String, CodingKey { case id, role, content, status; case clientMessageID = "client_message_id"; case conversationID = "conversation_id"; case createdAt = "created_at" }
    var text: String { content.compactMap(\.text).joined() }
    var isValidStreamingContent: Bool {
        status != "streaming" || (role == .assistant && content.count == 1 && content[0].text != nil)
    }

    mutating func appendStreamingDelta(_ delta: String) -> Bool {
        guard role == .assistant, status == "streaming", content.count == 1, let text = content[0].text else { return false }
        content[0] = .text(text + delta)
        return true
    }
}
struct EventCursor: Codable, Equatable {
    let id: String
    let sequence: Int
}

struct ActiveRun: Codable, Equatable {
    let id: String
    let status: String
    let messageID: String?

    enum CodingKeys: String, CodingKey {
        case id = "run_id"
        case status
        case messageID = "message_id"
    }

    var isLive: Bool { status == "active" || status == "cancellation_requested" }

    static func current(in runs: [ActiveRun]) -> ActiveRun? {
        runs.first(where: \.isLive)
    }
}

struct ConversationSnapshot: Codable {
    let id: String
    let title: String
    let agentName: String?
    let messages: [ConversationMessage]
    let eventCursor: EventCursor
    /// Optional on the wire during the V1 transition. A snapshot must expose
    /// live runs once the server supports Stop-after-reconnect.
    let activeRuns: [ActiveRun]

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case agentName = "agent_name"
        case eventCursor = "event_cursor"
        case activeRuns = "active_runs"
    }

    init(id: String, title: String, agentName: String?, messages: [ConversationMessage], eventCursor: EventCursor, activeRuns: [ActiveRun] = []) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.messages = messages
        self.eventCursor = eventCursor
        self.activeRuns = activeRuns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        messages = try container.decode([ConversationMessage].self, forKey: .messages)
        eventCursor = try container.decode(EventCursor.self, forKey: .eventCursor)
        activeRuns = try container.decodeIfPresent([ActiveRun].self, forKey: .activeRuns) ?? []
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pairingID = try container.decode(String.self, forKey: .pairingID)
        requestID = try container.decode(String.self, forKey: .requestID)
        pollURL = try container.decode(URL.self, forKey: .pollURL)
        retryAfterSeconds = try container.decode(Int.self, forKey: .retryAfterSeconds)
        guard pollURL.scheme != nil, pollURL.host != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .pollURL,
                in: container,
                debugDescription: "poll_url must be an absolute network URL."
            )
        }
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
