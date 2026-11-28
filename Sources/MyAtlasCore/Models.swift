import Foundation

public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var recordedAt: Date?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        recordedAt: Date? = nil
    ) {
        self.latitude = latitude.isFinite ? latitude : 0
        self.longitude = longitude.isFinite ? longitude : 0
        self.altitude = altitude.flatMap { $0.isFinite ? $0 : nil }
        self.recordedAt = recordedAt
    }

    public var isValid: Bool {
        latitude.isFinite
            && longitude.isFinite
            && latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
    }

    public var isNonZero: Bool {
        abs(latitude) > 0.0001 || abs(longitude) > 0.0001
    }

    public var formattedString: String {
        let latHemisphere = latitude >= 0 ? "N" : "S"
        let lonHemisphere = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), latHemisphere, abs(longitude), lonHemisphere)
    }

    /// Great-circle distance in meters using the Haversine formula.
    public func distance(to other: Coordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = (other.longitude - longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return earthRadiusMeters * c
    }
}

public struct RegionBounds: Codable, Equatable, Hashable, Sendable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    public func estimatedTileCount(minZoom: Int = 0, maxZoom: Int = 14) -> Int {
        guard centerLatitude.isFinite,
              centerLongitude.isFinite,
              latitudeDelta.isFinite,
              longitudeDelta.isFinite,
              minZoom <= maxZoom else {
            return 0
        }

        let clampedLatDelta = max(0.005, min(160.0, abs(latitudeDelta)))
        let clampedLonDelta = max(0.005, min(350.0, abs(longitudeDelta)))
        let south = max(-85.0511, centerLatitude - clampedLatDelta / 2.0)
        let north = min(85.0511, centerLatitude + clampedLatDelta / 2.0)
        let west = max(-180.0, centerLongitude - clampedLonDelta / 2.0)
        let east = min(180.0, centerLongitude + clampedLonDelta / 2.0)

        var total = 0
        for zoom in max(0, minZoom)...max(0, maxZoom) {
            let n = pow(2.0, Double(zoom))
            let x0 = Self.tileX(longitude: west, n: n)
            let x1 = Self.tileX(longitude: east, n: n)
            let y0 = Self.tileY(latitude: north, n: n)
            let y1 = Self.tileY(latitude: south, n: n)
            let width = abs(x1 - x0) + 1
            let height = abs(y1 - y0) + 1
            total += width * height
        }
        return total
    }

    /// Chooses the deepest zoom level (up to `preferredMaxZoom`) that stays within OpenFreeMap's per-pack tile budget.
    public func safeOfflineMaxZoom(
        maxTileBudget: Int = 2_200,
        minZoom: Int = 0,
        preferredMaxZoom: Int = 14
    ) -> Int {
        guard preferredMaxZoom > minZoom else { return preferredMaxZoom }
        for candidate in stride(from: preferredMaxZoom, through: max(minZoom, 10), by: -1) {
            if estimatedTileCount(minZoom: minZoom, maxZoom: candidate) <= maxTileBudget {
                return candidate
            }
        }
        return max(minZoom, 10)
    }

    public func estimatedOfflineBytes(maxTileBudget: Int = 2_200) -> Int64 {
        let maxZoom = safeOfflineMaxZoom(maxTileBudget: maxTileBudget)
        let tiles = estimatedTileCount(minZoom: 0, maxZoom: maxZoom)
        // Average OpenFreeMap Liberty PBF tile + glyphs/sprites overhead is ~42 KB per tile (min ~5 MB floor).
        return max(5_000_000, Int64(tiles) * 42_000)
    }

    private static func tileX(longitude: Double, n: Double) -> Int {
        let raw = Int(floor((longitude + 180.0) / 360.0 * n))
        return max(0, min(Int(n) - 1, raw))
    }

    private static func tileY(latitude: Double, n: Double) -> Int {
        let rad = latitude * .pi / 180.0
        let merc = log(tan(rad) + 1.0 / cos(rad))
        let raw = Int(floor((1.0 - merc / .pi) / 2.0 * n))
        return max(0, min(Int(n) - 1, raw))
    }
}

public enum DownloadState: Codable, Equatable, Sendable {
    case available
    case downloading(progress: Double)
    case downloaded
    case failed(message: String)

    public var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    public var normalizedForLaunch: DownloadState {
        if case .downloading = self {
            return .available
        }
        return self
    }
}

