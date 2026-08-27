import Foundation

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
        // A missing sequence cannot be filled locally: applying this event
        // would silently present a timeline that never existed on the server.
        if let sequence = event.sequence, let cursor, sequence > cursor.sequence + 1 { return true }

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
