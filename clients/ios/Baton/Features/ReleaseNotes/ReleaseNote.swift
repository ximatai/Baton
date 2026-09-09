import Foundation

struct ReleaseNote: Identifiable, Equatable {
    struct Feature: Identifiable, Equatable {
        /// Stable across copy and localization revisions so a translated string
        /// never changes the read state for an otherwise identical feature.
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    let version: String
    /// Bump this when the release note changes without changing the app version.
    let revision: Int
    let features: [Feature]

    var id: String { "\(version)-\(revision)" }
}

enum ReleaseNotesRegistry {
    static let current = ReleaseNote(
        version: "1.26.3",
        revision: 1,
        features: [
            ReleaseNote.Feature(
                id: "photo-conversations",
                icon: "photo",
                title: String(localized: "图片对话"),
                detail: String(localized: "支持从相册选择图片，搭配文字发送，与 AI 继续交流。需要接入服务支持图片输入。")
            ),
            ReleaseNote.Feature(
                id: "pairing-experience",
                icon: "checkmark.circle",
                title: String(localized: "配对体验"),
                detail: String(localized: "扫码后的等待提示更清晰，加入成功时显示确认反馈，再自动进入对话。")
            )
        ]
    )

    static func note(for version: String) -> ReleaseNote? {
        notes.first { $0.version == version }
    }

    /// Keep earlier releases here when adding a new current release.
    static let notes: [ReleaseNote] = [current]
}

final class ReleaseNotesManager {
    static let shared = ReleaseNotesManager()

    private enum StorageKey {
        static let version = "release_notes.last_read_version"
        static let revision = "release_notes.last_read_revision"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func noteToShow(for currentVersion: String) -> ReleaseNote? {
        guard let note = ReleaseNotesRegistry.note(for: currentVersion), shouldShow(note) else { return nil }
        return note
    }

    func shouldShow(_ note: ReleaseNote) -> Bool {
        guard defaults.string(forKey: StorageKey.version) == note.version,
              defaults.object(forKey: StorageKey.revision) != nil else { return true }
        return defaults.integer(forKey: StorageKey.revision) != note.revision
    }

    func markRead(_ note: ReleaseNote) {
        defaults.set(note.version, forKey: StorageKey.version)
        defaults.set(note.revision, forKey: StorageKey.revision)
    }
}

enum BatonAppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ReleaseNotesRegistry.current.version
    }
}