public struct AtlasRegion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var slug: String
    public var name: String
    public var countryCode: String
    public var mapPackageSize: Int64
    public var downloadState: DownloadState
    public var bounds: RegionBounds?
    public var downloadedAt: Date?

    public init(
        id: UUID = UUID(),
        slug: String? = nil,
        name: String,
        countryCode: String,
        mapPackageSize: Int64,
        downloadState: DownloadState = .available,
        bounds: RegionBounds? = nil,
        downloadedAt: Date? = nil
    ) {
        self.id = id
        self.slug = Self.sanitizedSlug(slug ?? Self.makeSlug(name: name, countryCode: countryCode, fallbackID: id), fallbackID: id)
        self.name = name
        self.countryCode = countryCode
        self.mapPackageSize = mapPackageSize
        self.downloadState = downloadState
        self.bounds = bounds
        self.downloadedAt = downloadedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, countryCode, mapPackageSize, downloadState, bounds, downloadedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        countryCode = try container.decode(String.self, forKey: .countryCode)
        mapPackageSize = try container.decode(Int64.self, forKey: .mapPackageSize)
        downloadState = try container.decode(DownloadState.self, forKey: .downloadState)
        let rawSlug = try container.decodeIfPresent(String.self, forKey: .slug)
        slug = Self.sanitizedSlug(rawSlug ?? Self.makeSlug(name: name, countryCode: countryCode, fallbackID: id), fallbackID: id)
        bounds = try container.decodeIfPresent(RegionBounds.self, forKey: .bounds)
        downloadedAt = try container.decodeIfPresent(Date.self, forKey: .downloadedAt)
    }

    public var catalogGroup: String {
        if slug.hasPrefix("tr-istanbul") {
            return "Istanbul"
        }
        switch countryCode.uppercased() {
        case "TR":
            return "Turkey"
        case "PT", "FR", "GB", "IT", "ES", "NL", "DE", "AT", "CZ", "GR", "CH", "IS":
            return "Europe"
        case "JP", "KR", "TH", "AE", "SG", "EG":
            return "Asia & Middle East"
        case "US", "AU", "CA":
            return "Americas & Oceania"
        default:
            return "Custom"
        }
    }

    public var requiresIdeographicGlyphs: Bool {
        ["JP", "KR", "CN", "TW", "HK"].contains(countryCode.uppercased())
    }

    public static func makeSlug(name: String, countryCode: String, fallbackID: UUID = UUID()) -> String {
        let raw = "\(countryCode)-\(name)".lowercased()
        let allowed = raw.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        let joined = String(allowed).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "region-\(fallbackID.uuidString.prefix(8).lowercased())" : joined
    }

    public static func sanitizedSlug(_ candidate: String, fallbackID: UUID) -> String {
        let allowed = candidate.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) ? $0 : "-" }
        let joined = String(allowed).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "region-\(fallbackID.uuidString.prefix(8).lowercased())" : joined
    }
}

public enum PlaceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case viewpoint
    case food
    case nature
    case culture
    case stay
    case gem
    case note

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .viewpoint: "Viewpoint"
        case .food: "Food & Café"
        case .nature: "Nature & Trail"
        case .culture: "Culture"
        case .stay: "Stay"
        case .gem: "Hidden Gem"
        case .note: "Field Note"
        }
    }

    public var systemImage: String {
        switch self {
        case .viewpoint: "binoculars.fill"
        case .food: "fork.knife"
        case .nature: "leaf.fill"
        case .culture: "building.columns.fill"
        case .stay: "bed.double.fill"
        case .gem: "sparkles"
        case .note: "mappin.and.ellipse"
        }
    }
}

public struct Place: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var subtitle: String
    public var latitude: Double
    public var longitude: Double
    public var visitedAt: Date
    public var updatedAt: Date
    public var category: PlaceCategory
    public var isFavorite: Bool
    public var rating: Int?
    public var note: String?
    public var attachmentCount: Int
    public var regionID: UUID?

    public var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String,
        latitude: Double,
        longitude: Double,
        visitedAt: Date,
        updatedAt: Date? = nil,
        category: PlaceCategory = .note,
        isFavorite: Bool = false,
        rating: Int? = nil,
        note: String? = nil,
        attachmentCount: Int = 0,
        regionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude.isFinite ? min(90, max(-90, latitude)) : 0
        self.longitude = longitude.isFinite ? min(180, max(-180, longitude)) : 0
        self.visitedAt = visitedAt
        self.updatedAt = updatedAt ?? visitedAt
        self.category = category
        self.isFavorite = isFavorite
        self.rating = rating
        self.note = note
        self.attachmentCount = attachmentCount
        self.regionID = regionID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, subtitle, latitude, longitude, visitedAt, updatedAt, category, isFavorite, rating, note, attachmentCount, regionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        let rawLat = try container.decode(Double.self, forKey: .latitude)
        let rawLon = try container.decode(Double.self, forKey: .longitude)
        latitude = rawLat.isFinite ? min(90, max(-90, rawLat)) : 0
        longitude = rawLon.isFinite ? min(180, max(-180, rawLon)) : 0
        visitedAt = try container.decode(Date.self, forKey: .visitedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? visitedAt
        category = try container.decodeIfPresent(PlaceCategory.self, forKey: .category) ?? .note
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
        regionID = try container.decodeIfPresent(UUID.self, forKey: .regionID)
    }
}

