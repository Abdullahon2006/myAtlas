import Foundation
import SwiftUI
import UIKit

@MainActor
final class AtlasViewModel: ObservableObject {
    @Published private(set) var regions: [AtlasRegion]
    @Published private(set) var places: [Place]
    @Published private(set) var entries: [JournalEntry]
    @Published private(set) var attachments: [PlaceAttachment]
    @Published private(set) var routes: [TravelRoute]
    @Published private(set) var mediaStorage = MediaStorageBreakdown(photoBytes: 0, thumbnailBytes: 0, voiceBytes: 0)
    @Published private(set) var actualMapPackBytes: Int64 = 0
    @Published private(set) var downloadedPackBytesBySlug: [String: Int64] = [:]
    @Published var bannerErrorMessage: String?
    @Published private(set) var lastSaveFeedbackID = UUID()

    let mapConfiguration: MapProviderConfiguration
    let recoveryWarning: String?

    private let store: AtlasStore
    private let mediaStore: MediaStore?
    private let mapProvider: any MapProvider
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadTokens: [UUID: UUID] = [:]
    private let thumbnailCache: NSCache<NSString, UIImage>
    private var pendingStoreTail: Task<Void, Never>?

    init(
        store: AtlasStore? = nil,
        mediaStore: MediaStore? = nil,
        mapProvider: any MapProvider = MapLibreOfflineMapProvider()
    ) {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 40 * 1024 * 1024
        self.thumbnailCache = cache

        let resolvedStore = store ?? AtlasStore(
            regions: AtlasCatalog.defaultSeedRegions,
            places: AtlasCatalog.defaultSeedPlaces,
            entries: AtlasCatalog.defaultSeedEntries,
            routes: AtlasCatalog.defaultSeedRoutes,
            persistenceURL: AtlasStore.defaultPersistenceURL
        )
        self.store = resolvedStore
        self.mediaStore = mediaStore ?? (try? MediaStore())
        self.mapProvider = mapProvider
        self.mapConfiguration = mapProvider.configuration
        self.recoveryWarning = resolvedStore.recoveryWarning

        self.regions = resolvedStore.initialRegions
        self.places = resolvedStore.initialPlaces
        self.entries = resolvedStore.initialEntries
        self.attachments = resolvedStore.initialAttachments
        self.routes = resolvedStore.initialRoutes

        Task {
            await refreshStorageMetrics()
        }
    }

    // MARK: - Derived Collections & Stats

    var downloadedRegions: [AtlasRegion] {
        regions.filter { $0.downloadState.isDownloaded }
    }

    var recentPlaces: [Place] {
        places.sorted { $0.visitedAt > $1.visitedAt }
    }

    var sortedRoutes: [TravelRoute] {
        routes.sorted { $0.startedAt > $1.startedAt }
    }

    var availableCatalogRegions: [AtlasRegion] {
        let existingSlugs = Set(regions.map(\.slug))
        return AtlasCatalog.regions.filter { !existingSlugs.contains($0.slug) }
    }

    func downloadedBytes(for region: AtlasRegion) -> Int64? {
        guard region.downloadState.isDownloaded else { return nil }
        if let bytes = downloadedPackBytesBySlug[region.slug], bytes > 0 {
            return bytes
        }
        return nil
    }

    var summaryStats: AtlasSummaryStats {
        let downloaded = downloadedRegions
        return AtlasSummaryStats(
            totalPlaces: places.count,
            favoritePlaces: places.filter(\.isFavorite).count,
            downloadedRegions: downloaded.count,
            downloadedMapBytes: downloaded.reduce(0) { $0 + $1.mapPackageSize },
            photoCount: attachments.filter { $0.kind == .photo }.count,
            voiceNoteCount: attachments.filter { $0.kind == .voice }.count,
            journalEntryCount: entries.count,
            routeCount: routes.count,
            totalRouteDistanceMeters: routes.reduce(0) { $0 + $1.totalDistanceMeters }
        )
    }

