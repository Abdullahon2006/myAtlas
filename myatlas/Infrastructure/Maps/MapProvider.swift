import CoreLocation
import Foundation
import MapLibre

enum OfflineMapState: Equatable, Sendable {
    case unavailable
    case ready
    case downloading(progress: Double)
    case failed(String)
}

enum MapLibreRuntime {
    static let openFreeMapLibertyStyleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    private static var isConfigured = false

    @MainActor
    static func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        var headers = config.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = "myatlas-ios/0.1.0 (offline-personal-atlas)"
        config.httpAdditionalHeaders = headers

        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
        MLNOfflineStorage.shared.setMaximumAllowedMapboxTiles(50_000)
    }
}

struct MapProviderConfiguration: Sendable {
    let styleURL: URL?
    let attributionText: String
    let providerName: String

    var hasLicensedTileSource: Bool {
        styleURL != nil
    }

    static let localBoundary = MapProviderConfiguration(
        styleURL: nil,
        attributionText: "Local region index ready · MapKit provides live map preview. Configure a licensed MapLibre tile/style URL before shipping offline vector downloads. © OpenStreetMap contributors when using OSM-derived styles.",
        providerName: "Local Region Index · MapKit Preview"
    )

    static let openFreeMapLiberty = MapProviderConfiguration(
        styleURL: MapLibreRuntime.openFreeMapLibertyStyleURL,
        attributionText: "Offline vector maps by OpenFreeMap · © OpenMapTiles · © OpenStreetMap contributors.",
        providerName: "MapLibre Vector · OpenFreeMap Liberty"
    )
}

