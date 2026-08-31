import Foundation
import Testing
@testable import Baton

@MainActor
struct ConversationReducerTests {
    private func message(id: String = "msg_1", text: String = "hello") -> ConversationMessage {
        ConversationMessage(id: id, clientMessageID: nil, conversationID: "conv_1", role: .assistant, content: [.text(text)], createdAt: "2026-08-26T00:00:00Z", status: "streaming")
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

    @Test func messagePreservesOrderedImageAndTextContentAndSafelyDowngradesUnknownItems() throws {
        let json = """
        {"id":"msg_1","conversation_id":"conv_1","role":"assistant","content":[{"type":"text","text":"趋势图："},{"type":"image","url":"https://service.example/v1/baton/media/chart.png","mime_type":"image/png","width":640,"height":400,"alt":"月度趋势图"},{"type":"future_card","alt":"稍后支持的卡片"},{"type":"text","text":"已附上。"}],"created_at":"2026-08-26T00:00:00Z","status":"completed"}
        """
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(message.content.count == 4)
        #expect(message.text == "趋势图：已附上。")
        #expect(message.content[1].image?.alt == "月度趋势图")
        #expect(message.content[2] == .unsupported(type: "future_card", alt: "稍后支持的卡片"))
    }

    @Test func malformedOrUnsupportedImageSafelyBecomesUnsupportedContent() throws {
        let json = #"[{"type":"image","url":"https://service.example/image.svg","mime_type":"image/svg+xml","width":1,"height":1,"alt":"不支持"}]"#
        let content = try JSONDecoder().decode([MessageContent].self, from: Data(json.utf8))
        #expect(content == [.unsupported(type: "image", alt: "不支持")])
    }

    @Test func deltaAfterImageOrForUnknownMessageRequestsResynchronization() {
        let image = MessageImage(url: URL(string: "https://service.example/chart.png")!, mimeType: "image/png", width: 2, height: 2, alt: "图")
        let completed = ConversationMessage(id: "msg_image", clientMessageID: nil, conversationID: "conv_1", role: .assistant, content: [.text("图："), .image(image)], createdAt: "2026-08-26T00:00:00Z", status: "completed")
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [completed], eventCursor: EventCursor(id: "evt_10", sequence: 10)))
        let afterImage = BatonEvent(id: "evt_11", sequence: 11, type: "message.delta", data: .object(["message_id": .string("msg_image"), "delta": .string("错序")]))
        let imageRequiresResync = reducer.apply(afterImage)
        #expect(imageRequiresResync)
        #expect(reducer.messages == [completed])

        reducer.replaceSnapshot(ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [], eventCursor: EventCursor(id: "evt_10", sequence: 10)))
        let orphan = BatonEvent(id: "evt_11", sequence: 11, type: "message.delta", data: .object(["message_id": .string("unknown"), "delta": .string("错序")]))
        let orphanRequiresResync = reducer.apply(orphan)
        #expect(orphanRequiresResync)
    }

    @Test func userStreamingMessageAndInvalidStreamingSnapshotAreRejectedWithoutMutation() {
        let userStreaming = ConversationMessage(id: "msg_user", clientMessageID: nil, conversationID: "conv_1", role: .user, content: [.text("不合法")], createdAt: "2026-08-26T00:00:00Z", status: "streaming")
        var reducer = ConversationEventReducer()
        let initial = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [message()], eventCursor: EventCursor(id: "evt_10", sequence: 10))
        let acceptedInitial = reducer.replaceSnapshot(initial)
        #expect(acceptedInitial)
        let invalid = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [userStreaming], eventCursor: EventCursor(id: "evt_11", sequence: 11))
        let acceptedInvalid = reducer.replaceSnapshot(invalid)
        #expect(!acceptedInvalid)
        #expect(reducer.messages == [message()])
        #expect(reducer.cursor == EventCursor(id: "evt_10", sequence: 10))

        let created = BatonEvent(id: "evt_11", sequence: 11, type: "message.created", data: .object(["message": .object([
            "id": .string("msg_user"), "conversation_id": .string("conv_1"), "role": .string("user"),
            "content": .array([.object(["type": .string("text"), "text": .string("不合法")])]),
            "created_at": .string("2026-08-26T00:00:00Z"), "status": .string("streaming")
        ])]))
        let createdRequiresResync = reducer.apply(created)
        #expect(createdRequiresResync)
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
