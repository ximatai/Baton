import Foundation
import Testing
@testable import Baton

struct ReleaseNotesTests {
    @Test func currentReleaseHasStableFeatureIdentifiers() {
        let note = ReleaseNotesRegistry.current

        #expect(note.version == "1.26.3")
        #expect(note.revision == 1)
        #expect(note.features.map(\.id) == ["photo-conversations", "pairing-experience"])
        #expect(note.features.map(\.icon) == ["photo", "checkmark.circle"])
    }

    @Test func currentReleaseShowsOnceThenStaysRead() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let manager = ReleaseNotesManager(defaults: defaults)
        let note = ReleaseNotesRegistry.current

        #expect(manager.noteToShow(for: note.version) == note)
        manager.markRead(note)
        #expect(manager.noteToShow(for: note.version) == nil)
    }

    @Test func revisionChangesShowAgainWithoutDependingOnLocalizedCopy() {
        let defaults = makeDefaults(suiteName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let manager = ReleaseNotesManager(defaults: defaults)
        let english = ReleaseNote(
            version: "1.26.3",
            revision: 7,
            features: [.init(id: "feature", icon: "star", title: "Images", detail: "English copy")]
        )
        let localized = ReleaseNote(
            version: "1.26.3",
            revision: 7,
            features: [.init(id: "feature", icon: "star", title: "图片", detail: "中文文案")]
        )
        let revised = ReleaseNote(version: "1.26.3", revision: 8, features: localized.features)

        manager.markRead(english)
        #expect(!manager.shouldShow(localized))
        #expect(manager.shouldShow(revised))
    }

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
