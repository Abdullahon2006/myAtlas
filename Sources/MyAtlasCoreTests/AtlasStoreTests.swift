import XCTest
#if canImport(MyAtlasCore)
@testable import MyAtlasCore
#else
@testable import myatlas
#endif

final class AtlasStoreTests: XCTestCase {
    func testPlacesAreReturnedNewestFirst() async {
        let older = Place(
            name: "Lisbon",
            subtitle: "Portugal",
            latitude: 38.7223,
            longitude: -9.1393,
            visitedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = Place(
            name: "Porto",
            subtitle: "Portugal",
            latitude: 41.1579,
            longitude: -8.6291,
            visitedAt: Date(timeIntervalSince1970: 20)
        )
        let store = AtlasStore(places: [older, newer])

        let places = await store.allPlaces()

        XCTAssertEqual(places.map(\.name), ["Porto", "Lisbon"])
    }

    func testRegionUpsertDeduplicatesBySlugAndPunctuationSlugFallsBackSafely() async {
        let punctuationRegion = AtlasRegion(name: "!!!", countryCode: "---", mapPackageSize: 50)
        XCTAssertTrue(punctuationRegion.slug.hasPrefix("region-"))

        let region = AtlasRegion(name: "Kyoto", countryCode: "JP", mapPackageSize: 100)
        let duplicateSlugRegion = AtlasRegion(name: "Kyoto", countryCode: "JP", mapPackageSize: 150, downloadState: .downloaded)
        let store = AtlasStore(regions: [region])

        await store.upsert(region: duplicateSlugRegion)
        let updatedRegions = await store.allRegions()
        XCTAssertEqual(updatedRegions.count, 1)
        XCTAssertEqual(updatedRegions.first?.downloadState, .downloaded)

        await store.remove(regionID: duplicateSlugRegion.id)
        let remainingRegions = await store.allRegions()
        XCTAssertTrue(remainingRegions.isEmpty)
    }

    func testStoreRestoresPersistedSnapshotAndNormalizesInterruptedDownloads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("atlas.json")

        let place = Place(
            name: "Reykjavik",
            subtitle: "Iceland",
            latitude: 64.1466,
            longitude: -21.9426,
            visitedAt: .now,
            category: .nature,
            isFavorite: true
        )
        let downloadingRegion = AtlasRegion(
            name: "Tokyo",
            countryCode: "JP",
            mapPackageSize: 320_000_000,
            downloadState: .downloading(progress: 0.4)
        )

        let firstStore = AtlasStore(persistenceURL: url)
        await firstStore.add(place: place)
        await firstStore.add(region: downloadingRegion)

        let restoredStore = AtlasStore(persistenceURL: url)
        let restoredPlaces = await restoredStore.allPlaces()
        let restoredRegions = await restoredStore.allRegions()

        XCTAssertEqual(restoredPlaces.map(\.name), ["Reykjavik"])
        XCTAssertEqual(restoredPlaces.first?.category, .nature)
        XCTAssertEqual(restoredPlaces.first?.isFavorite, true)
        XCTAssertEqual(restoredRegions.first?.downloadState, .available)
    }

    func testCorruptPersistenceFileIsBackedUpInsteadOfSilentlyOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("atlas.json")
        try Data("{not valid json".utf8).write(to: url)