public struct JournalEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let placeID: UUID
    public var title: String?
    public var body: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        placeID: UUID,
        title: String? = nil,
        body: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.placeID = placeID
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, placeID, title, body, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        placeID = try container.decode(UUID.self, forKey: .placeID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

public enum AttachmentKind: String, Codable, Sendable {
    case photo
    case voice
}

public struct PlaceAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let placeID: UUID
    public let kind: AttachmentKind
    public let filename: String
    public var thumbnailFilename: String?
    public var durationSeconds: TimeInterval?
    public var byteSize: Int64?
    public var caption: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        placeID: UUID,
        kind: AttachmentKind,
        filename: String,
        thumbnailFilename: String? = nil,
        durationSeconds: TimeInterval? = nil,
        byteSize: Int64? = nil,
        caption: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.placeID = placeID
        self.kind = kind
        self.filename = filename
        self.thumbnailFilename = thumbnailFilename
        self.durationSeconds = durationSeconds
        self.byteSize = byteSize
        self.caption = caption
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, placeID, kind, filename, thumbnailFilename, durationSeconds, byteSize, caption, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        placeID = try container.decode(UUID.self, forKey: .placeID)
        kind = try container.decode(AttachmentKind.self, forKey: .kind)
        filename = try container.decode(String.self, forKey: .filename)
        thumbnailFilename = try container.decodeIfPresent(String.self, forKey: .thumbnailFilename)
        durationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

public struct TravelRoute: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var points: [Coordinate]
    public var totalDistanceMeters: Double
    public var note: String?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        points: [Coordinate],
        totalDistanceMeters: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.points = points
        let computed = totalDistanceMeters ?? TravelRoute.computeDistance(points)
        self.totalDistanceMeters = computed.isFinite ? max(0, computed) : 0
        self.note = note
    }

    public var duration: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    public static func computeDistance(_ points: [Coordinate]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            let d = points[index - 1].distance(to: points[index])
            if d.isFinite {
                total += d
            }
        }
        return total
    }
}

public struct AtlasSummaryStats: Equatable, Sendable {
    public let totalPlaces: Int
    public let favoritePlaces: Int
    public let downloadedRegions: Int
    public let downloadedMapBytes: Int64
    public let photoCount: Int
    public let voiceNoteCount: Int
    public let journalEntryCount: Int
    public let routeCount: Int
    public let totalRouteDistanceMeters: Double

    public init(
        totalPlaces: Int,
        favoritePlaces: Int,
        downloadedRegions: Int,
        downloadedMapBytes: Int64,
        photoCount: Int,
        voiceNoteCount: Int,
        journalEntryCount: Int,
        routeCount: Int,
        totalRouteDistanceMeters: Double
    ) {
        self.totalPlaces = totalPlaces
        self.favoritePlaces = favoritePlaces
        self.downloadedRegions = downloadedRegions
        self.downloadedMapBytes = downloadedMapBytes
        self.photoCount = photoCount
        self.voiceNoteCount = voiceNoteCount
        self.journalEntryCount = journalEntryCount
        self.routeCount = routeCount
        self.totalRouteDistanceMeters = totalRouteDistanceMeters
    }
}

public struct AtlasSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let savedAt: Date
    public let regions: [AtlasRegion]
    public let places: [Place]
    public let entries: [JournalEntry]
    public let attachments: [PlaceAttachment]
    public let routes: [TravelRoute]

    public init(
        schemaVersion: Int = AtlasSnapshot.currentSchemaVersion,
        savedAt: Date = .now,
        regions: [AtlasRegion],
        places: [Place],
        entries: [JournalEntry],
        attachments: [PlaceAttachment],
        routes: [TravelRoute] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.regions = regions
        self.places = places
        self.entries = entries
        self.attachments = attachments
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt, regions, places, entries, attachments, routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .now
        regions = try container.decode([AtlasRegion].self, forKey: .regions)
        places = try container.decode([Place].self, forKey: .places)
        entries = try container.decode([JournalEntry].self, forKey: .entries)
        attachments = try container.decodeIfPresent([PlaceAttachment].self, forKey: .attachments) ?? []
        routes = try container.decodeIfPresent([TravelRoute].self, forKey: .routes) ?? []
    }
}

