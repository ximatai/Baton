import Foundation

/// Ephemeral delivery state for a Keychain-backed outbox item. The message
/// itself (including its client message ID) remains the durable source of
/// truth; this state is deliberately rebuilt as `.queued` after relaunch.
enum OutboxDeliveryState: Equatable {
    case queued
    case sending
    case retrying
    case needsUserAction

    var canRetry: Bool {
        switch self {
        case .queued, .needsUserAction: true
        case .sending, .retrying: false
        }
    }
}

struct OutboxItemPresentation: Identifiable, Equatable {
    let message: PendingOutboxMessage
    let state: OutboxDeliveryState

    var id: String { message.clientMessageID }
}

/// The full identity of one persisted request. A UUID collision must never
/// make delivery work in a different device session block this request.
struct OutboxDeliveryIdentity: Hashable {
    let clientMessageID: String
    let conversationID: String
    let conversationEndpoint: URL
    let sessionID: String
    let deviceID: String

    init(_ pending: PendingOutboxMessage) {
        clientMessageID = pending.clientMessageID
        conversationID = pending.conversationID
        conversationEndpoint = pending.conversationEndpoint
        sessionID = pending.sessionID
        deviceID = pending.deviceID
    }
}

/// Main-actor-owned coordination for one delivery chain per persisted request.
/// Persisted presence remains the authority for whether a retry may continue
/// after local discard.
struct OutboxDeliveryRegistry {
    private var activeRequests = Set<OutboxDeliveryIdentity>()

    mutating func claim(_ pending: PendingOutboxMessage) -> Bool {
        activeRequests.insert(OutboxDeliveryIdentity(pending)).inserted
    }

    mutating func release(_ pending: PendingOutboxMessage) {
        activeRequests.remove(OutboxDeliveryIdentity(pending))
    }
}

/// Pure projection shared by the view model and tests. No delivery metadata is
/// persisted, so a restored message is intentionally shown as waiting to send.
enum OutboxPresentation {
    /// A delivery attempt is valid only while its exact persisted request still
    /// exists for the credential that started it. This makes local discard win
    /// over a pending retry without affecting another conversation.
    static func contains(
        _ pending: PendingOutboxMessage,
        in messages: [PendingOutboxMessage],
        for credential: SessionCredential
    ) -> Bool {
        messages.contains { $0 == pending && $0.belongs(to: credential) }
    }

    static func items(
        from messages: [PendingOutboxMessage],
        states: [String: OutboxDeliveryState]
    ) -> [OutboxItemPresentation] {
        messages.map { message in
            OutboxItemPresentation(message: message, state: states[message.clientMessageID] ?? .queued)
        }
    }

    static func stateAfterFailure(attemptsRemaining: Int, maintainsConnection: Bool) -> OutboxDeliveryState {
        attemptsRemaining > 1 && maintainsConnection ? .retrying : .needsUserAction
    }
}
