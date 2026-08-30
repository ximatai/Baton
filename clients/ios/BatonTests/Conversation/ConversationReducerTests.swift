import Foundation
import Testing
@testable import Baton

@MainActor
struct ConversationReducerTests {
    private func message(id: String = "msg_1", text: String = "hello") -> ConversationMessage {
        ConversationMessage(id: id, clientMessageID: nil, conversationID: "conv_1", role: .assistant, content: [MessageContent(type: "text", text: text)], createdAt: "2026-08-26T00:00:00Z", status: "streaming")
    }

    @Test func snapshotCursorIsDecodedAndStaleDeltasAreIgnored() throws {
        let json = """
        {"id":"conv_1","title":"Test","messages":[{"id":"msg_1","conversation_id":"conv_1","role":"assistant","content":[{"type":"text","text":"hello"}],"created_at":"2026-08-26T00:00:00Z","status":"streaming"}],"event_cursor":{"id":"evt_10","sequence":10}}
        """
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.eventCursor == EventCursor(id: "evt_10", sequence: 10))

        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(snapshot)
        _ = reducer.apply(BatonEvent(id: "evt_10", sequence: 10, type: "message.delta", data: .object(["message_id": .string("msg_1"), "delta": .string(" again")])))
        #expect(reducer.messages[0].text == "hello")
        #expect(reducer.cursor == EventCursor(id: "evt_10", sequence: 10))
    }

    @Test func duplicateDeltaIsAppliedOnlyOnce() {
        let snapshot = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [message()], eventCursor: EventCursor(id: "evt_10", sequence: 10))
        let delta = BatonEvent(id: "evt_11", sequence: 11, type: "message.delta", data: .object(["message_id": .string("msg_1"), "delta": .string(" world")]))
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(snapshot)
        _ = reducer.apply(delta)
        _ = reducer.apply(delta)
        #expect(reducer.messages[0].text == "hello world")
        #expect(reducer.cursor == EventCursor(id: "evt_11", sequence: 11))
    }

    @Test func createdMessageIsReadFromEventMessageEnvelope() {
        let created = BatonEvent(
            id: "evt_11",
            sequence: 11,
            type: "message.created",
            data: .object(["message": .object([
                "id": .string("msg_user_1"),
                "client_message_id": .string("11111111-2222-3333-4444-555555555555"),
                "conversation_id": .string("conv_1"),
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string("from web")])]),
                "created_at": .string("2026-08-26T00:00:01Z"),
                "status": .string("completed")
            ])])
        )
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [], eventCursor: EventCursor(id: "evt_10", sequence: 10)))

        let mustResynchronize = reducer.apply(created)
        #expect(!mustResynchronize)
        #expect(reducer.messages.map(\.text) == ["from web"])
        #expect(reducer.messages.first?.role == .user)
    }

    @Test func resyncRequestsFreshSnapshotWithoutMutatingTimeline() {
        let snapshot = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [message()], eventCursor: EventCursor(id: "evt_10", sequence: 10))
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(snapshot)
        let required = reducer.apply(BatonEvent(id: "evt_99", sequence: 99, type: "conversation.resync", data: .object(["reason": .string("cursor_unknown_or_expired")])))
        #expect(required)
        #expect(reducer.messages == [message()])
        #expect(reducer.cursor == EventCursor(id: "evt_10", sequence: 10))
    }

    @Test func sequenceGapRequiresSnapshotInsteadOfSilentlySkippingAnEvent() {
        let snapshot = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [message()], eventCursor: EventCursor(id: "evt_10", sequence: 10))
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(snapshot)

        let required = reducer.apply(BatonEvent(id: "evt_12", sequence: 12, type: "message.delta", data: .object(["message_id": .string("msg_1"), "delta": .string(" lost") ])))

        #expect(required)
        #expect(reducer.messages == [message()])
        #expect(reducer.cursor == EventCursor(id: "evt_10", sequence: 10))
    }

    @Test func snapshotDecodesActiveRunsForReconnectCancellation() throws {
        let json = """
        {"id":"conv_1","title":"Test","messages":[],"event_cursor":{"id":"evt_10","sequence":10},"active_runs":[{"run_id":"run_1","status":"active","message_id":"msg_1"}]}
        """
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.activeRuns == [ActiveRun(id: "run_1", status: "active", messageID: "msg_1")])
        #expect(snapshot.activeRuns[0].isLive)
        #expect(ActiveRun.current(in: snapshot.activeRuns)?.id == "run_1")
    }

    @Test func outboxKeepsClientUUIDAcrossPersistence() throws {
        let credential = SessionCredential(accessToken: "test-token", deviceID: "ios_1", sessionID: "session_1", service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil), conversation: ConversationDescriptor(id: "conv_1", title: "Test", agentName: nil), conversationEndpoint: URL(string: "https://example.test/v1/baton/conversations/conv_1")!)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let pending = PendingOutboxMessage(clientMessageID: uuid, text: "send this once", credential: credential)
        let restored = try JSONDecoder().decode(PendingOutboxMessage.self, from: JSONEncoder().encode(pending))
        #expect(restored.clientMessageID == uuid.uuidString)
        #expect(restored.belongs(to: credential))
    }

    @Test func credentialsRejectSnapshotsForAnotherConversation() {
        let credential = SessionCredential(accessToken: "test-token", deviceID: "ios_1", sessionID: "session_1", service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil), conversation: ConversationDescriptor(id: "conv_1", title: "Test", agentName: nil), conversationEndpoint: URL(string: "https://example.test/v1/baton/conversations/conv_1")!)

        #expect(credential.ownsConversation(id: "conv_1"))
        #expect(!credential.ownsConversation(id: "conv_other"))
    }
}
