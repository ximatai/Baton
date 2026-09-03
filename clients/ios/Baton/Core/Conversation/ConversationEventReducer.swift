import Foundation

/// Pure conversation state machine. Networking stays in the view model, which
/// makes atomic snapshot/cursor behavior and duplicate SSE handling testable.
struct ConversationEventReducer: Equatable {
    private(set) var messages: [ConversationMessage] = []
    private(set) var selectionStates: [String: SelectionInteractionState] = [:]
    private(set) var cursor: EventCursor?
    /// Event identifiers are not sufficient for replay safety on their own:
    /// the same id with a rewritten sequence is a continuity failure.
    private var seenEventSequences: [String: Int] = [:]
    private var seenOrder: [String] = []
    private let maxSeenEvents = 512

    @discardableResult
    mutating func replaceSnapshot(_ snapshot: ConversationSnapshot) -> Bool {
        guard snapshot.messages.allSatisfy(\.isValidStreamingContent) else { return false }
        messages = snapshot.messages.sorted { $0.createdAt < $1.createdAt }
        selectionStates = Dictionary(uniqueKeysWithValues: snapshot.selectionStates.map { ($0.interactionID, $0) })
        cursor = snapshot.eventCursor
        seenEventSequences.removeAll(keepingCapacity: true)
        seenOrder.removeAll(keepingCapacity: true)
        return true
    }

    /// Returns true when the server asks the caller to obtain a fresh atomic
    /// snapshot. The control event itself is intentionally not remembered as a
    /// normal conversation event.
    mutating func apply(_ event: BatonEvent) -> Bool {
        if event.type == "conversation.resync" { return true }

        // A replay is ignorable only when it identifies the exact accepted
        // envelope. Every other id/sequence conflict means this reducer can no
        // longer prove that its timeline is contiguous.
        if let seenSequence = seenEventSequences[event.id] {
            return seenSequence == event.sequence ? false : true
        }
        // Events are only valid after an atomic snapshot establishes the
        // mandatory cursor. There is no first-event fallback.
        guard let cursor else { return true }
        if event.id == cursor.id, event.sequence == cursor.sequence { return false }
        if event.id == cursor.id { return true }
        if event.sequence <= cursor.sequence { return true }
        if event.sequence > cursor.sequence + 1 { return true }

        // Work against a copy so malformed events never partially advance the
        // cursor or replay ledger before requesting an atomic snapshot.
        var next = self

        // Validate an append before advancing the cursor: an invalid target or
        // item means local state cannot be reconciled without an atomic snapshot.
        if event.type == "message.content.appended" {
            guard next.applyContentAppend(event.data) else { return true }
            next.remember(event)
            next.advanceCursor(for: event)
            self = next
            return false
        }

        if event.type == "selection.resolved" || event.type == "selection.cancelled" {
            guard let state = next.decodeSelectionState(event.data), state.isPlausible else { return true }
            next.selectionStates[state.interactionID] = state
            next.remember(event)
            next.advanceCursor(for: event)
            self = next
            return false
        }

        switch event.type {
        case "message.created":
            guard let message = next.decodeMessage(event.data), message.isValidStreamingContent else { return true }
            next.mergeMessage(message)
        case "message.delta":
            guard let data = event.data.object, let id = data["message_id"]?.string, let delta = data["delta"]?.string else { break }
            guard let index = next.messages.firstIndex(where: { $0.id == id }), next.messages[index].appendStreamingDelta(delta) else { return true }
        case "message.completed":
            if let id = event.data.object?["message_id"]?.string, let index = next.messages.firstIndex(where: { $0.id == id }) {
                next.messages[index].status = event.data.object?["status"]?.string ?? "completed"
            }
        case "message.failed":
            if let id = event.data.object?["message_id"]?.string, let index = next.messages.firstIndex(where: { $0.id == id }) { next.messages[index].status = "failed" }
        default:
            break
        }
        next.remember(event)
        next.advanceCursor(for: event)
        self = next
        return false
    }

    private mutating func advanceCursor(for event: BatonEvent) {
        // BatonEvent already rejects an empty id/non-positive sequence.
        // Keep this guard so this reducer never installs an invalid cursor if
        // its construction invariants are changed in the future.
        guard let nextCursor = EventCursor(id: event.id, sequence: event.sequence) else { return }
        cursor = nextCursor
    }

    private mutating func applyContentAppend(_ value: JSONValue) -> Bool {
        guard let data = value.object,
              let messageID = data["message_id"]?.string,
              let rawContent = data["content"]?.foundationValue,
              JSONSerialization.isValidJSONObject(rawContent),
              let encoded = try? JSONSerialization.data(withJSONObject: rawContent),
              let content = try? JSONDecoder().decode([MessageContent].self, from: encoded),
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        return messages[index].appendCompletedImages(content)
    }

    mutating func mergeMessage(_ message: ConversationMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else { messages.append(message); messages.sort { $0.createdAt < $1.createdAt } }
    }

    private mutating func remember(_ event: BatonEvent) {
        seenEventSequences[event.id] = event.sequence; seenOrder.append(event.id)
        if seenOrder.count > maxSeenEvents {
            let removed = seenOrder.removeFirst()
            seenEventSequences.removeValue(forKey: removed)
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

    private func decodeSelectionState(_ value: JSONValue) -> SelectionInteractionState? {
        guard JSONSerialization.isValidJSONObject(value.foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationValue) else { return nil }
        return try? JSONDecoder().decode(SelectionInteractionState.self, from: data)
    }
}
