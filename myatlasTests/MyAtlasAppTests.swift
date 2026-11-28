import UIKit
import XCTest
@testable import myatlas

@MainActor
final class MyAtlasAppTests: XCTestCase {
    func testSaveNewPlaceWithPhotoGeneratesThumbnailAndCleansUpDiskOnDelete() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = AtlasStore(persistenceURL: tempRoot.appendingPathComponent("atlas.json"))
        let mediaRoot = tempRoot.appendingPathComponent("Media", isDirectory: true)
        let mediaStore = try MediaStore(baseDirectory: mediaRoot)
        let viewModel = AtlasViewModel(store: store, mediaStore: mediaStore)

        let imageData = makeTestJPEGData()
        let saved = await viewModel.saveNewPlace(
            name: "  Belem Tower  ",
            subtitle: "  Lisbon, PT  ",
            latitude: 38.6916,
            longitude: -9.2160,
            visitedAt: .now,
            category: .culture,
            isFavorite: true,
            rating: 5,
            note: "  River breeze  ",
            photoItemsData: [imageData],
            pendingVoiceURL: nil,
            pendingVoiceDuration: 0
        )

        XCTAssertEqual(saved.name, "Belem Tower")
        XCTAssertEqual(saved.subtitle, "Lisbon, PT")
        XCTAssertEqual(saved.note, "River breeze")
        XCTAssertEqual(saved.attachmentCount, 1)

        let attachments = viewModel.attachments(for: saved.id)
        XCTAssertEqual(attachments.count, 1)
        let thumbImage = await viewModel.loadThumbnailImage(for: attachments[0])
        XCTAssertNotNil(thumbImage)

        let photoURL = mediaStore.fileURL(for: attachments[0])
        XCTAssertNotNil(photoURL)
        if let photoURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
        }

        viewModel.delete(place: saved)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(viewModel.places.isEmpty)
        XCTAssertTrue(viewModel.attachments.isEmpty)
        if let photoURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: photoURL.path))
        }
    }

    func testCompleteBackupArchiveRoundTripRestoresPlacesAndMedia() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sourceStore = AtlasStore(persistenceURL: tempRoot.appendingPathComponent("source.json"))
        let sourceMedia = try MediaStore(baseDirectory: tempRoot.appendingPathComponent("SourceMedia", isDirectory: true))
        let sourceVM = AtlasViewModel(store: sourceStore, mediaStore: sourceMedia)

        let saved = await sourceVM.saveNewPlace(
            name: "Alfama",
            subtitle: "Lisbon",
            latitude: 38.7117,
            longitude: -9.1303,
            visitedAt: .now,
            category: .gem,
            isFavorite: true,
            rating: 5,
            note: "Tiled alleys",
            photoItemsData: [makeTestJPEGData()],
            pendingVoiceURL: nil,
            pendingVoiceDuration: 0
        )

        let backupData = try await sourceVM.buildCompleteBackupData()

        let targetStore = AtlasStore(persistenceURL: tempRoot.appendingPathComponent("target.json"))
        let targetMedia = try MediaStore(baseDirectory: tempRoot.appendingPathComponent("TargetMedia", isDirectory: true))
        let targetVM = AtlasViewModel(store: targetStore, mediaStore: targetMedia)

        let restoredCount = try await targetVM.importBackup(from: backupData, merge: false)
        XCTAssertEqual(restoredCount, 1)
        XCTAssertEqual(targetVM.places.first?.id, saved.id)
        XCTAssertEqual(targetVM.attachments.count, 1)
        let restoredThumb = await targetVM.loadThumbnailImage(for: targetVM.attachments[0])
        XCTAssertNotNil(restoredThumb)
    }

    func testMediaStoreRejectsInvalidFilenamesAndInvalidImages() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mediaStore = try MediaStore(baseDirectory: tempRoot)

        for badName in ["", ".", "..", "Thumbnails", "a/b.jpg", "../escape.jpg"] {
            do {
                _ = try await mediaStore.save(Data([1, 2, 3]), filename: badName)
                if badName != "Thumbnails" {
                    XCTFail("Expected invalidFilename for \(badName)")
                }
            } catch {
                // Expected for invalid paths.
            }
        }

        do {
            _ = try await mediaStore.saveProcessedPhoto(Data("not an image".utf8))
            XCTFail("Expected encoding error for non-image bytes")
        } catch {
            // Expected.
        }
    }

    func testDownloadAndCancelRegionViaProvider() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let provider = MockSlowMapProvider()
        let store = AtlasStore(persistenceURL: tempRoot.appendingPathComponent("atlas.json"))
        let mediaStore = try MediaStore(baseDirectory: tempRoot.appendingPathComponent("Media", isDirectory: true))
        let viewModel = AtlasViewModel(store: store, mediaStore: mediaStore, mapProvider: provider)

        let tokyo = AtlasCatalog.regions[1]
        viewModel.download(region: tokyo)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(viewModel.regions.first?.downloadState.isDownloading == true)

        viewModel.cancelDownload(for: tokyo)
        XCTAssertEqual(viewModel.regions.first?.downloadState, .available)

        // Immediate retry after cancel must not be clobbered by old task cancellation.
        viewModel.download(region: tokyo)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(viewModel.regions.first?.downloadState, .downloaded)
    }

    private func makeTestJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

private struct MockSlowMapProvider: MapProvider {
    let configuration = MapProviderConfiguration.localBoundary

    func downloadRegion(_ region: AtlasRegion, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        for step in 1...5 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(60))
            onProgress(Double(step) / 5.0)
        }
    }

    func removeRegion(_ region: AtlasRegion) async throws {}

    func totalStoredPackBytes() async -> Int64 { 0 }
}