    func attachments(for placeID: UUID) -> [PlaceAttachment] {
        attachments
            .filter { $0.placeID == placeID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func entries(for placeID: UUID) -> [JournalEntry] {
        entries
            .filter { $0.placeID == placeID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func filteredPlaces(
        query: String,
        category: PlaceCategory? = nil,
        mediaFilter: PlaceMediaFilter = .all
    ) -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entriesByPlace = Dictionary(grouping: entries, by: \.placeID)
        let attachmentsByPlace = Dictionary(grouping: attachments, by: \.placeID)

        return recentPlaces.filter { place in
            if let category, place.category != category {
                return false
            }

            let placeAttachments = attachmentsByPlace[place.id] ?? []
            switch mediaFilter {
            case .all:
                break
            case .favorites:
                if !place.isFavorite { return false }
            case .withPhotos:
                if !placeAttachments.contains(where: { $0.kind == .photo }) { return false }
            case .withVoiceNotes:
                if !placeAttachments.contains(where: { $0.kind == .voice }) { return false }
            case .withNotes:
                let hasNote = !(place.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasEntries = !(entriesByPlace[place.id]?.isEmpty ?? true)
                if !hasNote && !hasEntries { return false }
            }

            guard !trimmed.isEmpty else { return true }
            if place.name.localizedCaseInsensitiveContains(trimmed)
                || place.subtitle.localizedCaseInsensitiveContains(trimmed)
                || (place.note?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || place.category.displayName.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return (entriesByPlace[place.id] ?? []).contains {
                $0.body.localizedCaseInsensitiveContains(trimmed)
                    || ($0.title?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
    }

    // MARK: - Regions

    func download(region: AtlasRegion) {
        if let existing = regions.first(where: { $0.id == region.id || $0.slug == region.slug }),
           existing.downloadState.isDownloading || downloadTasks[existing.id] != nil {
            return
        }

        let target = regions.first(where: { $0.id == region.id || $0.slug == region.slug }) ?? region
        let token = UUID()
        downloadTokens[target.id] = token
        upsertRegion(target, state: .downloading(progress: 0), persistImmediately: false)

        let provider = mapProvider
        downloadTasks[target.id] = Task { [weak self] in
            do {
                try await provider.downloadRegion(target) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.setDownloadProgress(progress, for: target.id, token: token)
                    }
                }
                guard !Task.isCancelled, let self, self.downloadTokens[target.id] == token else { return }
                self.finishDownload(for: target.id, token: token)
                await self.refreshStorageMetrics()
            } catch is CancellationError {
                guard let self, self.downloadTokens[target.id] == token else { return }
                self.downloadTasks[target.id] = nil
                self.downloadTokens[target.id] = nil
                self.setRegionState(.available, for: target.id, persistImmediately: true)
            } catch {
                guard let self, self.downloadTokens[target.id] == token else { return }
                self.downloadTasks[target.id] = nil
                self.downloadTokens[target.id] = nil
                self.setRegionState(.failed(message: error.localizedDescription), for: target.id, persistImmediately: true)
            }
        }
    }

    func cancelDownload(for region: AtlasRegion) {
        downloadTasks[region.id]?.cancel()
        downloadTasks[region.id] = nil
        downloadTokens[region.id] = nil
        setRegionState(.available, for: region.id, persistImmediately: true)
    }

    func remove(region: AtlasRegion) async {
        downloadTasks[region.id]?.cancel()
        downloadTasks[region.id] = nil
        downloadTokens[region.id] = nil
        regions.removeAll { $0.id == region.id }
        try? await mapProvider.removeRegion(region)
        await enqueueStoreWork { store in
            await store.remove(regionID: region.id)
        }
        await refreshStorageMetrics()
    }

    func addCustomRegion(name: String, countryCode: String = "CUSTOM", bounds: RegionBounds?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let estimatedBytes = bounds?.estimatedOfflineBytes() ?? 24_000_000
        let region = AtlasRegion(
            name: trimmed,
            countryCode: countryCode,
            mapPackageSize: estimatedBytes,
            downloadState: .available,
            bounds: bounds
        )
        download(region: region)
    }

    // MARK: - Places & Memories

    func saveNewPlace(
        name: String,
        subtitle: String,
        latitude: Double,
        longitude: Double,
        visitedAt: Date,
        category: PlaceCategory,
        isFavorite: Bool,
        rating: Int?,
        note: String?,
        photoItemsData: [Data],
        pendingVoiceURL: URL?,
        pendingVoiceDuration: TimeInterval
    ) async -> Place {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        let place = Place(
            name: cleanName.isEmpty ? "Pinned Place" : cleanName,
            subtitle: cleanSubtitle.isEmpty ? Coordinate(latitude: latitude, longitude: longitude).formattedString : cleanSubtitle,
            latitude: latitude,
            longitude: longitude,
            visitedAt: visitedAt,
            category: category,
            isFavorite: isFavorite,
            rating: rating,
            note: (cleanNote?.isEmpty == false) ? cleanNote : nil,
            attachmentCount: 0
        )

        places.insert(place, at: 0)
        await enqueueStoreWork { store in
            await store.add(place: place)
        }

        for data in photoItemsData {
            await addPhotoAndAwait(data, to: place.id)
        }

        if let pendingVoiceURL {
            await addVoiceNote(from: pendingVoiceURL, duration: pendingVoiceDuration, to: place.id)
            try? FileManager.default.removeItem(at: pendingVoiceURL)
        }

        lastSaveFeedbackID = UUID()
        return places.first(where: { $0.id == place.id }) ?? place
    }

    func add(place: Place) {
        guard !places.contains(where: { $0.id == place.id }) else {
            update(place: place)
            return
        }
        places.insert(place, at: 0)
        lastSaveFeedbackID = UUID()
        enqueueStoreFireAndForget { store in
            await store.add(place: place)
        }
    }

    func update(place: Place) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        var updated = place
        updated.updatedAt = .now
        updated.attachmentCount = attachments.filter { $0.placeID == place.id }.count
        places[index] = updated
        let placeToSave = updated
        enqueueStoreFireAndForget { store in
            await store.update(place: placeToSave)
        }
    }

    func toggleFavorite(for place: Place) {
        var updated = place
        updated.isFavorite.toggle()
        update(place: updated)
    }

    func delete(place: Place) {
        places.removeAll { $0.id == place.id }
        entries.removeAll { $0.placeID == place.id }
        let removedAttachments = attachments.filter { $0.placeID == place.id }
        attachments.removeAll { $0.placeID == place.id }
        for item in removedAttachments {
            thumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
        }

        enqueueStoreFireAndForget { [weak self] store in
            let deleted = await store.delete(placeID: place.id)
            await self?.mediaStore?.removeAll(deleted)
            await self?.refreshStorageMetrics()
        }
    }

    // MARK: - Journal Entries

    func add(entry: JournalEntry) {
        entries.insert(entry, at: 0)
        if let index = places.firstIndex(where: { $0.id == entry.placeID }) {
            places[index].updatedAt = .now
        }
        lastSaveFeedbackID = UUID()
        enqueueStoreFireAndForget { store in
            await store.add(entry: entry)
        }
    }

    func update(entry: JournalEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        if let placeIdx = places.firstIndex(where: { $0.id == entry.placeID }) {
            places[placeIdx].updatedAt = .now
        }
        enqueueStoreFireAndForget { store in
            await store.update(entry: entry)
        }
    }

    func delete(entry: JournalEntry) {
        entries.removeAll { $0.id == entry.id }
        enqueueStoreFireAndForget { store in
            await store.delete(entryID: entry.id)
        }
    }

    // MARK: - Attachments (Photos & Voice)

    func addPhoto(_ data: Data, to place: Place) {
        Task {
            await addPhotoAndAwait(data, to: place.id)
        }
    }

    func addPhotoAndAwait(_ data: Data, to placeID: UUID) async {
        guard let mediaStore else {
            bannerErrorMessage = "Local media storage is unavailable."
            return
        }
        let attachmentID = UUID()
        do {
            let saved = try await mediaStore.saveProcessedPhoto(data, attachmentID: attachmentID)
            let attachment = PlaceAttachment(
                id: attachmentID,
                placeID: placeID,
                kind: .photo,
                filename: saved.filename,
                thumbnailFilename: saved.thumbnailFilename,
                byteSize: saved.byteSize
            )

            // Guard against place deletion while processing the photo off the main actor.
            guard places.contains(where: { $0.id == placeID }) else {
                try? await mediaStore.remove(attachment)
                return
            }

            attachments.insert(attachment, at: 0)
            syncAttachmentCountLocally(for: placeID)
            await enqueueStoreWork { store in
                await store.add(attachment: attachment)
            }
            await refreshStorageMetrics()
        } catch {
            bannerErrorMessage = error.localizedDescription
        }
    }

    func addVoiceNote(from temporaryURL: URL, duration: TimeInterval, to placeID: UUID) async {
        guard let mediaStore else {
            bannerErrorMessage = "Local media storage is unavailable."
            return
        }
        let attachmentID = UUID()
        do {
            let saved = try await mediaStore.saveVoiceRecording(from: temporaryURL, attachmentID: attachmentID)
            let attachment = PlaceAttachment(
                id: attachmentID,
                placeID: placeID,
                kind: .voice,
                filename: saved.filename,
                durationSeconds: duration,
                byteSize: saved.byteSize
            )

            guard places.contains(where: { $0.id == placeID }) else {
                try? await mediaStore.remove(attachment)
                return
            }

            attachments.insert(attachment, at: 0)
            syncAttachmentCountLocally(for: placeID)
            await enqueueStoreWork { store in
                await store.add(attachment: attachment)
            }
            await refreshStorageMetrics()
        } catch {
            bannerErrorMessage = "Could not save voice note: \(error.localizedDescription)"
        }
    }

    func delete(attachment: PlaceAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        thumbnailCache.removeObject(forKey: attachment.id.uuidString as NSString)
        syncAttachmentCountLocally(for: attachment.placeID)

        enqueueStoreFireAndForget { [weak self] store in
            await store.delete(attachmentID: attachment.id)
            try? await self?.mediaStore?.remove(attachment)
            await self?.refreshStorageMetrics()
        }
    }

    func loadThumbnailImage(for attachment: PlaceAttachment) async -> UIImage? {
        let key = attachment.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let mediaStore,
              let data = await mediaStore.thumbnailData(for: attachment) else {
            return nil
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            thumbnailCache.setObject(decoded, forKey: key, cost: max(1, cost))
        }
        return decoded
    }

    func loadThumbnailData(for attachment: PlaceAttachment) async -> Data? {
        guard let mediaStore else { return nil }
        return await mediaStore.thumbnailData(for: attachment)
    }

    func loadFullPhotoImage(for attachment: PlaceAttachment) async -> UIImage? {
        guard let mediaStore,
              let data = try? await mediaStore.data(for: attachment) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    func voiceFileURL(for attachment: PlaceAttachment) -> URL? {
        mediaStore?.fileURL(for: attachment)
    }

    // MARK: - Routes

    func add(route: TravelRoute) {
        routes.insert(route, at: 0)
        lastSaveFeedbackID = UUID()
        enqueueStoreFireAndForget { store in
            await store.add(route: route)
        }
    }

    func update(route: TravelRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        enqueueStoreFireAndForget { store in
            await store.update(route: route)
        }
    }

    func delete(route: TravelRoute) {
        routes.removeAll { $0.id == route.id }
        enqueueStoreFireAndForget { store in
            await store.delete(routeID: route.id)
        }
    }

    // MARK: - Export & Restore

    func makeExportSnapshot() -> AtlasSnapshot {
        AtlasSnapshot(
            regions: regions,
            places: recentPlaces,
            entries: entries,
            attachments: attachments,
            routes: sortedRoutes
        )
    }

    func buildCompleteBackupData() async throws -> Data {
        let snapshot = makeExportSnapshot()
        let media = await mediaStore?.exportEmbeddedMedia(for: attachments) ?? []
        return try await Task.detached(priority: .userInitiated) {
            try AtlasExporter.exportBackupArchive(snapshot: snapshot, media: media)
        }.value
    }

    func buildJSONExportData() async throws -> Data {
        let snapshot = makeExportSnapshot()
        return try await Task.detached(priority: .userInitiated) {
            try AtlasExporter.exportJSON(snapshot: snapshot)
        }.value
    }

    func importBackup(from data: Data, merge: Bool) async throws -> Int {
        let archive = try await Task.detached(priority: .userInitiated) {
            try AtlasExporter.decodeBackup(from: data)
        }.value

        if !archive.media.isEmpty {
            await mediaStore?.importEmbeddedMedia(archive.media)
        }

        let removedAttachments = await enqueueStoreWork { store in
            await store.restore(from: archive.snapshot, merge: merge)
        }
        if !removedAttachments.isEmpty {
            await mediaStore?.removeAll(removedAttachments)
        }

        self.regions = await store.allRegions()
        self.places = await store.allPlaces()
        self.entries = await store.allEntries()
        self.attachments = await store.allAttachments()
        self.routes = await store.allRoutes()
        thumbnailCache.removeAllObjects()
        await refreshStorageMetrics()
        lastSaveFeedbackID = UUID()
        return archive.snapshot.places.count
    }

    func flushPersistence() {
        enqueueStoreFireAndForget { store in
            await store.flushPersistence()
        }
    }

    // MARK: - Private Helpers

    private func enqueueStoreFireAndForget(_ work: @escaping @Sendable (AtlasStore) async -> Void) {
        let previous = pendingStoreTail
        let store = self.store
        pendingStoreTail = Task { [weak self] in
            await previous?.value
            await work(store)
            if let error = await store.persistenceError() {
                await MainActor.run {
                    self?.bannerErrorMessage = "Failed to persist atlas changes: \(error)"
                }
            }
        }
    }

    private func enqueueStoreWork<T: Sendable>(_ work: @escaping @Sendable (AtlasStore) async -> T) async -> T {
        let previous = pendingStoreTail
        let store = self.store
        let task = Task<T, Never> {
            await previous?.value
            return await work(store)
        }
        pendingStoreTail = Task {
            _ = await task.value
        }
        let result = await task.value
        if let error = await store.persistenceError() {
            bannerErrorMessage = "Failed to persist atlas changes: \(error)"
        }
        return result
    }

    private func syncAttachmentCountLocally(for placeID: UUID) {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return }
        places[index].attachmentCount = attachments.filter { $0.placeID == placeID }.count
        places[index].updatedAt = .now
    }

    private func upsertRegion(_ region: AtlasRegion, state: DownloadState, persistImmediately: Bool) {
        var updated = region
        updated.downloadState = state
        if case .downloaded = state {
            updated.downloadedAt = .now
        }
        regions.removeAll { $0.id == updated.id || $0.slug == updated.slug }
        regions.append(updated)
        regions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let regionToSave = updated
        enqueueStoreFireAndForget { store in
            await store.upsert(region: regionToSave, persistImmediately: persistImmediately)
        }
    }

    private func setRegionState(_ state: DownloadState, for id: UUID, persistImmediately: Bool) {
        guard let region = regions.first(where: { $0.id == id }) else { return }
        upsertRegion(region, state: state, persistImmediately: persistImmediately)
    }

    private func setDownloadProgress(_ progress: Double, for id: UUID, token: UUID) {
        guard downloadTokens[id] == token, downloadTasks[id] != nil else { return }
        setRegionState(.downloading(progress: progress), for: id, persistImmediately: false)
    }

    private func finishDownload(for id: UUID, token: UUID) {
        guard downloadTokens[id] == token else { return }
        downloadTasks[id] = nil
        downloadTokens[id] = nil
        setRegionState(.downloaded, for: id, persistImmediately: true)
        lastSaveFeedbackID = UUID()
    }

    private func refreshStorageMetrics() async {
        if let mediaStore {
            mediaStorage = await mediaStore.storageBreakdown()
        }
        actualMapPackBytes = await mapProvider.totalStoredPackBytes()
        downloadedPackBytesBySlug = await mapProvider.downloadedBytesBySlug()
    }
}
