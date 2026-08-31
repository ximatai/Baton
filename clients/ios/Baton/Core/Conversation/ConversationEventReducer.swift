import Foundation

/// Pure conversation state machine. Networking stays in the view model, which
/// makes atomic snapshot/cursor behavior and duplicate SSE handling testable.
struct ConversationEventReducer: Equatable {
    private(set) var messages: [ConversationMessage] = []
    private(set) var cursor: EventCursor?
    private var seenEventIDs: Set<String> = []
    private var seenOrder: [String] = []
    private let maxSeenEvents = 512

    @discardableResult
    mutating func replaceSnapshot(_ snapshot: ConversationSnapshot) -> Bool {
        guard snapshot.messages.allSatisfy(\.isValidStreamingContent) else { return false }
        messages = snapshot.messages.sorted { $0.createdAt < $1.createdAt }
        cursor = snapshot.eventCursor
        seenEventIDs.removeAll(keepingCapacity: true)
        seenOrder.removeAll(keepingCapacity: true)
        return true
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
            guard let message = decodeMessage(event.data), message.isValidStreamingContent else { return true }
            mergeMessage(message)
        case "message.delta":
            guard let data = event.data.object, let id = data["message_id"]?.string, let delta = data["delta"]?.string else { break }
            guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].appendStreamingDelta(delta) else { return true }
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
        // A Baton message.created event wraps its protocol message in data.message.
        // Decoding the outer event payload silently drops real-time user messages.
        guard let message = value.object?["message"],
              JSONSerialization.isValidJSONObject(message.foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: message.foundationValue) else { return nil }
        return try? JSONDecoder().decode(ConversationMessage.self, from: data)
    }
}
