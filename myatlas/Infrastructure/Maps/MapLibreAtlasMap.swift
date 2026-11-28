import CoreLocation
import MapKit
import MapLibre
import SwiftUI
import UIKit

struct MapCameraRequest: Equatable {
    let token: UUID
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
    let animated: Bool

    init(
        region: MKCoordinateRegion,
        animated: Bool = true
    ) {
        self.token = UUID()
        self.centerLatitude = region.center.latitude
        self.centerLongitude = region.center.longitude
        self.latitudeDelta = region.span.latitudeDelta
        self.longitudeDelta = region.span.longitudeDelta
        self.animated = animated
    }

    var mkRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    var coordinateBounds: MLNCoordinateBounds {
        let halfLat = max(0.002, abs(latitudeDelta) / 2.0)
        let halfLon = max(0.002, abs(longitudeDelta) / 2.0)
        return MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(
                latitude: max(-85.0, centerLatitude - halfLat),
                longitude: max(-180.0, centerLongitude - halfLon)
            ),
            ne: CLLocationCoordinate2D(
                latitude: min(85.0, centerLatitude + halfLat),
                longitude: min(180.0, centerLongitude + halfLon)
            )
        )
    }
}

final class AtlasPlaceAnnotation: NSObject, MLNAnnotation {
    let placeID: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    let category: PlaceCategory
    let isFavorite: Bool

    init(place: Place) {
        self.placeID = place.id
        self.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        self.title = place.name
        self.subtitle = place.subtitle
        self.category = place.category
        self.isFavorite = place.isFavorite
        super.init()
    }
}

private final class AtlasPlaceAnnotationView: MLNAnnotationView {
    private let badgeView = UIView()
    private let iconImageView = UIImageView()

    override init(annotation: MLNAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
        apply(annotation: annotation)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override var isSelected: Bool {
        didSet {
            let scale: CGFloat = isSelected ? 1.18 : 1.0
            UIView.animate(withDuration: 0.18) {
                self.badgeView.transform = CGAffineTransform(scaleX: scale, y: scale)
                self.badgeView.layer.borderWidth = self.isSelected ? 2.5 : 2.0
            }
        }
    }

    func apply(annotation: MLNAnnotation?) {
        self.annotation = annotation
        guard let placeAnnotation = annotation as? AtlasPlaceAnnotation else { return }
        badgeView.backgroundColor = UIColor(placeAnnotation.category.pinFillColor)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconImageView.image = UIImage(systemName: placeAnnotation.category.systemImage, withConfiguration: symbolConfig)
        accessibilityLabel = placeAnnotation.title
    }

    private func setupView() {
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        backgroundColor = .clear
        scalesWithViewingDistance = false
        centerOffset = .zero

        badgeView.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
        badgeView.layer.cornerRadius = 16
        badgeView.layer.borderColor = UIColor.white.cgColor
        badgeView.layer.borderWidth = 2.0
        badgeView.layer.shadowColor = UIColor.black.cgColor
        badgeView.layer.shadowOpacity = 0.25
        badgeView.layer.shadowRadius = 4
        badgeView.layer.shadowOffset = CGSize(width: 0, height: 2)
        badgeView.isUserInteractionEnabled = false

        iconImageView.frame = CGRect(x: 6, y: 6, width: 20, height: 20)
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white

        badgeView.addSubview(iconImageView)
        addSubview(badgeView)
    }
}

private final class SinglePinAnnotation: NSObject, MLNAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    let category: PlaceCategory

    init(coordinate: CLLocationCoordinate2D, category: PlaceCategory) {
        self.coordinate = coordinate
        self.category = category
        super.init()
    }
}

private final class SinglePinAnnotationView: MLNAnnotationView {
    private let badgeView = UIView()
    private let iconImageView = UIImageView()

    override init(annotation: MLNAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
        apply(annotation: annotation)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func apply(annotation: MLNAnnotation?) {
        self.annotation = annotation
        guard let pin = annotation as? SinglePinAnnotation else { return }
        badgeView.backgroundColor = UIColor(pin.category.pinFillColor)
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconImageView.image = UIImage(systemName: pin.category.systemImage, withConfiguration: config)
    }

    private func setupView() {
        frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        backgroundColor = .clear
        scalesWithViewingDistance = false
        centerOffset = .zero

        badgeView.frame = CGRect(x: 2, y: 2, width: 32, height: 32)
        badgeView.layer.cornerRadius = 16
        badgeView.layer.borderColor = UIColor.white.cgColor
        badgeView.layer.borderWidth = 2.0
        badgeView.layer.shadowColor = UIColor.black.cgColor
        badgeView.layer.shadowOpacity = 0.25
        badgeView.layer.shadowRadius = 4
        badgeView.layer.shadowOffset = CGSize(width: 0, height: 2)

        iconImageView.frame = CGRect(x: 6, y: 6, width: 20, height: 20)
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white

        badgeView.addSubview(iconImageView)
        addSubview(badgeView)
    }
}

struct MapLibreAtlasMapView: UIViewRepresentable {
    let cameraRequest: MapCameraRequest
    let places: [Place]
    let downloadedRegions: [AtlasRegion]
    let routes: [TravelRoute]
    let liveRoutePoints: [Coordinate]
    let focusedRouteID: UUID?
    let isLocationAuthorized: Bool

