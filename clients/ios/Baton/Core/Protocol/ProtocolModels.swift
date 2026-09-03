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
    let contentAppend: Bool
    /// A shared Conversation lifecycle operation; false unless the service
    /// explicitly declares that Baton may invoke it.
    let conversationEnd: Bool
    /// The service can render selection interactions for a device which
    /// explicitly advertised support during pairing. This remains a server
    /// declaration, not permission for arbitrary client-side actions.
    let selection: Bool

    enum CodingKeys: String, CodingKey {
        case text, markdown, streaming, image
        case contentAppend = "content_append"
        case conversationEnd = "conversation_end"
        case selection
    }

    init(text: Bool = true, markdown: Bool = false, streaming: Bool = false, image: Bool = false, contentAppend: Bool = false, conversationEnd: Bool = false, selection: Bool = false) {
        self.text = text
        self.markdown = markdown
        self.streaming = streaming
        self.image = image
        self.contentAppend = contentAppend
        self.conversationEnd = conversationEnd
        self.selection = selection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(Bool.self, forKey: .text) ?? false
        markdown = try container.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
        contentAppend = try container.decodeIfPresent(Bool.self, forKey: .contentAppend) ?? false
        conversationEnd = try container.decodeIfPresent(Bool.self, forKey: .conversationEnd) ?? false
        selection = try container.decodeIfPresent(Bool.self, forKey: .selection) ?? false
    }
}

/// A per-device declaration submitted while joining. It only tells the
/// service which structured content the device can render; the service still
/// owns all authorization, validation, and fallback decisions.
struct BatonClientCapabilities: Encodable, Equatable {
    let selectionInteraction: Bool

    enum CodingKeys: String, CodingKey { case selectionInteraction = "selection_interaction" }
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

    /// V1.1 services may reject unknown JSON fields. Only a V1.2 service that
    /// explicitly declares selection support receives the optional join hint.
    var supportsSelectionCapabilityNegotiation: Bool {
        protocolVersion == "baton/1.2" && capabilities.selection
    }
}

/// `mediaID` is the stable, service-owned identity of an immutable media
/// rendition. `url` is only the Baton device's authenticated read location.
struct MessageImage: Codable, Equatable, Identifiable {
    let mediaID: String
    let url: URL
    let mimeType: String
    let width: Int
    let height: Int
    let alt: String

    var id: String { mediaID }

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case url, width, height, alt
        case mimeType = "mime_type"
    }

    var isPlausible: Bool {
        !mediaID.isEmpty && BatonImageFormat.isSupported(mimeType) && width > 0 && height > 0
    }
}

enum SelectionInputPolicy: String, Codable, Equatable {
    case freeTextAllowed = "free_text_allowed"
    case selectionRequired = "selection_required"
}

enum SelectionPresentation: String, Codable, Equatable {
    case standard
    case confirmation
}

struct MessageSelectionOption: Codable, Equatable, Identifiable {
    let id: String
    let label: String

    var isPlausible: Bool { !id.isEmpty && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A server-created, immutable question attached to an assistant message.
/// Its current lifecycle state is carried separately by ConversationSnapshot
/// and selection lifecycle SSE events.
struct MessageSelection: Codable, Equatable, Identifiable {
    let interactionID: String
    let prompt: String
    let inputPolicy: SelectionInputPolicy
    let presentation: SelectionPresentation
    let options: [MessageSelectionOption]

    var id: String { interactionID }

    enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case prompt
        case inputPolicy = "input_policy"
        case presentation, options
    }

    var isPlausible: Bool {
        guard !interactionID.isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (2...8).contains(options.count),
              options.allSatisfy(\.isPlausible),
              Set(options.map(\.id)).count == options.count else { return false }
        if presentation == .confirmation {
            return inputPolicy == .selectionRequired
                && options.map(\.id) == ["confirm", "cancel"]
        }
        return true
    }
}

/// User content for a selected option. `label` is omitted by the client and
/// populated only by the server when it persists the corresponding message.
struct SelectionResponse: Codable, Equatable {
    let interactionID: String
    let optionID: String
    let label: String?

    enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case optionID = "option_id"
        case label
    }

    init(interactionID: String, optionID: String, label: String? = nil) {
        self.interactionID = interactionID
        self.optionID = optionID
        self.label = label
    }

    var isPlausible: Bool { !interactionID.isEmpty && !optionID.isEmpty }
}

enum SelectionInteractionStatus: String, Codable, Equatable {
    case open, answered, cancelled, superseded, expired
}

struct SelectionInteractionState: Codable, Equatable, Identifiable {
    let interactionID: String
    let status: SelectionInteractionStatus
    let selectedOptionID: String?

    var id: String { interactionID }

    enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case status
        case selectedOptionID = "selected_option_id"
    }

    var isPlausible: Bool {
        guard !interactionID.isEmpty else { return false }
        return status != .answered || selectedOptionID?.isEmpty == false
    }
}

/// Ordered Conversation content. Unknown items stay explicit rather than being
/// silently coerced to text, so future server content cannot run as markup or
/// be mistaken for a supported image.
enum MessageContent: Codable, Equatable {
    case text(String)
    case image(MessageImage)
    case selection(MessageSelection)
    case selectionResponse(SelectionResponse)
    case unsupported(type: String, alt: String?)

