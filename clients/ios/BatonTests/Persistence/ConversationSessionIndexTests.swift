import Foundation
import Testing
@testable import Baton

struct ConversationSessionIndexTests {
    private func credential(
        sessionID: String,
        conversationID: String,
        host: String = "example.test"
    ) -> SessionCredential {
        SessionCredential(
            accessToken: "test-token-\(sessionID)",
            deviceID: "ios_test",
            sessionID: sessionID,
            service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil),
            conversation: ConversationDescriptor(id: conversationID, title: conversationID, agentName: nil),
            conversationEndpoint: URL(string: "https://\(host)/v1/baton/conversations/\(conversationID)")!
        )
    }

    @Test func sessionsAreKeptIndependentlyAndOrderedByLastActivation() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1")
        let second = credential(sessionID: "session_2", conversationID: "conv_2")
        let firstOpened = Date(timeIntervalSince1970: 100)
        let secondOpened = Date(timeIntervalSince1970: 200)

        let afterFirst = ConversationSessionIndex.upserting(first, into: [], at: firstOpened)
        let afterSecond = ConversationSessionIndex.upserting(second, into: afterFirst, at: secondOpened)
        #expect(afterSecond.map(\.id) == [second.conversationKey, first.conversationKey])

        let reactivatedFirst = ConversationSessionIndex.upserting(first, into: afterSecond, at: Date(timeIntervalSince1970: 300))
        #expect(reactivatedFirst.map(\.id) == [first.conversationKey, second.conversationKey])
        #expect(reactivatedFirst.count == 2)

        let remaining = ConversationSessionIndex.removing(conversationKey: first.conversationKey, from: reactivatedFirst)
        #expect(remaining.map(\.id) == [second.conversationKey])
    }

    @Test func aNewDeviceSessionReplacesTheExistingConversationEntry() {
        let original = credential(sessionID: "session_1", conversationID: "conv_1")
        let replacement = credential(sessionID: "session_2", conversationID: "conv_1")

        let originalEntries = ConversationSessionIndex.upserting(original, into: [], at: Date(timeIntervalSince1970: 100))
        let updatedEntries = ConversationSessionIndex.upserting(replacement, into: originalEntries, at: Date(timeIntervalSince1970: 200))

        #expect(updatedEntries.count == 1)
        #expect(updatedEntries.first?.id == original.conversationKey)
        #expect(updatedEntries.first?.credential.sessionID == "session_2")
    }

    @Test func identicalConversationIDsFromDifferentServiceOriginsStaySeparate() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1", host: "one.example.test")
        let second = credential(sessionID: "session_2", conversationID: "conv_1", host: "two.example.test")

        let entries = ConversationSessionIndex.upserting(
            second,
            into: ConversationSessionIndex.upserting(first, into: [], at: Date(timeIntervalSince1970: 100)),
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)) == Set([first.conversationKey, second.conversationKey]))
    }
}
