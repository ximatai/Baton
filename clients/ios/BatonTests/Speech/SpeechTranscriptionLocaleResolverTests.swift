import Foundation
import Testing
@testable import Baton

struct SpeechTranscriptionLocaleResolverTests {
    @Test func simplifiedChinesePrefersSystemLanguageOverRegionalLocale() {
        let locale = SpeechTranscriptionLocaleResolver.preferredRequestLocale(
            currentLocale: Locale(identifier: "en_US"),
            preferredLanguageIdentifiers: ["zh-Hans-CN", "en-US"]
        )

        #expect(locale.language.languageCode?.identifier == "zh")
        #expect(locale.language.script?.identifier == "Hans")

        let candidates = SpeechTranscriptionLocaleResolver.candidates(for: locale)
        #expect(candidates.first?.language.languageCode?.identifier == "zh")
        #expect(candidates.contains { $0.language.script?.identifier == "Hans" })
        #expect(candidates.contains { $0.region?.identifier == "CN" })
    }

    @Test func nonChineseKeepsCurrentLocale() {
        let current = Locale(identifier: "ja_JP")
        let locale = SpeechTranscriptionLocaleResolver.preferredRequestLocale(
            currentLocale: current,
            preferredLanguageIdentifiers: ["ja-JP"]
        )

        #expect(locale.identifier == current.identifier)
        #expect(SpeechTranscriptionLocaleResolver.candidates(for: locale).map(\.identifier) == [current.identifier])
    }

    @Test func traditionalChineseDoesNotFallbackToSimplifiedCandidates() {
        let traditional = Locale(identifier: "zh-Hant-TW")

        #expect(SpeechTranscriptionLocaleResolver.candidates(for: traditional).map(\.identifier) == [traditional.identifier])
    }
}
