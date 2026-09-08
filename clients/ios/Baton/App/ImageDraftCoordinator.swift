import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImageDraftCoordinator {
    struct NormalizedImage: @unchecked Sendable { let data: Data; let mimeType: String; let width: Int; let height: Int }
    struct Draft: Equatable, Identifiable {
        let id: UUID
        let fileURL: URL
        let mimeType: String
        let byteCount: Int
        let pixelCount: Int
        var uploadID: UUID
        var stagedMediaID: String?
    }

    private(set) var drafts: [Draft] = []
    private let directory: URL
    private var preparationError: Error?

    init(root: URL? = nil) {
        directory = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appending(path: "Baton/ImageDrafts", directoryHint: .isDirectory)
        do { try prepareDirectory(); clearOrphans() }
        catch { preparationError = error }
    }

    func importImages(_ input: [Data], policy: ImageUploadPolicy) throws {
        clear()
        try importNormalized(Self.normalizeImages(input, policy: policy))
    }
    func importNormalized(_ images: [NormalizedImage]) throws {
        if let preparationError { throw preparationError }
        try prepareDirectory()
        clear()
        for image in images { drafts.append(try save(image)) }
    }

    func clear() { drafts.forEach { try? FileManager.default.removeItem(at: $0.fileURL) }; drafts = [] }
    func clearOrphans() { try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).forEach { try? FileManager.default.removeItem(at: $0) } }
    func data(for draft: Draft) throws -> Data { try Data(contentsOf: draft.fileURL, options: [.mappedIfSafe]) }
    func draft(id: UUID) -> Draft? { drafts.first(where: { $0.id == id }) }
    func remove(id: UUID) { guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }; try? FileManager.default.removeItem(at: drafts[index].fileURL); drafts.remove(at: index) }
    func markStaged(_ mediaID: String, for draftID: UUID) { guard let i = drafts.firstIndex(where: { $0.id == draftID }) else { return }; drafts[i].stagedMediaID = mediaID }
    func resetUploads() { for i in drafts.indices { drafts[i].stagedMediaID = nil; drafts[i].uploadID = UUID() } }

    nonisolated static func normalizeImages(_ input: [Data], policy: ImageUploadPolicy) throws -> [NormalizedImage] {
        try input.prefix(policy.maxItemsPerMessage).map { try normalizeImage($0, policy: policy) }
    }

    nonisolated private static func normalizeImage(_ data: Data, policy: ImageUploadPolicy) throws -> NormalizedImage {
        // Check the source before decoding: animated assets are not silently
        // flattened, and malformed or huge dimensions never reach a bitmap.
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              !width.multipliedReportingOverflow(by: height).overflow,
              width.multipliedReportingOverflow(by: height).partialValue <= BatonImageLimits.maximumPixels else { throw CompanionAPIError.invalidImage }
        let outputMIME = policy.mimeTypes.contains("image/jpeg") ? "image/jpeg" : (policy.mimeTypes.contains("image/png") ? "image/png" : nil)
        guard let outputMIME,
              let outputType = UTType(mimeType: outputMIME)?.identifier as CFString? else { throw CompanionAPIError.invalidImage }
        let maxDimension = max(1, Int(Double(policy.maxPixelsPerItem).squareRoot()))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { throw CompanionAPIError.invalidImage }
        let normalized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(normalized, outputType, 1, nil) else { throw CompanionAPIError.invalidImage }
        let encoding: [CFString: Any] = outputMIME == "image/jpeg" ? [kCGImageDestinationLossyCompressionQuality: 0.82] : [:]
        // A new destination deliberately has no source metadata, including
        // orientation and location. The thumbnail transform bakes orientation.
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompanionAPIError.invalidImage }
        let normalizedData = normalized as Data
        guard normalizedData.count <= policy.maxBytesPerItem,
              let normalizedSource = CGImageSourceCreateWithData(normalizedData as CFData, nil),
              let normalizedProperties = CGImageSourceCopyPropertiesAtIndex(normalizedSource, 0, nil) as? [CFString: Any],
              let normalizedWidth = normalizedProperties[kCGImagePropertyPixelWidth] as? Int,
              let normalizedHeight = normalizedProperties[kCGImagePropertyPixelHeight] as? Int,
              !normalizedWidth.multipliedReportingOverflow(by: normalizedHeight).overflow,
              normalizedWidth.multipliedReportingOverflow(by: normalizedHeight).partialValue <= policy.maxPixelsPerItem else { throw CompanionAPIError.invalidImage }
        return NormalizedImage(data: normalizedData, mimeType: outputMIME, width: normalizedWidth, height: normalizedHeight)
    }

    private func save(_ image: NormalizedImage) throws -> Draft {
        let url = directory.appending(path: UUID().uuidString + ".image")
        do {
            try image.data.write(to: url, options: [.atomic])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutableURL = url; try mutableURL.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Draft(id: UUID(), fileURL: url, mimeType: image.mimeType, byteCount: image.data.count, pixelCount: image.width * image.height, uploadID: UUID(), stagedMediaID: nil)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
    }
}
