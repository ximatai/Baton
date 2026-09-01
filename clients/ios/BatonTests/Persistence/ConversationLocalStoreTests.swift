import Foundation
import Testing
@testable import Baton

@MainActor
struct ConversationLocalStoreTests {
    private func credential(conversationID: String = UUID().uuidString, sessionID: String = "session_test") -> SessionCredential {
        SessionCredential(
            accessToken: "test-token",
            deviceID: "ios_test",
            sessionID: sessionID,
            service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil),
            conversation: ConversationDescriptor(id: conversationID, title: "Cached", agentName: "Agent"),
            conversationEndpoint: URL(string: "https://example.test/v1/baton/conversations/\(conversationID)")!
        )
    }

    @Test func persistsAndRemovesOneConversationReplica() throws {
        let credential = credential()
        let store = ConversationLocalStore(credential: credential)
        defer { try? store.invalidateAndRemoveAll() }
        try store.removeAll()

        let message = ConversationMessage(
            id: "msg_1", clientMessageID: nil, conversationID: credential.conversation.id,
            role: .assistant, content: [.text("available offline")],
            createdAt: "2026-09-01T00:00:00Z", status: "completed"
        )
        let cursor = try #require(EventCursor(id: "evt_1", sequence: 1))
        try store.saveSnapshot(conversation: credential.conversation, messages: [message], cursor: cursor)
        try store.saveMedia(Data([0x01, 0x02]), mediaID: "media_1")

        let restoredSnapshot = try store.loadSnapshot(for: credential)
        let restored = try #require(restoredSnapshot)
        #expect(restored.messages == [message])
        #expect(restored.cursor == cursor)
        #expect(try store.mediaData(for: "media_1") == Data([0x01, 0x02]))

        try store.removeAll()
        #expect(try store.loadSnapshot(for: credential) == nil)
        #expect(try store.mediaData(for: "media_1") == nil)
    }

    @Test func invalidatedLeaseCannotRecreateADeletedReplica() throws {
        let conversationID = UUID().uuidString
        let oldCredential = credential(conversationID: conversationID, sessionID: "session_old")
        let oldStore = ConversationLocalStore(credential: oldCredential)
        try oldStore.removeAll()
        try oldStore.saveMedia(Data([0x01]), mediaID: "old_media")

        try oldStore.invalidateAndRemoveAll()
        try oldStore.saveMedia(Data([0x02]), mediaID: "late_media")
        #expect(try oldStore.mediaData(for: "late_media") == nil)

        let replacementCredential = credential(conversationID: conversationID, sessionID: "session_new")
        let replacementStore = ConversationLocalStore(credential: replacementCredential)
        defer { try? replacementStore.invalidateAndRemoveAll() }
        try oldStore.saveMedia(Data([0x03]), mediaID: "stale_media")
        #expect(try replacementStore.mediaData(for: "stale_media") == nil)

        try replacementStore.saveMedia(Data([0x04]), mediaID: "new_media")
        #expect(try replacementStore.mediaData(for: "new_media") == Data([0x04]))
    }
}
