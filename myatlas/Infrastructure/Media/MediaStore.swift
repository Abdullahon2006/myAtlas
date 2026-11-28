import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaStorageBreakdown: Equatable, Sendable {
    let photoBytes: Int64
    let thumbnailBytes: Int64
    let voiceBytes: Int64

    var totalBytes: Int64 {
        photoBytes + thumbnailBytes + voiceBytes
    }
}

actor MediaStore {
    enum MediaStoreError: LocalizedError {
        case invalidFilename
        case invalidImageData
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidFilename:
                "The media filename is invalid."
            case .invalidImageData:
                "The selected image could not be decoded."
            case .encodingFailed:
                "The photo could not be compressed for local storage."
            }
        }
    }

    struct SavedPhotoResult: Sendable {
        let filename: String
        let thumbnailFilename: String?
        let byteSize: Int64
    }

    private let baseDirectory: URL
    private let photosDirectory: URL
    private let thumbnailsDirectory: URL
    private let voiceDirectory: URL

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            root = applicationSupport.appendingPathComponent("Media", isDirectory: true)
        }

        self.baseDirectory = root
        self.photosDirectory = root.appendingPathComponent("Photos", isDirectory: true)
        self.thumbnailsDirectory = root.appendingPathComponent("Thumbnails", isDirectory: true)
        self.voiceDirectory = root.appendingPathComponent("Voice", isDirectory: true)

        try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)

        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(exclusion)
    }

    func save(_ data: Data, filename: String) throws -> URL {
        let url = try validatedURL(for: filename, in: photosDirectory)
        try Self.writeProtected(data, to: url)
        return url
    }

    /// Re-encodes oversized photos to compressed JPEG and generates a fast thumbnail off the main thread.
    func saveProcessedPhoto(_ data: Data, attachmentID: UUID = UUID()) throws -> SavedPhotoResult {
        guard !data.isEmpty else {
            throw MediaStoreError.invalidImageData
        }
        guard let fullData = Self.downsampleJPEG(from: data, maxPixelSize: 2048, quality: 0.85), !fullData.isEmpty else {
            throw MediaStoreError.encodingFailed
        }

        let filename = "\(attachmentID.uuidString).jpg"
        let photoURL = try validatedURL(for: filename, in: photosDirectory)
        try Self.writeProtected(fullData, to: photoURL)

        var savedThumbName: String?
        let thumbFilename = "\(attachmentID.uuidString)_thumb.jpg"
        if let thumbData = Self.downsampleJPEG(from: fullData, maxPixelSize: 360, quality: 0.78),
           let thumbURL = try? validatedURL(for: thumbFilename, in: thumbnailsDirectory),
           (try? Self.writeProtected(thumbData, to: thumbURL)) != nil {
            savedThumbName = thumbFilename
        }

        return SavedPhotoResult(
            filename: filename,
            thumbnailFilename: savedThumbName,
            byteSize: Int64(fullData.count)
        )
    }

    func saveVoiceRecording(from temporaryURL: URL, attachmentID: UUID = UUID()) throws -> (filename: String, byteSize: Int64) {
        let filename = "\(attachmentID.uuidString).m4a"
        let destination = try validatedURL(for: filename, in: voiceDirectory)
        let audioData = try Data(contentsOf: temporaryURL)
        try Self.writeProtected(audioData, to: destination)
        return (filename, Int64(audioData.count))
    }

    func data(for attachment: PlaceAttachment) throws -> Data {
        switch attachment.kind {
        case .photo:
            let primary = try validatedURL(for: attachment.filename, in: photosDirectory)
            if FileManager.default.fileExists(atPath: primary.path) {
                return try Data(contentsOf: primary)
            }
            // Fallback for legacy v1 attachments stored directly under baseDirectory.
            let legacy = try validatedURL(for: attachment.filename, in: baseDirectory)
            return try Data(contentsOf: legacy)
        case .voice:
            let url = try validatedURL(for: attachment.filename, in: voiceDirectory)
            return try Data(contentsOf: url)
        }
    }

    func thumbnailData(for attachment: PlaceAttachment) -> Data? {
        guard attachment.kind == .photo else { return nil }
        if let thumb = attachment.thumbnailFilename,
           let thumbURL = try? validatedURL(for: thumb, in: thumbnailsDirectory),
           let data = try? Data(contentsOf: thumbURL) {
            return data
        }
        guard let fullData = try? data(for: attachment),
              let generatedThumb = Self.downsampleJPEG(from: fullData, maxPixelSize: 360, quality: 0.78) else {
            return nil
        }
        if let thumb = attachment.thumbnailFilename,
           let thumbURL = try? validatedURL(for: thumb, in: thumbnailsDirectory) {
            try? Self.writeProtected(generatedThumb, to: thumbURL)
        }
        return generatedThumb
    }

    nonisolated func fileURL(for attachment: PlaceAttachment) -> URL? {
        guard Self.isValidFilename(attachment.filename) else { return nil }
        switch attachment.kind {
        case .photo:
            let candidate = photosDirectory.appendingPathComponent(attachment.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            return baseDirectory.appendingPathComponent(attachment.filename)
        case .voice:
            return voiceDirectory.appendingPathComponent(attachment.filename)
        }
    }

    func remove(_ attachment: PlaceAttachment) throws {
        switch attachment.kind {
        case .photo:
            let photoURL = try validatedURL(for: attachment.filename, in: photosDirectory)
            if FileManager.default.fileExists(atPath: photoURL.path) {
                try FileManager.default.removeItem(at: photoURL)
            }
            if let legacyURL = try? validatedURL(for: attachment.filename, in: baseDirectory),
               FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            if let thumb = attachment.thumbnailFilename,
               let thumbURL = try? validatedURL(for: thumb, in: thumbnailsDirectory),
               FileManager.default.fileExists(atPath: thumbURL.path) {
                try? FileManager.default.removeItem(at: thumbURL)
            }
        case .voice:
            let voiceURL = try validatedURL(for: attachment.filename, in: voiceDirectory)
            if FileManager.default.fileExists(atPath: voiceURL.path) {
                try FileManager.default.removeItem(at: voiceURL)
            }
        }
    }

    func removeAll(_ attachments: [PlaceAttachment]) {
        for attachment in attachments {
            try? remove(attachment)
        }
    }

    func exportEmbeddedMedia(for attachments: [PlaceAttachment]) -> [EmbeddedMedia] {
        attachments.compactMap { attachment in
            guard let bytes = try? data(for: attachment), !bytes.isEmpty else { return nil }
            return EmbeddedMedia(
                attachmentID: attachment.id,
                kind: attachment.kind,
                filename: attachment.filename,
                data: bytes
            )
        }
    }

    func importEmbeddedMedia(_ items: [EmbeddedMedia]) {
        for item in items {
            switch item.kind {
            case .photo:
                if let url = try? validatedURL(for: item.filename, in: photosDirectory) {
                    try? Self.writeProtected(item.data, to: url)
                }
            case .voice:
                if let url = try? validatedURL(for: item.filename, in: voiceDirectory) {
                    try? Self.writeProtected(item.data, to: url)
                }
            }
        }
    }

    func storageBreakdown() -> MediaStorageBreakdown {
        MediaStorageBreakdown(
            photoBytes: Self.directoryByteSize(photosDirectory, excludeSubdirectories: true)
                + Self.directoryByteSize(baseDirectory, excludeSubdirectories: true),
            thumbnailBytes: Self.directoryByteSize(thumbnailsDirectory, excludeSubdirectories: true),
            voiceBytes: Self.directoryByteSize(voiceDirectory, excludeSubdirectories: true)
        )
    }

    // MARK: - Private

    private func validatedURL(for filename: String, in directory: URL) throws -> URL {
        guard Self.isValidFilename(filename) else {
            throw MediaStoreError.invalidFilename
        }
        let candidate = directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        let expectedDir = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedDir else {
            throw MediaStoreError.invalidFilename
        }
        return candidate
    }

    private nonisolated static func isValidFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && !filename.contains("..")
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private static func directoryByteSize(_ directory: URL, excludeSubdirectories: Bool) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            if excludeSubdirectories && values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func downsampleJPEG(from data: Data, maxPixelSize: Int, quality: CGFloat) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}