protocol MapProvider: Sendable {
    var configuration: MapProviderConfiguration { get }
    func downloadRegion(
        _ region: AtlasRegion,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
    func removeRegion(_ region: AtlasRegion) async throws
    func totalStoredPackBytes() async -> Int64
    func downloadedBytesBySlug() async -> [String: Int64]
}

extension MapProvider {
    func downloadedBytesBySlug() async -> [String: Int64] { [:] }
}

/// Real offline vector tile downloader backed by MapLibre Native (`MLNOfflineStorage`) and OpenFreeMap Liberty style tiles.
final class MapLibreOfflineMapProvider: MapProvider, @unchecked Sendable {
    enum MapProviderError: LocalizedError {
        case missingRegionBounds
        case missingStyleURL
        case tileLimitReached
        case offlineStorageUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingRegionBounds:
                return "This region does not have map coordinates to download."
            case .missingStyleURL:
                return "No vector map style URL is configured."
            case .tileLimitReached:
                return "Map tile limit reached for this region. Try zooming in to download a smaller area."
            case .offlineStorageUnavailable(let detail):
                return detail
            }
        }
    }

    let configuration: MapProviderConfiguration

    init(configuration: MapProviderConfiguration = .openFreeMapLiberty) {
        self.configuration = configuration
    }

    func downloadRegion(
        _ region: AtlasRegion,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let styleURL = configuration.styleURL else {
            throw MapProviderError.missingStyleURL
        }
        guard let bounds = region.bounds else {
            throw MapProviderError.missingRegionBounds
        }

        let session = await MainActor.run {
            PackDownloadSession(region: region, bounds: bounds, styleURL: styleURL, onProgress: onProgress)
        }

        try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        }
    }

    func removeRegion(_ region: AtlasRegion) async throws {
        let targetSlug = AtlasRegion.sanitizedSlug(region.slug, fallbackID: region.id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                MLNOfflineStorage.shared.reloadPacks()
                let matching = (MLNOfflineStorage.shared.packs ?? []).filter { pack in
                    guard let context = PackContext.decode(from: pack.context) else { return false }
                    return context.slug == targetSlug || context.regionID == region.id
                }
                guard !matching.isEmpty else {
                    continuation.resume()
                    return
                }

                let group = DispatchGroup()
                var firstError: Error?
                for pack in matching {
                    pack.suspend()
                    group.enter()
                    MLNOfflineStorage.shared.removePack(pack) { error in
                        if let error, firstError == nil {
                            firstError = error
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    if let firstError {
                        continuation.resume(throwing: firstError)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func totalStoredPackBytes() async -> Int64 {
        await MainActor.run {
            let packs = MLNOfflineStorage.shared.packs ?? []
            let packSum = packs.reduce(Int64(0)) { partial, pack in
                partial + Int64(pack.progress.countOfBytesCompleted)
            }
            if packSum > 0 {
                return packSum
            }
            if !packs.isEmpty,
               let dbURL = MLNOfflineStorage.shared.databaseURL,
               let size = (try? dbURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return Int64(size)
            }
            return 0
        }
    }

    func downloadedBytesBySlug() async -> [String: Int64] {
        await MainActor.run {
            let packs = MLNOfflineStorage.shared.packs ?? []
            var result: [String: Int64] = [:]
            for pack in packs where pack.state == .complete {
                if let context = PackContext.decode(from: pack.context) {
                    result[context.slug] = Int64(pack.progress.countOfBytesCompleted)
                }
            }
            return result
        }
    }
}

private struct PackContext: Codable {
    let regionID: UUID
    let slug: String
    let name: String

    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decode(from data: Data) -> PackContext? {
        try? JSONDecoder().decode(PackContext.self, from: data)
    }
}

@MainActor
private final class PackDownloadSession {
    private let region: AtlasRegion
    private let bounds: RegionBounds
    private let styleURL: URL
    private let onProgress: @Sendable (Double) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var observerTokens: [NSObjectProtocol] = []
    private var activePack: MLNOfflinePack?
    private var isFinished = false

    init(
        region: AtlasRegion,
        bounds: RegionBounds,
        styleURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.region = region
        self.bounds = bounds
        self.styleURL = styleURL
        self.onProgress = onProgress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.start()
        }
    }

    func cancel() {
        guard !isFinished else { return }
        let packToRemove = activePack
        activePack?.suspend()
        finish(with: .failure(CancellationError()))
        if let packToRemove, packToRemove.state != .complete {
            MLNOfflineStorage.shared.removePack(packToRemove) { _ in }
        }
    }

    private func start() {
        guard !isFinished else { return }
        MapLibreRuntime.configureIfNeeded()
        MLNOfflineStorage.shared.reloadPacks()

        let targetSlug = AtlasRegion.sanitizedSlug(region.slug, fallbackID: region.id)
        if let existing = (MLNOfflineStorage.shared.packs ?? []).first(where: { pack in
            guard let context = PackContext.decode(from: pack.context) else { return false }
            return context.slug == targetSlug || context.regionID == region.id
        }) {
            if existing.state == .complete {
                onProgress(1.0)
                finish(with: .success(()))
                return
            }
            attach(to: existing)
            existing.resume()
            existing.requestProgress()
            return
        }

        let halfLat = max(0.01, abs(bounds.latitudeDelta) / 2.0)
        let halfLon = max(0.01, abs(bounds.longitudeDelta) / 2.0)
        let sw = CLLocationCoordinate2D(
            latitude: max(-85.0, bounds.centerLatitude - halfLat),
            longitude: max(-180.0, bounds.centerLongitude - halfLon)
        )
        let ne = CLLocationCoordinate2D(
            latitude: min(85.0, bounds.centerLatitude + halfLat),
            longitude: min(180.0, bounds.centerLongitude + halfLon)
        )
        let mlBounds = MLNCoordinateBounds(sw: sw, ne: ne)
        let maxZoom = bounds.safeOfflineMaxZoom(maxTileBudget: 2_200, minZoom: 0, preferredMaxZoom: 14)

        let offlineRegion = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: mlBounds,
            fromZoomLevel: 0,
            toZoomLevel: Double(maxZoom)
        )
        offlineRegion.includesIdeographicGlyphs = region.requiresIdeographicGlyphs

        let contextData = PackContext(regionID: region.id, slug: targetSlug, name: region.name).encode()
        onProgress(0.02)

        MLNOfflineStorage.shared.addPack(for: offlineRegion, withContext: contextData) { [weak self] pack, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isFinished else { return }
                if let error {
                    self.finish(with: .failure(error))
                    return
                }
                guard let pack else {
                    self.finish(with: .failure(MapLibreOfflineMapProvider.MapProviderError.offlineStorageUnavailable("Could not initialize offline map pack.")))
                    return
                }
                self.attach(to: pack)
                pack.resume()
            }
        }
    }

    private func attach(to pack: MLNOfflinePack) {
        activePack = pack
        let center = NotificationCenter.default

        let progressToken = center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: pack,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished,
                      let updatedPack = notification.object as? MLNOfflinePack else { return }
                self.handleProgress(updatedPack)
            }
        }

        let errorToken = center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackError,
            object: pack,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished else { return }
                let err = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
                if let err,
                   err.domain == NSURLErrorDomain,
                   [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost].contains(err.code) {
                    self.activePack?.suspend()
                    self.finish(with: .failure(MapLibreOfflineMapProvider.MapProviderError.offlineStorageUnavailable(
                        "Connect to the internet to download this offline map pack."
                    )))
                }
            }
        }

        let limitToken = center.addObserver(
            forName: NSNotification.Name.MLNOfflinePackMaximumMapboxTilesReached,
            object: pack,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished else { return }
                let partial = self.activePack
                partial?.suspend()
                self.finish(with: .failure(MapLibreOfflineMapProvider.MapProviderError.tileLimitReached))
                if let partial {
                    MLNOfflineStorage.shared.removePack(partial) { _ in }
                }
            }
        }

        observerTokens = [progressToken, errorToken, limitToken]
    }

    private func handleProgress(_ pack: MLNOfflinePack) {
        let progress = pack.progress
        if pack.state == .complete {
            onProgress(1.0)
            finish(with: .success(()))
            return
        }

        if progress.countOfResourcesExpected > 0 {
            let ratio = Double(progress.countOfResourcesCompleted) / Double(progress.countOfResourcesExpected)
            onProgress(max(0.02, min(0.99, ratio)))
        } else {
            onProgress(0.03)
        }
    }

    private func finish(with result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        let pending = continuation
        continuation = nil
        switch result {
        case .success:
            pending?.resume()
        case .failure(let error):
            pending?.resume(throwing: error)
        }
    }
}