        let store = AtlasStore(persistenceURL: url)
        XCTAssertNotNil(store.recoveryWarning)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("atlas.corrupt.") })
    }

    func testAttachmentCountsReconcileAndCascadeOnPlaceDelete() async {
        let place = Place(
            name: "Bosphorus",
            subtitle: "Istanbul, Turkey",
            latitude: 41.0422,
            longitude: 29.0067,
            visitedAt: .now,
            attachmentCount: 99
        )
        let photo = PlaceAttachment(placeID: place.id, kind: .photo, filename: "p1.jpg")
        let entry = JournalEntry(placeID: place.id, title: "Ferry", body: "Tea on deck")

        let store = AtlasStore(places: [place], entries: [entry], attachments: [photo])
        let initialPlace = await store.place(id: place.id)
        XCTAssertEqual(initialPlace?.attachmentCount, 1)

        let voice = PlaceAttachment(placeID: place.id, kind: .voice, filename: "v1.m4a", durationSeconds: 12)
        await store.add(attachment: voice)
        let afterAdd = await store.place(id: place.id)
        XCTAssertEqual(afterAdd?.attachmentCount, 2)

        let removed = await store.delete(placeID: place.id)
        XCTAssertEqual(removed.count, 2)
        let remainingPlaces = await store.allPlaces()
        let remainingEntries = await store.entries(for: place.id)
        XCTAssertTrue(remainingPlaces.isEmpty)
        XCTAssertTrue(remainingEntries.isEmpty)
    }

    func testSearchPlacesFiltersByQueryCategoryAndMedia() async {
        let p1 = Place(
            name: "Sensō-ji",
            subtitle: "Tokyo, Japan",
            latitude: 35.7148,
            longitude: 139.7967,
            visitedAt: .now,
            category: .culture,
            isFavorite: true,
            note: "Lanterns in the rain"
        )
        let p2 = Place(
            name: "Blue Bottle",
            subtitle: "Kyoto, Japan",
            latitude: 35.0116,
            longitude: 135.7681,
            visitedAt: Date(timeIntervalSinceNow: -100),
            category: .food
        )
        let photo = PlaceAttachment(placeID: p1.id, kind: .photo, filename: "temple.jpg")
        let entry = JournalEntry(placeID: p2.id, body: "Matcha affogato")

        let store = AtlasStore(places: [p1, p2], entries: [entry], attachments: [photo])

        let favs = await store.searchPlaces(query: "", mediaFilter: .favorites)
        XCTAssertEqual(favs.map(\.id), [p1.id])

        let entryHit = await store.searchPlaces(query: "affogato")
        XCTAssertEqual(entryHit.map(\.id), [p2.id])

        let culture = await store.searchPlaces(query: "", category: .culture)
        XCTAssertEqual(culture.map(\.id), [p1.id])
    }

    func testV1SnapshotDecodesWithoutRoutesOrSchemaVersion() throws {
        let v1JSON = """
        {
          "regions": [],
          "places": [
            {
              "id": "22222222-2222-4222-8222-222222222201",
              "name": "Alfama",
              "subtitle": "Lisbon",
              "latitude": 38.7117,
              "longitude": -9.1303,
              "visitedAt": 0
            }
          ],
          "entries": []
        }
        """
        let snapshot = try AtlasExporter.decodeSnapshot(from: Data(v1JSON.utf8))
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.places.count, 1)
        XCTAssertEqual(snapshot.places.first?.category, .note)
        XCTAssertTrue(snapshot.attachments.isEmpty)
        XCTAssertTrue(snapshot.routes.isEmpty)
    }

    func testRouteDistanceExportersAndBackupRoundTrip() async throws {
        let start = Coordinate(latitude: 38.7192, longitude: -9.1326, altitude: .nan, recordedAt: Date(timeIntervalSince1970: 1000))
        let end = Coordinate(latitude: 38.7118, longitude: -9.1308, altitude: 42.5, recordedAt: Date(timeIntervalSince1970: 1600))
        let route = TravelRoute(title: "Ridge\u{0000} & <Valley>", startedAt: Date(timeIntervalSince1970: 1000), endedAt: Date(timeIntervalSince1970: 1600), points: [start, end])

        XCTAssertGreaterThan(route.totalDistanceMeters, 700)
        XCTAssertLessThan(route.totalDistanceMeters, 1000)

        let place = Place(name: "Miradouro", subtitle: "Lisbon", latitude: 38.7192, longitude: -9.1326, visitedAt: .now, isFavorite: true)
        let snapshot = AtlasSnapshot(regions: [], places: [place], entries: [], attachments: [], routes: [route])

        let md = AtlasExporter.exportMarkdown(snapshot: snapshot)
        XCTAssertTrue(md.contains("## Miradouro ★"))

        let gpx = AtlasExporter.exportGPX(routes: [route], places: [place])
        XCTAssertTrue(gpx.contains("<name>Ridge &amp; &lt;Valley&gt;</name>"))
        XCTAssertFalse(gpx.contains("<ele>nan</ele>"))
        XCTAssertTrue(gpx.contains("<ele>42.5</ele>"))

        let jsonData = try AtlasExporter.exportJSON(snapshot: snapshot)
        let decodedBackup = try AtlasExporter.decodeBackup(from: jsonData)
        XCTAssertEqual(decodedBackup.snapshot.places.map(\.id), [place.id])

        let store = AtlasStore()
        await store.restore(from: decodedBackup.snapshot, merge: false)
        let restoredPlaces = await store.allPlaces()
        XCTAssertEqual(restoredPlaces.count, 1)
    }

    func testCatalogRegionsRespectTileBudgetAndIncludeIstanbulPacks() {
        XCTAssertGreaterThanOrEqual(AtlasCatalog.regions.count, 30)
        let istanbulPacks = AtlasCatalog.regions.filter { $0.slug.hasPrefix("tr-istanbul") }
        XCTAssertGreaterThanOrEqual(istanbulPacks.count, 6)

        for region in AtlasCatalog.regions {
            guard let bounds = region.bounds else {
                XCTFail("Missing bounds for \(region.slug)")
                continue
            }
            let safeMaxZoom = bounds.safeOfflineMaxZoom(maxTileBudget: 2_200, minZoom: 0, preferredMaxZoom: 14)
            let tileCount = bounds.estimatedTileCount(minZoom: 0, maxZoom: safeMaxZoom)
            XCTAssertLessThanOrEqual(tileCount, 2_200, "Tile budget exceeded for \(region.slug)")
            XCTAssertGreaterThan(bounds.estimatedOfflineBytes(), 0)
        }
    }
}
