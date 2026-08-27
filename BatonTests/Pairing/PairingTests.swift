import Foundation
import Testing
@testable import Baton

@MainActor
struct PairingTests {
    @Test func pairingQRParserAcceptsOnlyAbsoluteURLs() {
        #expect(BatonPairingURLParser.parse("https://service.example/.well-known/baton/pair/abc")?.host == "service.example")
        #expect(BatonPairingURLParser.parse("  http://127.0.0.1:8787/.well-known/baton/pair/abc  ")?.host == "127.0.0.1")
        #expect(BatonPairingURLParser.parse("not a URL") == nil)
        #expect(BatonPairingURLParser.parse("baton://pair/abc") == nil)
        #expect(BatonPairingURLParser.parse("/relative/pairing") == nil)
    }

    @Test func unauthorizedResponseIsTerminalForSavedCredential() {
        let invalid = CompanionAPIError.server(status: 401, code: "invalid_token", message: "expired")
        #expect(invalid.invalidatesSessionCredential)
        #expect(!CompanionAPIError.server(status: 503, code: "temporary", message: "retry").invalidatesSessionCredential)
        #expect(CompanionAPIError.server(status: 410, code: "conversation_closed", message: "ended").closesConversation)
        #expect(!CompanionAPIError.server(status: 410, code: "pairing_expired", message: "expired").closesConversation)
    }

    @Test func debugHTTPPolicyAcceptsOnlyPrivateIPv4OrLoopback() {
        #expect(BatonDebugHTTPHostPolicy.allows("172.20.1.2"))
        #expect(BatonDebugHTTPHostPolicy.allows("10.0.0.8"))
        #expect(BatonDebugHTTPHostPolicy.allows("192.168.1.2"))
        #expect(!BatonDebugHTTPHostPolicy.allows("172.32.0.1"))
        #expect(!BatonDebugHTTPHostPolicy.allows("8.8.8.8"))
        #expect(!BatonDebugHTTPHostPolicy.allows("example.com"))
    }
}
