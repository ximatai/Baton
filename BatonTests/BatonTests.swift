//
//  BatonTests.swift
//  BatonTests
//
//  Created by 牧云踏歌 on 2026/8/26.
//

import Foundation
import Testing
@testable import Baton

struct BatonTests {
    @Test func pairingQRParserAcceptsOnlyAbsoluteURLs() {
        #expect(BatonPairingURLParser.parse("https://service.example/.well-known/baton/pair/abc")?.host == "service.example")
        #expect(BatonPairingURLParser.parse("  http://127.0.0.1:8787/.well-known/baton/pair/abc  ")?.host == "127.0.0.1")
        #expect(BatonPairingURLParser.parse("not a URL") == nil)
        #expect(BatonPairingURLParser.parse("baton://pair/abc") == nil)
        #expect(BatonPairingURLParser.parse("/relative/pairing") == nil)
    }

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

    @Test func resyncRequestsFreshSnapshotWithoutMutatingTimeline() {
        let snapshot = ConversationSnapshot(id: "conv_1", title: "Test", agentName: nil, messages: [message()], eventCursor: EventCursor(id: "evt_10", sequence: 10))
        var reducer = ConversationEventReducer()
        reducer.replaceSnapshot(snapshot)
        let required = reducer.apply(BatonEvent(id: "evt_99", sequence: 99, type: "conversation.resync", data: .object(["reason": .string("cursor_unknown_or_expired")])) )
        #expect(required)
        #expect(reducer.messages == [message()])
        #expect(reducer.cursor == EventCursor(id: "evt_10", sequence: 10))
    }

    @Test func outboxKeepsClientUUIDAcrossPersistence() throws {
        let credential = SessionCredential(accessToken: "test-token", deviceID: "ios_1", sessionID: "session_1", service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil), conversation: ConversationDescriptor(id: "conv_1", title: "Test", agentName: nil), conversationEndpoint: URL(string: "https://example.test/v1/baton/conversations/conv_1")!)
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let pending = PendingOutboxMessage(clientMessageID: uuid, text: "send this once", credential: credential)
        let restored = try JSONDecoder().decode(PendingOutboxMessage.self, from: JSONEncoder().encode(pending))
        #expect(restored.clientMessageID == uuid.uuidString)
        #expect(restored.belongs(to: credential))
    }

    @Test func unauthorizedResponseIsTerminalForSavedCredential() {
        let invalid = CompanionAPIError.server(status: 401, code: "invalid_token", message: "expired")
        #expect(invalid.invalidatesSessionCredential)
        #expect(!CompanionAPIError.server(status: 503, code: "temporary", message: "retry").invalidatesSessionCredential)
    }

    @Test func markdownRendererParsesCoreChatFormatting() {
        let source = """
        # 标题

        **粗体**、*斜体*、`code`，以及 [Baton](https://example.test)。

        - 第一项
        - 第二项

        ```swift
        let baton = \"ready\"
        ```
        """

        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered != nil)
        #expect(rendered.map { String($0.characters).contains("标题") } == true)
        #expect(rendered.map { String($0.characters).contains("let baton") } == true)
        #expect(rendered?.runs.contains(where: { $0.link == URL(string: "https://example.test") }) == true)
    }

    @Test func markdownRendererKeepsHTMLLookingInputAsText() {
        let source = "<script>alert('not executable')</script>"
        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered.map { String($0.characters) } == source)
    }

    @Test func markdownRendererDoesNotMixHTMLWithMarkdown() {
        let source = "**Baton** <em>不解释</em>"
        let rendered = BatonMarkdownRenderer.render(source)
        #expect(rendered.map { String($0.characters) } == source)
        #expect(rendered?.runs.contains(where: { $0.inlinePresentationIntent != nil }) == false)
    }
}
