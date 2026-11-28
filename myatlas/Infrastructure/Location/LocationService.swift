import CoreLocation
import Foundation
import MapKit

struct PlaceSearchSuggestion: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: Coordinate
}

private final class ContinuationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Coordinate?, Never>?
    private var activeToken: UUID?

    func replace(with newContinuation: CheckedContinuation<Coordinate?, Never>, token: UUID) {
        lock.lock()
        let previous = continuation
        continuation = newContinuation
        activeToken = token
        lock.unlock()
        previous?.resume(returning: nil)
    }

    func resume(with coordinate: Coordinate?, expectedToken: UUID? = nil) {
        lock.lock()
        if let expectedToken, activeToken != expectedToken {
            lock.unlock()
            return
        }
        let current = continuation
        continuation = nil
        activeToken = nil
        lock.unlock()
        current?.resume(returning: coordinate)
    }
}

@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentCoordinate: Coordinate?
    @Published private(set) var isRequestingLocation = false
    @Published var locationErrorMessage: String?

    // Foreground-only, opt-in route recording state
    @Published private(set) var isRecordingRoute = false
    @Published private(set) var isRoutePaused = false
    @Published private(set) var activeRouteTitle = ""
    @Published private(set) var routeStartedAt: Date?
    @Published private(set) var recordedPoints: [Coordinate] = []
    @Published private(set) var recordedDistanceMeters: Double = 0
    @Published private(set) var elapsedRecordingSeconds: TimeInterval = 0

    private let manager: CLLocationManager
    private let geocoder = CLGeocoder()
    private let locationSlot = ContinuationSlot()
    private var locationTimeoutTask: Task<Void, Never>?
    private var routeTimerTask: Task<Void, Never>?
    private var activeSegmentStart: Date?
    private var accumulatedActiveSeconds: TimeInterval = 0

    override init() {
        let locationManager = CLLocationManager()
        self.manager = locationManager
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 8
        // Foreground-only by policy: never enable background location updates.
    }

    deinit {
        locationSlot.resume(with: nil)
        locationTimeoutTask?.cancel()
        routeTimerTask?.cancel()
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestCurrentCoordinate() async -> Coordinate? {
        locationErrorMessage = nil

        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return nil
        } else if isDenied {
            locationErrorMessage = "Location access is off. You can still tap the map or enter coordinates offline."
            return nil
        }

        isRequestingLocation = true
        let token = UUID()
        locationTimeoutTask?.cancel()

        let result: Coordinate? = await withCheckedContinuation { continuation in
            locationSlot.replace(with: continuation, token: token)
            manager.requestLocation()

            locationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self else { return }
                self.locationSlot.resume(with: self.currentCoordinate, expectedToken: token)
            }
        }

        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        isRequestingLocation = false
        return result
    }

    func reverseGeocodeSubtitle(for coordinate: Coordinate) async -> String? {
        if geocoder.isGeocoding {
            geocoder.cancelGeocode()
        }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let first = placemarks.first else {
            return nil
        }
        let parts = [first.locality ?? first.subAdministrativeArea, first.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    func searchPlaces(query: String, near region: MKCoordinateRegion?) async -> (suggestions: [PlaceSearchSuggestion], offlineNotice: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return ([], nil) }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let region {
            request.region = region
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.prefix(8).compactMap { item -> PlaceSearchSuggestion? in
                guard let name = item.name else { return nil }
                let coord = item.placemark.coordinate
                let subtitleParts = [
                    item.placemark.locality ?? item.placemark.administrativeArea,
                    item.placemark.country
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                return PlaceSearchSuggestion(
                    name: name,
                    subtitle: subtitleParts.isEmpty ? Coordinate(latitude: coord.latitude, longitude: coord.longitude).formattedString : subtitleParts.joined(separator: ", "),
                    coordinate: Coordinate(latitude: coord.latitude, longitude: coord.longitude)
                )
            }
            return (results, results.isEmpty ? "No places found for \"\(trimmed)\"." : nil)
        } catch {
            return ([], "Place search needs a network connection. Tap the map or use coordinates offline.")
        }
    }

    // MARK: - Foreground-Only Route Recording

    func startRouteRecording(title: String? = nil) -> Bool {
        guard !isRecordingRoute else { return true }
        locationErrorMessage = nil

        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isDenied {
            locationErrorMessage = "Location permission is required to record a walk."
            return false
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeRouteTitle = trimmedTitle.isEmpty ? Self.defaultRouteTitle() : trimmedTitle
        routeStartedAt = .now
        recordedPoints = []
        if let currentCoordinate {
            recordedPoints.append(
                Coordinate(
                    latitude: currentCoordinate.latitude,
                    longitude: currentCoordinate.longitude,
                    altitude: currentCoordinate.altitude,
                    recordedAt: .now
                )
            )
        }
        recordedDistanceMeters = 0
        accumulatedActiveSeconds = 0
        elapsedRecordingSeconds = 0
        activeSegmentStart = .now
        isRecordingRoute = true
        isRoutePaused = false

        if isAuthorized {
            manager.startUpdatingLocation()
        }
        startRouteTimer()
        return true
    }

    func pauseRouteRecording() {
        guard isRecordingRoute, !isRoutePaused else { return }
        if let activeSegmentStart {
            accumulatedActiveSeconds += Date().timeIntervalSince(activeSegmentStart)
        }
        activeSegmentStart = nil
        isRoutePaused = true
        routeTimerTask?.cancel()
        routeTimerTask = nil
        manager.stopUpdatingLocation()
    }

    func resumeRouteRecording() {
        guard isRecordingRoute, isRoutePaused else { return }
        activeSegmentStart = .now
        isRoutePaused = false
        if isAuthorized {
            manager.startUpdatingLocation()
        }
        startRouteTimer()
    }

    func stopRouteRecording(customTitle: String? = nil, note: String? = nil) -> TravelRoute? {
        guard isRecordingRoute else { return nil }
        routeTimerTask?.cancel()
        routeTimerTask = nil
        manager.stopUpdatingLocation()

        if let activeSegmentStart, !isRoutePaused {
            accumulatedActiveSeconds += Date().timeIntervalSince(activeSegmentStart)
        }

        let started = routeStartedAt ?? .now
        let cleanTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = cleanTitle.isEmpty
            ? (activeRouteTitle.isEmpty ? Self.defaultRouteTitle() : activeRouteTitle)
            : cleanTitle
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        let route = TravelRoute(
            title: resolvedTitle,
            startedAt: started,
            endedAt: .now,
            points: recordedPoints,
            totalDistanceMeters: recordedDistanceMeters,
            note: (cleanNote?.isEmpty == false) ? cleanNote : nil
        )

        resetRouteState()
        return route.points.isEmpty ? nil : route
    }

    func discardRouteRecording() {
        routeTimerTask?.cancel()
        routeTimerTask = nil
        manager.stopUpdatingLocation()
        resetRouteState()
    }

    private func resetRouteState() {
        isRecordingRoute = false
        isRoutePaused = false
        activeRouteTitle = ""
        routeStartedAt = nil
        recordedPoints = []
        recordedDistanceMeters = 0
        elapsedRecordingSeconds = 0
        accumulatedActiveSeconds = 0
        activeSegmentStart = nil
    }

    private func startRouteTimer() {
        routeTimerTask?.cancel()
        routeTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRecordingRoute, !self.isRoutePaused, let segmentStart = self.activeSegmentStart else {
                    break
                }
                self.elapsedRecordingSeconds = self.accumulatedActiveSeconds + Date().timeIntervalSince(segmentStart)
            }
        }
    }

    private static func defaultRouteTitle() -> String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Morning Walk"
        case 12..<17: return "Afternoon Walk"
        case 17..<21: return "Evening Walk"
        default: return "Night Walk"
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isAuthorized {
                self.locationErrorMessage = nil
                if self.isRecordingRoute && !self.isRoutePaused {
                    self.manager.startUpdatingLocation()
                }
            } else if self.isDenied && self.isRecordingRoute {
                self.discardRouteRecording()
                self.locationErrorMessage = "Location permission was denied, so route recording stopped."
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let validCoords = locations.compactMap { location -> Coordinate? in
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 65,
                  abs(location.timestamp.timeIntervalSinceNow) <= 15 else {
                return nil
            }
            let validAltitude = location.verticalAccuracy >= 0 ? location.altitude : nil
            return Coordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: validAltitude,
                recordedAt: location.timestamp
            )
        }
        guard let latestCoord = validCoords.last else { return }

        Task { @MainActor in
            self.currentCoordinate = latestCoord
            self.locationSlot.resume(with: latestCoord)

            if self.isRecordingRoute && !self.isRoutePaused {
                for point in validCoords {
                    if let previous = self.recordedPoints.last {
                        let stepDistance = previous.distance(to: point)
                        guard stepDistance >= 3 else { continue }
                        self.recordedDistanceMeters += stepDistance
                    }
                    self.recordedPoints.append(point)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isRequestingLocation = false
            self.locationSlot.resume(with: self.currentCoordinate)
            if (error as NSError).code != CLError.locationUnknown.rawValue {
                self.locationErrorMessage = "Unable to read your current location right now."
            }
        }
    }
}