    @Binding var selectedPlaceID: UUID?
    @Binding var visibleRegion: MKCoordinateRegion?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        MapLibreRuntime.configureIfNeeded()
        let mapView = MLNMapView(frame: .zero, styleURL: MapLibreRuntime.openFreeMapLibertyStyleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.backgroundColor = UIColor(Color.atlasCanvas)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = isLocationAuthorized
        mapView.compassViewPosition = .topRight
        mapView.compassViewMargins = CGPoint(x: 16, y: 124)
        mapView.logoViewPosition = .bottomLeft
        mapView.logoViewMargins = CGPoint(x: 16, y: 74)
        mapView.attributionButtonPosition = .bottomRight
        mapView.attributionButtonMargins = CGPoint(x: 16, y: 74)

        mapView.setVisibleCoordinateBounds(
            cameraRequest.coordinateBounds,
            edgePadding: .zero,
            animated: false
        )
        context.coordinator.lastCameraToken = cameraRequest.token
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.parent = self

        if uiView.showsUserLocation != isLocationAuthorized {
            uiView.showsUserLocation = isLocationAuthorized
        }

        if context.coordinator.lastCameraToken != cameraRequest.token {
            context.coordinator.lastCameraToken = cameraRequest.token
            context.coordinator.isProgrammaticMove = true
            uiView.setVisibleCoordinateBounds(
                cameraRequest.coordinateBounds,
                edgePadding: .zero,
                animated: cameraRequest.animated
            )
        }

        context.coordinator.syncAnnotations(on: uiView, places: places, selectedPlaceID: selectedPlaceID)

        if let style = uiView.style {
            context.coordinator.syncOverlays(
                in: style,
                downloadedRegions: downloadedRegions,
                routes: routes,
                liveRoutePoints: liveRoutePoints,
                focusedRouteID: focusedRouteID
            )
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapLibreAtlasMapView
        var lastCameraToken: UUID?
        var isProgrammaticMove = false
        private var isUpdatingSelection = false
        private var lastRenderedPlaceSignature: [Place] = []

        private let regionsSourceID = "atlas-regions-source"
        private let regionsFillLayerID = "atlas-regions-fill"
        private let regionsStrokeLayerID = "atlas-regions-stroke"

        private let savedRoutesSourceID = "atlas-saved-routes-source"
        private let savedRoutesLayerID = "atlas-saved-routes-layer"

        private let focusedRouteSourceID = "atlas-focused-route-source"
        private let focusedRouteLayerID = "atlas-focused-route-layer"

        private let liveRouteSourceID = "atlas-live-route-source"
        private let liveRouteLayerID = "atlas-live-route-layer"

        init(parent: MapLibreAtlasMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            setupOverlayLayersIfNeeded(in: style)
            syncOverlays(
                in: style,
                downloadedRegions: parent.downloadedRegions,
                routes: parent.routes,
                liveRoutePoints: parent.liveRoutePoints,
                focusedRouteID: parent.focusedRouteID
            )
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            isProgrammaticMove = false
            let bounds = mapView.visibleCoordinateBounds
            let latDelta = max(0.002, abs(bounds.ne.latitude - bounds.sw.latitude))
            let lonDelta = max(0.002, abs(bounds.ne.longitude - bounds.sw.longitude))
            let center = CLLocationCoordinate2D(
                latitude: (bounds.ne.latitude + bounds.sw.latitude) / 2.0,
                longitude: (bounds.ne.longitude + bounds.sw.longitude) / 2.0
            )
            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            )
            Task { @MainActor in
                self.parent.visibleRegion = region
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let placeAnnotation = annotation as? AtlasPlaceAnnotation else { return nil }
            let reuseID = "atlas-place-pin"
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? AtlasPlaceAnnotationView {
                reused.apply(annotation: placeAnnotation)
                return reused
            }
            return AtlasPlaceAnnotationView(annotation: placeAnnotation, reuseIdentifier: reuseID)
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard !isUpdatingSelection,
                  let placeAnnotation = annotation as? AtlasPlaceAnnotation else { return }
            Task { @MainActor in
                self.parent.selectedPlaceID = placeAnnotation.placeID
            }
        }

        func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation) {
            guard !isUpdatingSelection,
                  let placeAnnotation = annotation as? AtlasPlaceAnnotation else { return }
            Task { @MainActor in
                if self.parent.selectedPlaceID == placeAnnotation.placeID {
                    self.parent.selectedPlaceID = nil
                }
            }
        }

        func syncAnnotations(on mapView: MLNMapView, places: [Place], selectedPlaceID: UUID?) {
            if lastRenderedPlaceSignature != places {
                lastRenderedPlaceSignature = places
                if let existing = mapView.annotations {
                    let placeAnnotations = existing.compactMap { $0 as? AtlasPlaceAnnotation }
                    if !placeAnnotations.isEmpty {
                        mapView.removeAnnotations(placeAnnotations)
                    }
                }
                let added = places.map(AtlasPlaceAnnotation.init)
                if !added.isEmpty {
                    mapView.addAnnotations(added)
                }
            }

            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            let currentAnnotations = (mapView.annotations ?? []).compactMap { $0 as? AtlasPlaceAnnotation }
            let desired = currentAnnotations.first { $0.placeID == selectedPlaceID }
            let currentlySelected = (mapView.selectedAnnotations.first as? AtlasPlaceAnnotation)?.placeID

            if desired?.placeID != currentlySelected {
                if let desired {
                    mapView.selectAnnotation(desired, animated: true, completionHandler: nil)
                } else {
                    for annotation in mapView.selectedAnnotations {
                        mapView.deselectAnnotation(annotation, animated: true)
                    }
                }
            }
        }

        private func setupOverlayLayersIfNeeded(in style: MLNStyle) {
            if style.source(withIdentifier: regionsSourceID) == nil {
                let source = MLNShapeSource(identifier: regionsSourceID, shape: nil, options: nil)
                style.addSource(source)

                let fillLayer = MLNFillStyleLayer(identifier: regionsFillLayerID, source: source)
                fillLayer.fillColor = NSExpression(forConstantValue: UIColor(Color.atlasMoss).withAlphaComponent(0.08))
                style.addLayer(fillLayer)

                let strokeLayer = MLNLineStyleLayer(identifier: regionsStrokeLayerID, source: source)
                strokeLayer.lineColor = NSExpression(forConstantValue: UIColor(Color.atlasMoss).withAlphaComponent(0.45))
                strokeLayer.lineWidth = NSExpression(forConstantValue: 1.5)
                style.addLayer(strokeLayer)
            }

            if style.source(withIdentifier: savedRoutesSourceID) == nil {
                let source = MLNShapeSource(identifier: savedRoutesSourceID, shape: nil, options: nil)
                style.addSource(source)

                let layer = MLNLineStyleLayer(identifier: savedRoutesLayerID, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor(Color.atlasClay).withAlphaComponent(0.85))
                layer.lineWidth = NSExpression(forConstantValue: 3.5)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }

            if style.source(withIdentifier: focusedRouteSourceID) == nil {
                let source = MLNShapeSource(identifier: focusedRouteSourceID, shape: nil, options: nil)
                style.addSource(source)

                let layer = MLNLineStyleLayer(identifier: focusedRouteLayerID, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor(Color.atlasAmber))
                layer.lineWidth = NSExpression(forConstantValue: 5.0)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }

            if style.source(withIdentifier: liveRouteSourceID) == nil {
                let source = MLNShapeSource(identifier: liveRouteSourceID, shape: nil, options: nil)
                style.addSource(source)

                let layer = MLNLineStyleLayer(identifier: liveRouteLayerID, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor(Color.atlasAmber))
                layer.lineWidth = NSExpression(forConstantValue: 4.5)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
        }

        func syncOverlays(
            in style: MLNStyle,
            downloadedRegions: [AtlasRegion],
            routes: [TravelRoute],
            liveRoutePoints: [Coordinate],
            focusedRouteID: UUID?
        ) {
            setupOverlayLayersIfNeeded(in: style)

            if let regionsSource = style.source(withIdentifier: regionsSourceID) as? MLNShapeSource {
                let regionFeatures: [MLNShape] = downloadedRegions.compactMap { region -> MLNPolygonFeature? in
                    guard let bounds = region.bounds else { return nil }
                    let halfLat = abs(bounds.latitudeDelta) / 2.0
                    let halfLon = abs(bounds.longitudeDelta) / 2.0
                    let south = max(-85.0, bounds.centerLatitude - halfLat)
                    let north = min(85.0, bounds.centerLatitude + halfLat)
                    let west = max(-180.0, bounds.centerLongitude - halfLon)
                    let east = min(180.0, bounds.centerLongitude + halfLon)
                    var ring = [
                        CLLocationCoordinate2D(latitude: south, longitude: west),
                        CLLocationCoordinate2D(latitude: north, longitude: west),
                        CLLocationCoordinate2D(latitude: north, longitude: east),
                        CLLocationCoordinate2D(latitude: south, longitude: east),
                        CLLocationCoordinate2D(latitude: south, longitude: west)
                    ]
                    return MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
                }
                regionsSource.shape = regionFeatures.isEmpty ? nil : MLNShapeCollectionFeature(shapes: regionFeatures)
            }

            if let savedSource = style.source(withIdentifier: savedRoutesSourceID) as? MLNShapeSource {
                let regularRoutes = routes.filter { $0.id != focusedRouteID }
                let features: [MLNShape] = regularRoutes.compactMap { route in
                    var coords = route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    guard coords.count > 1 else { return nil }
                    return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                }
                savedSource.shape = features.isEmpty ? nil : MLNShapeCollectionFeature(shapes: features)
            }

            if let focusedSource = style.source(withIdentifier: focusedRouteSourceID) as? MLNShapeSource {
                if let focusedRouteID,
                   let focused = routes.first(where: { $0.id == focusedRouteID }),
                   focused.points.count > 1 {
                    var coords = focused.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    focusedSource.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                } else {
                    focusedSource.shape = nil
                }
            }

            if let liveSource = style.source(withIdentifier: liveRouteSourceID) as? MLNShapeSource {
                if liveRoutePoints.count > 1 {
                    var coords = liveRoutePoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    liveSource.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                } else {
                    liveSource.shape = nil
                }
            }
        }
    }
}

struct MapLibreMiniMapView: UIViewRepresentable {
    let coordinate: Coordinate
    let category: PlaceCategory
    var zoomLevel: Double = 13.5
    var onTapCoordinate: ((Coordinate) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        MapLibreRuntime.configureIfNeeded()
        let mapView = MLNMapView(frame: .zero, styleURL: MapLibreRuntime.openFreeMapLibertyStyleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.backgroundColor = UIColor(Color.atlasCanvas)
        mapView.delegate = context.coordinator
        mapView.attributionButtonMargins = CGPoint(x: 6, y: 6)
        mapView.logoViewMargins = CGPoint(x: 6, y: 6)

        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        mapView.setCenter(center, zoomLevel: zoomLevel, animated: false)

        if onTapCoordinate != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            mapView.addGestureRecognizer(tap)
            context.coordinator.mapView = mapView
        }

        context.coordinator.syncPin(on: mapView, coordinate: center, category: category)
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        let target = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if context.coordinator.lastCenteredCoordinate?.latitude != target.latitude
            || context.coordinator.lastCenteredCoordinate?.longitude != target.longitude {
            uiView.setCenter(target, zoomLevel: zoomLevel, animated: true)
        }
        context.coordinator.syncPin(on: uiView, coordinate: target, category: category)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapLibreMiniMapView
        weak var mapView: MLNMapView?
        var lastCenteredCoordinate: CLLocationCoordinate2D?
        private var lastCategory: PlaceCategory?

        init(parent: MapLibreMiniMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let mapView, let onTap = parent.onTapCoordinate else { return }
            let point = recognizer.location(in: mapView)
            let tapped = mapView.convert(point, toCoordinateFrom: mapView)
            let coord = Coordinate(latitude: tapped.latitude, longitude: tapped.longitude)
            Task { @MainActor in
                onTap(coord)
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let pin = annotation as? SinglePinAnnotation else { return nil }
            let reuseID = "mini-pin"
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? SinglePinAnnotationView {
                reused.apply(annotation: pin)
                return reused
            }
            return SinglePinAnnotationView(annotation: pin, reuseIdentifier: reuseID)
        }

        func syncPin(on mapView: MLNMapView, coordinate: CLLocationCoordinate2D, category: PlaceCategory) {
            guard lastCenteredCoordinate?.latitude != coordinate.latitude
                || lastCenteredCoordinate?.longitude != coordinate.longitude
                || lastCategory != category else {
                return
            }
            lastCenteredCoordinate = coordinate
            lastCategory = category
            if let existing = mapView.annotations {
                mapView.removeAnnotations(existing)
            }
            let pin = SinglePinAnnotation(coordinate: coordinate, category: category)
            mapView.addAnnotation(pin)
        }
    }
}