public struct EmbeddedMedia: Codable, Equatable, Sendable {
    public let attachmentID: UUID
    public let kind: AttachmentKind
    public let filename: String
    public let data: Data

    public init(attachmentID: UUID, kind: AttachmentKind, filename: String, data: Data) {
        self.attachmentID = attachmentID
        self.kind = kind
        self.filename = filename
        self.data = data
    }
}

public struct AtlasBackupArchive: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let snapshot: AtlasSnapshot
    public let media: [EmbeddedMedia]

    public init(
        formatVersion: Int = AtlasBackupArchive.formatVersion,
        exportedAt: Date = .now,
        snapshot: AtlasSnapshot,
        media: [EmbeddedMedia] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.snapshot = snapshot
        self.media = media
    }
}

public enum PlaceMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites
    case withPhotos
    case withVoiceNotes
    case withNotes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .withPhotos: "Photos"
        case .withVoiceNotes: "Voice"
        case .withNotes: "Notes"
        }
    }
}

public enum AtlasCatalog {
    public static let lisbonID = UUID(uuidString: "11111111-1111-4111-8111-111111111101")!
    public static let tokyoID = UUID(uuidString: "11111111-1111-4111-8111-111111111102")!
    public static let parisID = UUID(uuidString: "11111111-1111-4111-8111-111111111103")!
    public static let nycID = UUID(uuidString: "11111111-1111-4111-8111-111111111104")!
    public static let kyotoID = UUID(uuidString: "11111111-1111-4111-8111-111111111105")!
    public static let istanbulID = UUID(uuidString: "11111111-1111-4111-8111-111111111106")!
    public static let reykjavikID = UUID(uuidString: "11111111-1111-4111-8111-111111111107")!
    public static let dolomitesID = UUID(uuidString: "11111111-1111-4111-8111-111111111108")!

    public static let istanbulCoreID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    public static let istanbulHistoricID = UUID(uuidString: "11111111-1111-4111-8111-111111111112")!
    public static let istanbulAnatoliaID = UUID(uuidString: "11111111-1111-4111-8111-111111111113")!
    public static let istanbulUpperBosphorusID = UUID(uuidString: "11111111-1111-4111-8111-111111111114")!
    public static let istanbulAdalarID = UUID(uuidString: "11111111-1111-4111-8111-111111111115")!
    public static let istanbulWestID = UUID(uuidString: "11111111-1111-4111-8111-111111111116")!

    public static let ankaraID = UUID(uuidString: "11111111-1111-4111-8111-111111111121")!
    public static let izmirID = UUID(uuidString: "11111111-1111-4111-8111-111111111122")!
    public static let antalyaID = UUID(uuidString: "11111111-1111-4111-8111-111111111123")!
    public static let cappadociaID = UUID(uuidString: "11111111-1111-4111-8111-111111111124")!
    public static let bodrumID = UUID(uuidString: "11111111-1111-4111-8111-111111111125")!
    public static let fethiyeID = UUID(uuidString: "11111111-1111-4111-8111-111111111126")!
    public static let trabzonID = UUID(uuidString: "11111111-1111-4111-8111-111111111127")!

    public static let londonID = UUID(uuidString: "11111111-1111-4111-8111-111111111131")!
    public static let romeID = UUID(uuidString: "11111111-1111-4111-8111-111111111132")!
    public static let barcelonaID = UUID(uuidString: "11111111-1111-4111-8111-111111111133")!
    public static let amsterdamID = UUID(uuidString: "11111111-1111-4111-8111-111111111134")!
    public static let berlinID = UUID(uuidString: "11111111-1111-4111-8111-111111111135")!
    public static let viennaID = UUID(uuidString: "11111111-1111-4111-8111-111111111136")!
    public static let pragueID = UUID(uuidString: "11111111-1111-4111-8111-111111111137")!
    public static let athensID = UUID(uuidString: "11111111-1111-4111-8111-111111111138")!
    public static let madridID = UUID(uuidString: "11111111-1111-4111-8111-111111111139")!
    public static let milanID = UUID(uuidString: "11111111-1111-4111-8111-111111111140")!
    public static let zurichID = UUID(uuidString: "11111111-1111-4111-8111-111111111141")!

