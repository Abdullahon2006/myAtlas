import Foundation

public actor AtlasStore {
    public static var defaultPersistenceURL: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("atlas.json")
    }

    public nonisolated let initialRegions: [AtlasRegion]
    public nonisolated let initialPlaces: [Place]
    public nonisolated let initialEntries: [JournalEntry]
    public nonisolated let initialAttachments: [PlaceAttachment]
    public nonisolated let initialRoutes: [TravelRoute]
    public nonisolated let recoveryWarning: String?

    private var regions: [AtlasRegion]
    private var places: [Place]
    private var entries: [JournalEntry]
    private var attachments: [PlaceAttachment]
    private var routes: [TravelRoute]
    private let persistenceURL: URL?
    private var pendingPersistTask: Task<Void, Never>?
    private var lastPersistenceError: String?

    public init(
        regions: [AtlasRegion] = [],
        places: [Place] = [],
        entries: [JournalEntry] = [],
        attachments: [PlaceAttachment] = [],
        routes: [TravelRoute] = [],
        persistenceURL: URL? = nil
    ) {
        self.persistenceURL = persistenceURL
        var warning: String?
        var shouldRewriteNormalized = false

        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            do {
                let data = try Data(contentsOf: persistenceURL)
                let snapshot = try AtlasExporter.decodeSnapshot(from: data)

                var normalizedRegions = snapshot.regions
                for index in normalizedRegions.indices {
                    let normalized = normalizedRegions[index].downloadState.normalizedForLaunch
                    if normalized != normalizedRegions[index].downloadState {
                        normalizedRegions[index].downloadState = normalized
                        shouldRewriteNormalized = true
                    }
                }

                self.regions = Self.deduplicatedRegions(normalizedRegions)
                self.attachments = snapshot.attachments
                self.entries = snapshot.entries
                self.routes = snapshot.routes
                self.places = Self.reconciledPlaces(snapshot.places, attachments: snapshot.attachments)
            } catch {
                let backupName = "atlas.corrupt.\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
                let backupURL = persistenceURL.deletingLastPathComponent().appendingPathComponent(backupName)
                let copied = (try? FileManager.default.copyItem(at: persistenceURL, to: backupURL)) != nil
                if copied {
                    warning = "Previous atlas data could not be decoded and was backed up to \(backupName)."
                } else {
                    warning = "Previous atlas data could not be decoded."
                }
                self.regions = Self.deduplicatedRegions(regions)
                self.attachments = attachments
                self.entries = entries
                self.routes = routes
                self.places = Self.reconciledPlaces(places, attachments: attachments)
            }
        } else {
            self.regions = Self.deduplicatedRegions(regions)
            self.attachments = attachments
            self.entries = entries
            self.routes = routes
            self.places = Self.reconciledPlaces(places, attachments: attachments)
        }

        self.recoveryWarning = warning
        self.initialRegions = self.regions
        self.initialPlaces = self.places
        self.initialEntries = self.entries
        self.initialAttachments = self.attachments
        self.initialRoutes = self.routes

        if shouldRewriteNormalized, let persistenceURL {
            _ = Self.writeSnapshot(
                AtlasSnapshot(
                    regions: self.regions,
                    places: self.places,
                    entries: self.entries,
                    attachments: self.attachments,
                    routes: self.routes
                ),
                to: persistenceURL
            )
        }
    }

    // MARK: - Queries

    public func persistenceError() -> String? {
        lastPersistenceError
    }

    public func allRegions() -> [AtlasRegion] {
        regions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func allPlaces() -> [Place] {
        places.sorted { $0.visitedAt > $1.visitedAt }
    }

    public func place(id: UUID) -> Place? {
        places.first { $0.id == id }
    }

    public func allEntries() -> [JournalEntry] {
        entries.sorted { $0.createdAt > $1.createdAt }
    }

    public func entries(for placeID: UUID) -> [JournalEntry] {
        entries.filter { $0.placeID == placeID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func allAttachments() -> [PlaceAttachment] {
        attachments.sorted { $0.createdAt > $1.createdAt }
    }

    public func attachments(for placeID: UUID) -> [PlaceAttachment] {
        attachments.filter { $0.placeID == placeID }.sorted { $0.createdAt > $1.createdAt }
    }

    public func allRoutes() -> [TravelRoute] {
        routes.sorted { $0.startedAt > $1.startedAt }
    }

    public func searchPlaces(
        query: String,
        category: PlaceCategory? = nil,
        mediaFilter: PlaceMediaFilter = .all
    ) -> [Place] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryBodiesByPlace = Dictionary(grouping: entries, by: \.placeID)
        let attachmentsByPlace = Dictionary(grouping: attachments, by: \.placeID)

        return allPlaces().filter { place in
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
                let hasEntries = !(entryBodiesByPlace[place.id]?.isEmpty ?? true)
                if !hasNote && !hasEntries { return false }
            }

            guard !trimmedQuery.isEmpty else { return true }

            if place.name.localizedCaseInsensitiveContains(trimmedQuery)
                || place.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
                || (place.note?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || place.category.displayName.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }

            if let placeEntries = entryBodiesByPlace[place.id] {
                return placeEntries.contains { entry in
                    entry.body.localizedCaseInsensitiveContains(trimmedQuery)
                        || (entry.title?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                }
            }

            return false
        }
    }

    public func summaryStats() -> AtlasSummaryStats {
        let downloaded = regions.filter { $0.downloadState.isDownloaded }
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

    public func snapshot() -> AtlasSnapshot {
        AtlasSnapshot(
            regions: allRegions(),
            places: allPlaces(),
            entries: allEntries(),
            attachments: allAttachments(),
            routes: allRoutes()
        )
    }

    // MARK: - Mutations: Places

    public func add(place: Place) {
        guard !places.contains(where: { $0.id == place.id }) else {
            update(place: place)
            return
        }
        var normalized = place
        normalized.attachmentCount = attachments.filter { $0.placeID == place.id }.count
        places.append(normalized)
        persistNow()
    }

    public func update(place: Place) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else {
            return
        }
        var updated = place
        updated.updatedAt = .now
        updated.attachmentCount = attachments.filter { $0.placeID == place.id }.count
        places[index] = updated
        persistNow()
    }

    /// Deletes a place along with its journal entries and attachment records, returning removed attachments for disk cleanup.
    @discardableResult
    public func delete(placeID: UUID) -> [PlaceAttachment] {
        let removedAttachments = attachments.filter { $0.placeID == placeID }
        places.removeAll { $0.id == placeID }
        entries.removeAll { $0.placeID == placeID }
        attachments.removeAll { $0.placeID == placeID }
        persistNow()
        return removedAttachments
    }

    // MARK: - Mutations: Journal Entries

    public func add(entry: JournalEntry) {
        guard !entries.contains(where: { $0.id == entry.id }) else {
            update(entry: entry)
            return
        }
        entries.append(entry)
        touchPlace(id: entry.placeID)
        persistNow()
    }

    public func update(entry: JournalEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        touchPlace(id: entry.placeID)
        persistNow()
    }

    public func delete(entryID: UUID) {
        if let entry = entries.first(where: { $0.id == entryID }) {
            touchPlace(id: entry.placeID)
        }
        entries.removeAll { $0.id == entryID }
        persistNow()
    }

    // MARK: - Mutations: Attachments

    public func add(attachment: PlaceAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
        syncAttachmentCount(for: attachment.placeID)
        persistNow()
    }

    @discardableResult
    public func delete(attachmentID: UUID) -> PlaceAttachment? {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentID }) else {
            return nil
        }
        let removed = attachments.remove(at: index)
        syncAttachmentCount(for: removed.placeID)
        persistNow()
        return removed
    }

    // MARK: - Mutations: Regions

    public func add(region: AtlasRegion) {
        upsert(region: region, persistImmediately: true)
    }

    public func update(region: AtlasRegion, persistImmediately: Bool = true) {
        upsert(region: region, persistImmediately: persistImmediately)
    }

    public func upsert(region: AtlasRegion, persistImmediately: Bool = true) {
        if let index = regions.firstIndex(where: { $0.id == region.id || $0.slug == region.slug }) {
            regions[index] = region
        } else {
            regions.append(region)
        }
        if persistImmediately {
            persistNow()
        } else {
            schedulePersist()
        }
    }

    public func remove(regionID: UUID) {
        regions.removeAll { $0.id == regionID }
        persistNow()
    }

    // MARK: - Mutations: Routes

    public func add(route: TravelRoute) {
        guard !routes.contains(where: { $0.id == route.id }) else {
            update(route: route)
            return
        }
        routes.append(route)
        persistNow()
    }

    public func update(route: TravelRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        persistNow()
    }

    public func delete(routeID: UUID) {
        routes.removeAll { $0.id == routeID }
        persistNow()
    }

    // MARK: - Restore / Replace

    /// Merges or replaces store contents from an imported snapshot, returning any orphaned attachment records if replaced.
    @discardableResult
    public func restore(from imported: AtlasSnapshot, merge: Bool) -> [PlaceAttachment] {
        let normalizedRegions = imported.regions.map { region in
            var copy = region
            copy.downloadState = region.downloadState.normalizedForLaunch
            return copy
        }

        if merge {
            for region in normalizedRegions {
                if !regions.contains(where: { $0.id == region.id || $0.slug == region.slug }) {
                    regions.append(region)
                }
            }
            for place in imported.places where !places.contains(where: { $0.id == place.id }) {
                places.append(place)
            }
            for entry in imported.entries where !entries.contains(where: { $0.id == entry.id }) {
                entries.append(entry)
            }
            for attachment in imported.attachments where !attachments.contains(where: { $0.id == attachment.id }) {
                attachments.append(attachment)
            }
            for route in imported.routes where !routes.contains(where: { $0.id == route.id }) {
                routes.append(route)
            }
            places = Self.reconciledPlaces(places, attachments: attachments)
            regions = Self.deduplicatedRegions(regions)
            persistNow()
            return []
        } else {
            let previousAttachments = attachments
            regions = Self.deduplicatedRegions(normalizedRegions)
            attachments = imported.attachments
            entries = imported.entries
            routes = imported.routes
            places = Self.reconciledPlaces(imported.places, attachments: imported.attachments)
            persistNow()
            let remainingIDs = Set(attachments.map(\.id))
            return previousAttachments.filter { !remainingIDs.contains($0.id) }
        }
    }

    public func flushPersistence() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        persistNow()
    }

    // MARK: - Private Helpers

    private func touchPlace(id: UUID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].updatedAt = .now
    }

    private func syncAttachmentCount(for placeID: UUID) {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return }
        places[index].attachmentCount = attachments.filter { $0.placeID == placeID }.count
        places[index].updatedAt = .now
    }

    private static func reconciledPlaces(_ places: [Place], attachments: [PlaceAttachment]) -> [Place] {
        let counts = Dictionary(grouping: attachments, by: \.placeID).mapValues(\.count)
        return places.map { place in
            var copy = place
            copy.attachmentCount = counts[place.id] ?? 0
            return copy
        }
    }

    private static func deduplicatedRegions(_ regions: [AtlasRegion]) -> [AtlasRegion] {
        var seenIDs = Set<UUID>()
        var seenSlugs = Set<String>()
        var result: [AtlasRegion] = []
        for region in regions {
            if seenIDs.contains(region.id) || seenSlugs.contains(region.slug) {
                continue
            }
            seenIDs.insert(region.id)
            seenSlugs.insert(region.slug)
            result.append(region)
        }
        return result
    }

    private func schedulePersist() {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        guard let persistenceURL else { return }
        let current = AtlasSnapshot(
            regions: regions,
            places: places,
            entries: entries,
            attachments: attachments,
            routes: routes
        )
        lastPersistenceError = Self.writeSnapshot(current, to: persistenceURL)
    }

    private static func writeSnapshot(_ snapshot: AtlasSnapshot, to url: URL) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableParent = parentDir
            try? mutableParent.setResourceValues(resourceValues)

            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