/// Manages lightweight JSON pack manifests inside Application Support/MapPacks for unit tests or offline-stub environments.
actor LocalOfflineMapProvider: MapProvider {
    enum MapProviderError: LocalizedError {
        case invalidRegionSlug

        var errorDescription: String? {
            "The region identifier is invalid."
        }
    }

    nonisolated let configuration: MapProviderConfiguration
    private let packsDirectory: URL

    init(
        configuration: MapProviderConfiguration = .localBoundary,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("MapPacks", isDirectory: true)
        self.packsDirectory = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var exclusion = URLResourceValues()
        exclusion.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(exclusion)
    }

    func downloadRegion(
        _ region: AtlasRegion,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let targetURL = try manifestURL(for: region)

        for step in 1...10 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(90))
            try Task.checkCancellation()
            onProgress(Double(step) / 10.0)
        }

        let manifest = PackManifest(
            regionID: region.id,
            slug: region.slug,
            name: region.name,
            countryCode: region.countryCode,
            bounds: region.bounds,
            estimatedTileBytes: region.mapPackageSize,
            preparedAt: .now,
            styleURL: configuration.styleURL?.absoluteString
        )
        let data = try JSONEncoder().encode(manifest)
        #if os(iOS)
        try data.write(to: targetURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: targetURL, options: .atomic)
        #endif
    }

    func removeRegion(_ region: AtlasRegion) async throws {
        let url = try manifestURL(for: region)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func totalStoredPackBytes() async -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: packsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for url in urls {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func manifestURL(for region: AtlasRegion) throws -> URL {
        let safeSlug = AtlasRegion.sanitizedSlug(region.slug, fallbackID: region.id)
        let candidate = packsDirectory.appendingPathComponent("\(safeSlug).json", isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == packsDirectory.standardizedFileURL else {
            throw MapProviderError.invalidRegionSlug
        }
        return candidate
    }

    private struct PackManifest: Codable {
        let regionID: UUID
        let slug: String
        let name: String
        let countryCode: String
        let bounds: RegionBounds?
        let estimatedTileBytes: Int64
        let preparedAt: Date
        let styleURL: String?
    }
}
