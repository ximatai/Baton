import Foundation
import Testing
@testable import Baton

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
    }
}