    private enum CodingKeys: String, CodingKey {
        case type, text, mediaID = "media_id", url, mimeType = "mime_type", width, height, alt
        case interactionID = "interaction_id"
        case inputPolicy = "input_policy"
        case presentation, options, optionID = "option_id", label
    }

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
        case "selection":
            guard let selection = try? MessageSelection(from: decoder), selection.isPlausible else {
                self = .unsupported(type: type, alt: nil)
                return
            }
            self = .selection(selection)
        case "selection_response":
            guard let response = try? SelectionResponse(from: decoder), response.isPlausible else {
                self = .unsupported(type: type, alt: nil)
                return
            }
            self = .selectionResponse(response)
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
            try container.encode(image.mediaID, forKey: .mediaID)
            try container.encode(image.url, forKey: .url)
            try container.encode(image.mimeType, forKey: .mimeType)
            try container.encode(image.width, forKey: .width)
            try container.encode(image.height, forKey: .height)
            try container.encode(image.alt, forKey: .alt)
        case let .selection(selection):
            try container.encode("selection", forKey: .type)
            try selection.encode(to: encoder)
        case let .selectionResponse(response):
            try container.encode("selection_response", forKey: .type)
            try container.encode(response.interactionID, forKey: .interactionID)
            try container.encode(response.optionID, forKey: .optionID)
            try container.encodeIfPresent(response.label, forKey: .label)
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

    var selection: MessageSelection? {
        guard case let .selection(selection) = self else { return nil }
        return selection
    }

    var selectionResponse: SelectionResponse? {
        guard case let .selectionResponse(response) = self else { return nil }
        return response
    }

    func isValid(for role: MessageRole) -> Bool {
        switch self {
        case .selection: return role == .assistant
        case .selectionResponse: return role == .user
        default: return true
        }
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
        guard content.allSatisfy({ $0.isValid(for: role) }) else { return false }
        return status != "streaming" || (role == .assistant && content.count == 1 && content[0].text != nil)
    }

    mutating func appendStreamingDelta(_ delta: String) -> Bool {
        guard role == .assistant, status == "streaming", content.count == 1, let text = content[0].text else { return false }
        content[0] = .text(text + delta)
        return true
    }

    /// V1.1 only permits immutable static images to be appended once an
    /// assistant answer is complete. No client can insert, replace, or remove.
    mutating func appendCompletedImages(_ appended: [MessageContent]) -> Bool {
        guard role == .assistant, status == "completed", !appended.isEmpty,
              appended.allSatisfy({ $0.image != nil }) else { return false }
        content.append(contentsOf: appended)
        return true
    }
}
struct EventCursor: Codable, Equatable {
    let id: String
    let sequence: Int

    /// Snapshot cursors are the atomic boundary between history and SSE. They
    /// are never optional or provisional: an empty identity or non-positive
    /// sequence cannot safely resume a conversation.
    init?(id: String, sequence: Int) {
        guard !id.isEmpty, sequence > 0 else { return nil }
        self.id = id
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey { case id, sequence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let sequence = try container.decode(Int.self, forKey: .sequence)
        guard let cursor = Self(id: id, sequence: sequence) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: container,
                debugDescription: "Event cursor requires a non-empty id and positive sequence."
            )
        }
        self = cursor
    }
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
    let selectionStates: [SelectionInteractionState]

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case agentName = "agent_name"
        case eventCursor = "event_cursor"
        case activeRuns = "active_runs"
        case selectionStates = "selection_states"
    }

    init(id: String, title: String, agentName: String?, messages: [ConversationMessage], eventCursor: EventCursor, activeRuns: [ActiveRun] = [], selectionStates: [SelectionInteractionState] = []) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.messages = messages
        self.eventCursor = eventCursor
        self.activeRuns = activeRuns
        self.selectionStates = selectionStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        messages = try container.decode([ConversationMessage].self, forKey: .messages)
        eventCursor = try container.decode(EventCursor.self, forKey: .eventCursor)
        activeRuns = try container.decodeIfPresent([ActiveRun].self, forKey: .activeRuns) ?? []
        selectionStates = try container.decodeIfPresent([SelectionInteractionState].self, forKey: .selectionStates) ?? []
        guard selectionStates.allSatisfy(\.isPlausible), Set(selectionStates.map(\.interactionID)).count == selectionStates.count else {
            throw DecodingError.dataCorruptedError(forKey: .selectionStates, in: container, debugDescription: "Selection states must be unique and valid.")
        }
    }
}
struct PairingJoinRequest: Encodable {
    let deviceID: String
    let deviceName: String
    let deviceProof: String
    let clientCapabilities: BatonClientCapabilities?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case deviceProof = "device_proof"
        case clientCapabilities = "client_capabilities"
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
    /// Required by Companion Profile 1.1. `nil` is accepted only for the
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

struct BatonEvent: Decodable {
    let id: String
    let sequence: Int
    let type: String
    let data: JSONValue

    init(id: String, sequence: Int, type: String, data: JSONValue) {
        self.id = id
        self.sequence = sequence
        self.type = type
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case id, sequence, type, data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let sequence = try container.decode(Int.self, forKey: .sequence)
        let type = try container.decode(String.self, forKey: .type)
        let data = try container.decode(JSONValue.self, forKey: .data)
        guard !id.isEmpty, sequence > 0, !type.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sequence, in: container, debugDescription: "Baton event requires a positive sequence and non-empty identity.")
        }
        self.init(id: id, sequence: sequence, type: type, data: data)
    }
}