    public static let seoulID = UUID(uuidString: "11111111-1111-4111-8111-111111111151")!
    public static let bangkokID = UUID(uuidString: "11111111-1111-4111-8111-111111111152")!
    public static let dubaiID = UUID(uuidString: "11111111-1111-4111-8111-111111111153")!
    public static let singaporeID = UUID(uuidString: "11111111-1111-4111-8111-111111111154")!
    public static let cairoID = UUID(uuidString: "11111111-1111-4111-8111-111111111155")!
    public static let sanFranciscoID = UUID(uuidString: "11111111-1111-4111-8111-111111111156")!
    public static let sydneyID = UUID(uuidString: "11111111-1111-4111-8111-111111111157")!

    public static let galataPlaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222202")!
    public static let modaPlaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222203")!
    public static let miradouroPlaceID = UUID(uuidString: "22222222-2222-4222-8222-222222222201")!
    public static let galataWalkID = UUID(uuidString: "33333333-3333-4333-8333-333333333302")!
    public static let alfamaWalkID = UUID(uuidString: "33333333-3333-4333-8333-333333333301")!

    public static let regions: [AtlasRegion] = [
        // Istanbul packs (city-wide + district packs sized cleanly within OpenFreeMap limits)
        AtlasRegion(
            id: istanbulID,
            slug: "tr-istanbul-metro",
            name: "Istanbul — Complete Metro (Europe & Asia)",
            countryCode: "TR",
            mapPackageSize: 56_000_000,
            bounds: RegionBounds(centerLatitude: 41.0600, centerLongitude: 28.9800, latitudeDelta: 0.44, longitudeDelta: 0.72)
        ),
        // Kept at index 1 (.available) for unit tests and global catalog continuity.
        AtlasRegion(
            id: tokyoID,
            slug: "jp-tokyo",
            name: "Tokyo",
            countryCode: "JP",
            mapPackageSize: 23_000_000,
            bounds: RegionBounds(centerLatitude: 35.6762, centerLongitude: 139.6503, latitudeDelta: 0.35, longitudeDelta: 0.40)
        ),
        AtlasRegion(
            id: istanbulCoreID,
            slug: "tr-istanbul-core",
            name: "Istanbul — City Core & Bosphorus",
            countryCode: "TR",
            mapPackageSize: 15_000_000,
            bounds: RegionBounds(centerLatitude: 41.0350, centerLongitude: 29.0100, latitudeDelta: 0.24, longitudeDelta: 0.30)
        ),
        AtlasRegion(
            id: istanbulHistoricID,
            slug: "tr-istanbul-historic",
            name: "Istanbul — Historic Peninsula & Beyoğlu",
            countryCode: "TR",
            mapPackageSize: 6_000_000,
            bounds: RegionBounds(centerLatitude: 41.0180, centerLongitude: 28.9720, latitudeDelta: 0.10, longitudeDelta: 0.14)
        ),
        AtlasRegion(
            id: istanbulAnatoliaID,
            slug: "tr-istanbul-anatolia",
            name: "Istanbul — Anatolian Coast (Kadıköy – Üsküdar)",
            countryCode: "TR",
            mapPackageSize: 9_000_000,
            bounds: RegionBounds(centerLatitude: 40.9850, centerLongitude: 29.0750, latitudeDelta: 0.16, longitudeDelta: 0.22)
        ),
        AtlasRegion(
            id: istanbulUpperBosphorusID,
            slug: "tr-istanbul-upper-bosphorus",
            name: "Istanbul — Upper Bosphorus & Sarıyer",
            countryCode: "TR",
            mapPackageSize: 7_000_000,
            bounds: RegionBounds(centerLatitude: 41.1350, centerLongitude: 29.0550, latitudeDelta: 0.16, longitudeDelta: 0.18)
        ),
        AtlasRegion(
            id: istanbulAdalarID,
            slug: "tr-istanbul-adalar",
            name: "Istanbul — Princes' Islands (Adalar)",
            countryCode: "TR",
            mapPackageSize: 5_000_000,
            bounds: RegionBounds(centerLatitude: 40.8720, centerLongitude: 29.0950, latitudeDelta: 0.08, longitudeDelta: 0.13)
        ),
        AtlasRegion(
            id: istanbulWestID,
            slug: "tr-istanbul-west",
            name: "Istanbul — Bakırköy & Florya Coast",
            countryCode: "TR",
            mapPackageSize: 6_500_000,
            bounds: RegionBounds(centerLatitude: 40.9850, centerLongitude: 28.8400, latitudeDelta: 0.14, longitudeDelta: 0.18)
        ),

        // Turkey Destinations
        AtlasRegion(
            id: ankaraID,
            slug: "tr-ankara",
            name: "Ankara",
            countryCode: "TR",
            mapPackageSize: 13_000_000,
            bounds: RegionBounds(centerLatitude: 39.9208, centerLongitude: 32.8541, latitudeDelta: 0.24, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: izmirID,
            slug: "tr-izmir-cesme",
            name: "İzmir & Urla",
            countryCode: "TR",
            mapPackageSize: 13_000_000,
            bounds: RegionBounds(centerLatitude: 38.4192, centerLongitude: 27.1287, latitudeDelta: 0.24, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: antalyaID,
            slug: "tr-antalya",
            name: "Antalya & Kaleiçi",
            countryCode: "TR",
            mapPackageSize: 11_000_000,
            bounds: RegionBounds(centerLatitude: 36.8841, centerLongitude: 30.7056, latitudeDelta: 0.22, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: cappadociaID,
            slug: "tr-cappadocia",
            name: "Cappadocia (Göreme & Ürgüp)",
            countryCode: "TR",
            mapPackageSize: 15_000_000,
            bounds: RegionBounds(centerLatitude: 38.6431, centerLongitude: 34.8289, latitudeDelta: 0.24, longitudeDelta: 0.32)
        ),
        AtlasRegion(
            id: bodrumID,
            slug: "tr-bodrum",
            name: "Bodrum Peninsula",
            countryCode: "TR",
            mapPackageSize: 11_500_000,
            bounds: RegionBounds(centerLatitude: 37.0344, centerLongitude: 27.4305, latitudeDelta: 0.20, longitudeDelta: 0.30)
        ),
        AtlasRegion(
            id: fethiyeID,
            slug: "tr-fethiye",
            name: "Fethiye & Ölüdeniz",
            countryCode: "TR",
            mapPackageSize: 10_500_000,
            bounds: RegionBounds(centerLatitude: 36.6050, centerLongitude: 29.1150, latitudeDelta: 0.22, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: trabzonID,
            slug: "tr-trabzon",
            name: "Trabzon & Uzungöl",
            countryCode: "TR",
            mapPackageSize: 18_000_000,
            bounds: RegionBounds(centerLatitude: 40.8800, centerLongitude: 39.8500, latitudeDelta: 0.36, longitudeDelta: 0.56)
        ),

        // Europe
        AtlasRegion(
            id: lisbonID,
            slug: "pt-lisbon-sintra",
            name: "Lisbon & Sintra",
            countryCode: "PT",
            mapPackageSize: 17_000_000,
            bounds: RegionBounds(centerLatitude: 38.7369, centerLongitude: -9.2100, latitudeDelta: 0.25, longitudeDelta: 0.35)
        ),
        AtlasRegion(
            id: parisID,
            slug: "fr-paris",
            name: "Paris",
            countryCode: "FR",
            mapPackageSize: 15_000_000,
            bounds: RegionBounds(centerLatitude: 48.8566, centerLongitude: 2.3522, latitudeDelta: 0.22, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: londonID,
            slug: "gb-london",
            name: "London",
            countryCode: "GB",
            mapPackageSize: 22_500_000,
            bounds: RegionBounds(centerLatitude: 51.5074, centerLongitude: -0.1278, latitudeDelta: 0.26, longitudeDelta: 0.38)
        ),
        AtlasRegion(
            id: romeID,
            slug: "it-rome",
            name: "Rome",
            countryCode: "IT",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 41.9028, centerLongitude: 12.4964, latitudeDelta: 0.22, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: barcelonaID,
            slug: "es-barcelona",
            name: "Barcelona",
            countryCode: "ES",
            mapPackageSize: 10_500_000,
            bounds: RegionBounds(centerLatitude: 41.3874, centerLongitude: 2.1686, latitudeDelta: 0.20, longitudeDelta: 0.24)
        ),
        AtlasRegion(
            id: amsterdamID,
            slug: "nl-amsterdam",
            name: "Amsterdam",
            countryCode: "NL",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 52.3676, centerLongitude: 4.9041, latitudeDelta: 0.18, longitudeDelta: 0.26)
        ),
        AtlasRegion(
            id: berlinID,
            slug: "de-berlin",
            name: "Berlin",
            countryCode: "DE",
            mapPackageSize: 21_000_000,
            bounds: RegionBounds(centerLatitude: 52.5200, centerLongitude: 13.4050, latitudeDelta: 0.24, longitudeDelta: 0.36)
        ),
        AtlasRegion(
            id: viennaID,
            slug: "at-vienna",
            name: "Vienna",
            countryCode: "AT",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 48.2082, centerLongitude: 16.3738, latitudeDelta: 0.20, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: pragueID,
            slug: "cz-prague",
            name: "Prague",
            countryCode: "CZ",
            mapPackageSize: 11_000_000,
            bounds: RegionBounds(centerLatitude: 50.0755, centerLongitude: 14.4378, latitudeDelta: 0.18, longitudeDelta: 0.26)
        ),
        AtlasRegion(
            id: athensID,
            slug: "gr-athens",
            name: "Athens",
            countryCode: "GR",
            mapPackageSize: 10_000_000,
            bounds: RegionBounds(centerLatitude: 37.9838, centerLongitude: 23.7275, latitudeDelta: 0.20, longitudeDelta: 0.24)
        ),
        AtlasRegion(
            id: madridID,
            slug: "es-madrid",
            name: "Madrid",
            countryCode: "ES",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 40.4168, centerLongitude: -3.7038, latitudeDelta: 0.22, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: milanID,
            slug: "it-milan",
            name: "Milan",
            countryCode: "IT",
            mapPackageSize: 12_500_000,
            bounds: RegionBounds(centerLatitude: 45.4642, centerLongitude: 9.1900, latitudeDelta: 0.20, longitudeDelta: 0.28)
        ),
        AtlasRegion(
            id: zurichID,
            slug: "ch-zurich",
            name: "Zurich",
            countryCode: "CH",
            mapPackageSize: 10_500_000,
            bounds: RegionBounds(centerLatitude: 47.3769, centerLongitude: 8.5417, latitudeDelta: 0.18, longitudeDelta: 0.24)
        ),
        AtlasRegion(
            id: reykjavikID,
            slug: "is-reykjavik",
            name: "Reykjavik & Golden Circle",
            countryCode: "IS",
            mapPackageSize: 33_000_000,
            bounds: RegionBounds(centerLatitude: 64.1466, centerLongitude: -21.9426, latitudeDelta: 0.50, longitudeDelta: 0.90)
        ),
        AtlasRegion(
            id: dolomitesID,
            slug: "it-dolomites",
            name: "Dolomites",
            countryCode: "IT",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 46.5405, centerLongitude: 11.8440, latitudeDelta: 0.40, longitudeDelta: 0.56)
        ),

        // Asia, Middle East, Americas & Oceania
        AtlasRegion(
            id: kyotoID,
            slug: "jp-kyoto",
            name: "Kyoto",
            countryCode: "JP",
            mapPackageSize: 11_000_000,
            bounds: RegionBounds(centerLatitude: 35.0116, centerLongitude: 135.7681, latitudeDelta: 0.22, longitudeDelta: 0.24)
        ),
        AtlasRegion(
            id: seoulID,
            slug: "kr-seoul",
            name: "Seoul",
            countryCode: "KR",
            mapPackageSize: 16_500_000,
            bounds: RegionBounds(centerLatitude: 37.5665, centerLongitude: 126.9780, latitudeDelta: 0.26, longitudeDelta: 0.34)
        ),
        AtlasRegion(
            id: bangkokID,
            slug: "th-bangkok",
            name: "Bangkok",
            countryCode: "TH",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 13.7563, centerLongitude: 100.5018, latitudeDelta: 0.26, longitudeDelta: 0.30)
        ),
        AtlasRegion(
            id: dubaiID,
            slug: "ae-dubai",
            name: "Dubai",
            countryCode: "AE",
            mapPackageSize: 13_500_000,
            bounds: RegionBounds(centerLatitude: 25.2048, centerLongitude: 55.2708, latitudeDelta: 0.24, longitudeDelta: 0.30)
        ),
        AtlasRegion(
            id: singaporeID,
            slug: "sg-singapore",
            name: "Singapore",
            countryCode: "SG",
            mapPackageSize: 12_000_000,
            bounds: RegionBounds(centerLatitude: 1.3521, centerLongitude: 103.8198, latitudeDelta: 0.24, longitudeDelta: 0.34)
        ),
        AtlasRegion(
            id: cairoID,
            slug: "eg-cairo",
            name: "Cairo & Giza",
            countryCode: "EG",
            mapPackageSize: 14_500_000,
            bounds: RegionBounds(centerLatitude: 30.0444, centerLongitude: 31.2357, latitudeDelta: 0.26, longitudeDelta: 0.30)
        ),
        AtlasRegion(
            id: nycID,
            slug: "us-new-york-city",
            name: "New York City",
            countryCode: "US",
            mapPackageSize: 19_000_000,
            bounds: RegionBounds(centerLatitude: 40.7128, centerLongitude: -74.0060, latitudeDelta: 0.32, longitudeDelta: 0.32)
        ),
        AtlasRegion(
            id: sanFranciscoID,
            slug: "us-san-francisco",
            name: "San Francisco Bay",
            countryCode: "US",
            mapPackageSize: 22_000_000,
            bounds: RegionBounds(centerLatitude: 37.7749, centerLongitude: -122.4194, latitudeDelta: 0.34, longitudeDelta: 0.36)
        ),
        AtlasRegion(
            id: sydneyID,
            slug: "au-sydney",
            name: "Sydney",
            countryCode: "AU",
            mapPackageSize: 14_500_000,
            bounds: RegionBounds(centerLatitude: -33.8688, centerLongitude: 151.2093, latitudeDelta: 0.26, longitudeDelta: 0.30)
        )
    ]

    /// Start with no fake "downloaded" regions so every offline badge reflects a real downloaded MapLibre pack.
    public static var defaultSeedRegions: [AtlasRegion] {
        []
    }

    public static var defaultSeedPlaces: [Place] {
        [
            Place(
                id: galataPlaceID,
                name: "Galata Tower Overlook",
                subtitle: "Beyoğlu, Istanbul",
                latitude: 41.0256,
                longitude: 28.9741,
                visitedAt: Date(timeIntervalSinceNow: -86_400),
                category: .viewpoint,
                isFavorite: true,
                rating: 5,
                note: "Golden Horn ferries crossing at dusk with Süleymaniye silhouetted on the ridge.",
                attachmentCount: 0,
                regionID: istanbulCoreID
            ),
            Place(
                id: modaPlaceID,
                name: "Moda Pier Coastline",
                subtitle: "Kadıköy, Istanbul",
                latitude: 40.9794,
                longitude: 29.0251,
                visitedAt: Date(timeIntervalSinceNow: -86_400 * 1.5),
                category: .nature,
                isFavorite: true,
                rating: 5,
                note: "Evening sea breeze along the stone seawall facing the Princes' Islands.",
                attachmentCount: 0,
                regionID: istanbulAnatoliaID
            ),
            Place(
                id: miradouroPlaceID,
                name: "Miradouro da Senhora do Monte",
                subtitle: "Lisbon, Portugal",
                latitude: 38.7192,
                longitude: -9.1326,
                visitedAt: Date(timeIntervalSinceNow: -86_400 * 2),
                category: .viewpoint,
                isFavorite: true,
                rating: 5,
                note: "The city opened up below us just before sunset. Terracotta rooftops turned amber above the Tagus.",
                attachmentCount: 0,
                regionID: lisbonID
            )
        ]
    }

    public static var defaultSeedEntries: [JournalEntry] {
        [
            JournalEntry(
                placeID: galataPlaceID,
                title: "Karaköy steps to Galata",
                body: "Stopped for Turkish coffee on the stone alley before catching the ferry across to Kadıköy.",
                createdAt: Date(timeIntervalSinceNow: -86_400 + 900)
            ),
            JournalEntry(
                placeID: miradouroPlaceID,
                title: "Golden hour over Graça",
                body: "Walked up the steep cobblestones from Martim Moniz. Brought two pastel de nata from the corner bakery and stayed until the bridge lights flickered on.",
                createdAt: Date(timeIntervalSinceNow: -86_400 * 2 + 1200)
            )
        ]
    }

    public static var defaultSeedRoutes: [TravelRoute] {
        [
            TravelRoute(
                id: galataWalkID,
                title: "Karaköy to Galata Promenade",
                startedAt: Date(timeIntervalSinceNow: -86_400),
                endedAt: Date(timeIntervalSinceNow: -86_400 + 1_920),
                points: [
                    Coordinate(latitude: 41.0226, longitude: 28.9772),
                    Coordinate(latitude: 41.0239, longitude: 28.9758),
                    Coordinate(latitude: 41.0256, longitude: 28.9741),
                    Coordinate(latitude: 41.0282, longitude: 28.9760)
                ],
                note: "Historic stone stairways up from the Bosphorus."
            ),
            TravelRoute(
                id: alfamaWalkID,
                title: "Graça to Alfama Ridge Walk",
                startedAt: Date(timeIntervalSinceNow: -86_400 * 2),
                endedAt: Date(timeIntervalSinceNow: -86_400 * 2 + 2_340),
                points: [
                    Coordinate(latitude: 38.7192, longitude: -9.1326),
                    Coordinate(latitude: 38.7168, longitude: -9.1304),
                    Coordinate(latitude: 38.7141, longitude: -9.1292),
                    Coordinate(latitude: 38.7118, longitude: -9.1308)
                ],
                note: "Evening ridge walk before dinner."
            )
        ]
    }
}
