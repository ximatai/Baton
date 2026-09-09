import XCTest
import ImageIO
@testable import Baton

@MainActor
final class ImageDraftCoordinatorTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL3xQAAAABJRU5ErkJggg==")!
    private var policy: ImageUploadPolicy { ImageUploadPolicy(maxItemsPerMessage: 4, maxBytesPerItem: 1024, maxPixelsPerItem: 100, mimeTypes: ["image/png"]) }

    func testImportWritesProtectedBackupExcludedDraftAndStableUploadIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ImageDraftCoordinator(root: root)
        try coordinator.importImages([png], policy: policy)
        let draft = try XCTUnwrap(coordinator.drafts.first)
        XCTAssertEqual(draft.mimeType, "image/png")
        let stored = try coordinator.data(for: draft)
        XCTAssertNotNil(CGImageSourceCreateWithData(stored as CFData, nil))
        var freshFile = URL(fileURLWithPath: draft.fileURL.path); freshFile.removeAllCachedResourceValues()
        var freshDirectory = URL(fileURLWithPath: root.appending(path: "Baton/ImageDrafts").path); freshDirectory.removeAllCachedResourceValues()
        XCTAssertTrue(try freshDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false)
        XCTAssertTrue(try freshFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false)
        let uploadID = draft.uploadID
        coordinator.markStaged("med_staged", for: draft.id)
        XCTAssertEqual(coordinator.drafts.first?.uploadID, uploadID)
        XCTAssertEqual(coordinator.drafts.first?.stagedMediaID, "med_staged")
        coordinator.resetUploads()
        XCTAssertNotEqual(coordinator.drafts.first?.uploadID, uploadID)
        XCTAssertNil(coordinator.drafts.first?.stagedMediaID)
        coordinator.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.fileURL.path))
    }

    func testDraftDirectoryUsesCompleteFileProtectionWhenAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ImageDraftCoordinator(root: root)
        try coordinator.importImages([png], policy: policy)
        let freshDirectory = URL(fileURLWithPath: root.appending(path: "Baton/ImageDrafts").path)
        guard let protection = try FileManager.default.attributesOfItem(atPath: freshDirectory.path)[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("The iOS Simulator filesystem does not expose NSFileProtection attributes; verify this assertion on a physical device.")
        }
        XCTAssertEqual(protection, .complete)
    }

    func testRejectsUnsupportedMimeAndAnimatedOrOversizedPolicy() {
        let coordinator = ImageDraftCoordinator(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        XCTAssertThrowsError(try coordinator.importImages([png], policy: ImageUploadPolicy(maxItemsPerMessage: 1, maxBytesPerItem: 10, maxPixelsPerItem: 1, mimeTypes: ["image/jpeg"])))
    }

    func testLegacyCredentialDecodesWithoutUploadPolicy() throws {
        let json = #"{"accessToken":"x","deviceID":"d","sessionID":"s","service":{"id":"svc","name":"S"},"conversation":{"id":"c","title":"C"},"conversationEndpoint":"https://example.com/v1/baton/conversations/c","canEndConversation":false}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(SessionCredential.self, from: json).imageUploadPolicy)
    }
}
