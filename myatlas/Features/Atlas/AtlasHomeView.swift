import MapKit
import SwiftUI

struct AtlasHomeView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @EnvironmentObject private var locationService: LocationService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selectedTab: AtlasTab
    @Binding var focusedRoute: RouteFocusRequest?
    @Binding var focusedRegion: RegionFocusRequest?

    enum AtlasMapStyleOption: String, CaseIterable, Identifiable {
        case standard = "Map"
        case hybrid = "Satellite"

        var id: String { rawValue }
    }

    @State private var mapStyleOption: AtlasMapStyleOption = .standard
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.0256, longitude: 28.9741),
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.16)
        )
    )
    @State private var cameraRequest = MapCameraRequest(
        region: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.0256, longitude: 28.9741),
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.16)
        ),
        animated: false
    )
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var hasInitializedCamera = false
    @State private var selectedPlaceID: UUID?
    @State private var activeCategoryFilter: PlaceCategory?
    @State private var isShowingRegionSheet = false
    @State private var isShowingPlaceSheet = false
    @State private var isShowingFinishRouteSheet = false
    @State private var isShowingDiscardRouteConfirm = false
    @State private var placeCoordinateForSheet: Coordinate?
    @State private var isDeckExpanded = false
    @State private var navigatedPlaceID: UUID?
    @State private var routeNoticeMessage: String?

    private var filteredPlaces: [Place] {
        atlas.recentPlaces.filter { place in
            guard let activeCategoryFilter else { return true }
            return place.category == activeCategoryFilter
        }
    }

    private var selectedPlace: Place? {
        guard let selectedPlaceID else { return nil }
        return atlas.places.first { $0.id == selectedPlaceID }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                interactiveMap
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 10) {
                    topFloatingBar
                    categoryFilterStrip
                    Spacer()

                    if locationService.isRecordingRoute {
                        routeRecordingHUD
                    } else if let selectedPlace {
                        selectedPlaceCard(selectedPlace)
                    }

                    bottomDeck
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $navigatedPlaceID) { placeID in
                PlaceDetailView(placeID: placeID)
            }
            .sheet(isPresented: $isShowingRegionSheet) {
                RegionDownloadSheet(currentViewport: visibleRegion) { bounds in
                    moveCamera(
                        to: MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                            span: MKCoordinateSpan(latitudeDelta: bounds.latitudeDelta, longitudeDelta: bounds.longitudeDelta)
                        )
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isShowingPlaceSheet) {
                AddPlaceSheet(initialCoordinate: placeCoordinateForSheet)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingFinishRouteSheet) {
                FinishRouteSheet(
                    defaultTitle: locationService.activeRouteTitle,
                    distanceMeters: locationService.recordedDistanceMeters,
                    durationSeconds: locationService.elapsedRecordingSeconds,
                    pointCount: locationService.recordedPoints.count
                ) { customTitle, note in
                    if let savedRoute = locationService.stopRouteRecording(customTitle: customTitle, note: note) {
                        atlas.add(route: savedRoute)
                        focusedRoute = RouteFocusRequest(routeID: savedRoute.id)
                    } else {
                        routeNoticeMessage = "No GPS points were captured yet, so the walk could not be saved."
                    }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog("Discard this walk?", isPresented: $isShowingDiscardRouteConfirm, titleVisibility: .visible) {
                Button("Discard Walk", role: .destructive) {
                    locationService.discardRouteRecording()
                }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("All GPS points recorded during this session will be deleted.")
            }
            .alert(
                "Walk Recording",
                isPresented: Binding(
                    get: { routeNoticeMessage != nil },
                    set: { if !$0 { routeNoticeMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { routeNoticeMessage = nil }
            } message: {
                Text(routeNoticeMessage ?? "")
            }
            .onChange(of: selectedPlaceID) { _, newValue in
                if newValue != nil && isDeckExpanded {
                    isDeckExpanded = false
                }
            }
            .onChange(of: focusedRoute) { _, request in
                if let routeID = request?.routeID,
                   let route = atlas.routes.first(where: { $0.id == routeID }) {
                    focusMap(on: route)
                }
            }
            .onChange(of: focusedRegion) { _, request in
                if let bounds = request?.bounds {
                    selectedPlaceID = nil
                    isDeckExpanded = false
                    moveCamera(
                        to: MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                            span: MKCoordinateSpan(latitudeDelta: bounds.latitudeDelta, longitudeDelta: bounds.longitudeDelta)
                        )
                    )
                }
            }
            .onAppear {
                if let bounds = focusedRegion?.bounds {
                    moveCamera(
                        to: MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                            span: MKCoordinateSpan(latitudeDelta: bounds.latitudeDelta, longitudeDelta: bounds.longitudeDelta)
                        )
                    )
                } else if let routeID = focusedRoute?.routeID,
                   let route = atlas.routes.first(where: { $0.id == routeID }) {
                    focusMap(on: route)
                } else if !hasInitializedCamera {
                    hasInitializedCamera = true
                    if let firstPlace = atlas.recentPlaces.first, selectedPlaceID == nil {
                        moveCamera(
                            to: MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: firstPlace.latitude, longitude: firstPlace.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.10)
                            ),
                            animated: false
                        )
                    }
                }
            }
        }
    }

    // MARK: - Interactive Map

    @ViewBuilder
    private var interactiveMap: some View {
        if mapStyleOption == .standard {
            MapLibreAtlasMapView(
                cameraRequest: cameraRequest,
                places: filteredPlaces,
                downloadedRegions: atlas.downloadedRegions,
                routes: atlas.sortedRoutes,
                liveRoutePoints: locationService.recordedPoints,
                focusedRouteID: focusedRoute?.routeID,
                isLocationAuthorized: locationService.isAuthorized,
                selectedPlaceID: $selectedPlaceID,
                visibleRegion: $visibleRegion
            )
        } else {
            Map(position: $cameraPosition, selection: $selectedPlaceID) {
                UserAnnotation()

                ForEach(atlas.downloadedRegions) { region in
                    if let bounds = region.bounds {
                        MapCircle(
                            center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                            radius: max(6_000, bounds.latitudeDelta * 55_000)
                        )
                        .foregroundStyle(Color.atlasMoss.opacity(0.08))
                        .stroke(Color.atlasMoss.opacity(0.35), lineWidth: 1.5)
                    }
                }

                ForEach(atlas.sortedRoutes) { route in
                    let coords = route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    if coords.count > 1 {
                        let isFocused = focusedRoute?.routeID == route.id
                        MapPolyline(coordinates: coords)
                            .stroke(
                                isFocused ? Color.atlasAmber : Color.atlasClay.opacity(0.85),
                                style: StrokeStyle(lineWidth: isFocused ? 5 : 3.5, lineCap: .round, lineJoin: .round)
                            )
                    }
                }

                if locationService.recordedPoints.count > 1 {
                    let liveCoords = locationService.recordedPoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    MapPolyline(coordinates: liveCoords)
                        .stroke(Color.atlasAmber, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                }

                ForEach(filteredPlaces) { place in
                    Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) {
                        PlaceMapPin(place: place, isSelected: selectedPlaceID == place.id, reduceMotion: reduceMotion)
                    }
                    .tag(place.id)
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
        }
    }

    // MARK: - Floating Chrome

    private var topFloatingBar: some View {
        AdaptiveStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("myatlas")
                    .font(.atlasDisplay)
                    .foregroundStyle(Color.atlasInk)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.symbolCompact)
                        .foregroundStyle(Color.atlasMoss)
                    Text("Offline atlas")
                        .font(.badge)
                        .foregroundStyle(Color.atlasInk)
                    Text("· \(atlas.downloadedRegions.count) region\(atlas.downloadedRegions.count == 1 ? "" : "s")")
                        .font(.badge)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .floatingChrome(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("myatlas, Offline atlas, \(atlas.downloadedRegions.count) \(atlas.downloadedRegions.count == 1 ? "region" : "regions") ready")

            Spacer()

            HStack(spacing: 8) {
                Button {
                    if mapStyleOption == .standard {
                        if let visibleRegion {
                            cameraPosition = .region(visibleRegion)
                        }
                        mapStyleOption = .hybrid
                    } else {
                        if let visibleRegion {
                            cameraRequest = MapCameraRequest(region: visibleRegion, animated: false)
                        }
                        mapStyleOption = .standard
                    }
                } label: {
                    Image(systemName: mapStyleOption == .standard ? "globe.europe.africa" : "map")
                        .font(.symbol)
                        .foregroundStyle(Color.atlasInk)
                        .frame(width: 44, height: 44)
                        .floatingChrome(in: Circle())
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityLabel(mapStyleOption == .standard ? "Switch to Satellite Map" : "Switch to Standard Map")

                Button {
                    Task {
                        if let coord = await locationService.requestCurrentCoordinate() {
                            moveCamera(
                                to: MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude),
                                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                                )
                            )
                        }
                    }
                } label: {
                    Image(systemName: locationService.isRequestingLocation ? "location.fill" : "location")
                        .font(.symbol)
                        .foregroundStyle(Color.atlasInk)
                        .frame(width: 44, height: 44)
                        .floatingChrome(in: Circle())
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityLabel("Center Map on My Location")

                Button {
                    isShowingRegionSheet = true
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.symbolLarge)
                        .foregroundStyle(Color.atlasClay)
                        .frame(width: 44, height: 44)
                        .floatingChrome(in: Circle())
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityLabel("Download Map Region")
            }
        }
    }

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All (\(atlas.places.count))", systemImage: "globe", isSelected: activeCategoryFilter == nil) {
                    activeCategoryFilter = nil
                }
                ForEach(PlaceCategory.allCases) { category in
                    filterChip(
                        title: category.displayName,
                        systemImage: category.systemImage,
                        isSelected: activeCategoryFilter == category
                    ) {
                        activeCategoryFilter = (activeCategoryFilter == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterChip(title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.badge)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.atlasSelectedForeground : Color.atlasInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule().fill(Color.atlasSelectedBackground)
                    } else {
                        Capsule().fill(Color.atlasSurface.opacity(0.92))
                    }
                }
                .overlay(Capsule().strokeBorder(Color.atlasHairline, lineWidth: isSelected ? 0 : 1))
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Route Recording HUD

    private var routeRecordingHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveStack {
                Label(
                    locationService.isRoutePaused ? "Walk Paused" : "Recording Walk",
                    systemImage: locationService.isRoutePaused ? "pause.circle.fill" : "figure.walk"
                )
                .font(.rowTitle)
                .foregroundStyle(Color.atlasClay)
                Spacer()
                Text(VoiceRecorderService.formattedDuration(locationService.elapsedRecordingSeconds))
                    .font(.coordinate)
                    .foregroundStyle(Color.atlasInk)
            }

            AdaptiveStack(spacing: 12) {
                Label(DistanceFormatting.string(forMeters: locationService.recordedDistanceMeters), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.rowSubtitle)
                    .monospacedDigit()
                Text("· \(locationService.recordedPoints.count) GPS pts")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            AdaptiveStack(spacing: 8) {
                Button {
                    if locationService.isRoutePaused {
                        locationService.resumeRouteRecording()
                    } else {
                        locationService.pauseRouteRecording()
                    }
                } label: {
                    Label(locationService.isRoutePaused ? "Resume" : "Pause", systemImage: locationService.isRoutePaused ? "play.fill" : "pause.fill")
                        .font(.badge)
                        .lineLimit(1)
                        .foregroundStyle(Color.atlasInk)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color.atlasFieldFill, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    placeCoordinateForSheet = locationService.currentCoordinate
                    isShowingPlaceSheet = true
                } label: {
                    Label("Pin Here", systemImage: "mappin.and.ellipse")
                        .font(.badge)
                        .lineLimit(1)
                        .foregroundStyle(Color.atlasInk)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color.atlasFieldFill, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    isShowingDiscardRouteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.symbolCompact)
                        .frame(minWidth: 36, minHeight: 36)
                        .background(Color.atlasFieldFill, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard Walk")

                Spacer()

                Button {
                    isShowingFinishRouteSheet = true
                } label: {
                    Text("Finish")
                        .font(.badge.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Color.atlasMossButton, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 18)
    }

    // MARK: - Selected Pin Preview

    private func selectedPlaceCard(_ place: Place) -> some View {
        let firstPhoto = atlas.attachments(for: place.id).first { $0.kind == .photo }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let firstPhoto {
                    AttachmentThumbnailView(attachment: firstPhoto, cornerRadius: 10)
                        .frame(width: 60, height: 60)
                }
                VStack(alignment: .leading, spacing: 4) {
                    CategoryBadge(category: place.category)
                    Text(place.name)
                        .font(.rowTitle)
                        .foregroundStyle(Color.atlasInk)
                    Text(place.subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    selectedPlaceID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.symbolLarge)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Place Preview")
            }

            if let note = place.note, !note.isEmpty {
                Text(note)
                    .font(.rowSubtitle)
                    .foregroundStyle(Color.atlasMoss)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }

            AdaptiveStack {
                if place.attachmentCount > 0 {
                    Label("\(place.attachmentCount) attachment\(place.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip")
                        .font(.note)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    navigatedPlaceID = place.id
                } label: {
                    Label("Open Details", systemImage: "arrow.right")
                        .font(.badge)
                        .lineLimit(1)
                        .foregroundStyle(Color.atlasSelectedForeground)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Color.atlasSelectedBackground, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 18)
    }

    // MARK: - Bottom Deck

    private var bottomActionRow: some View {
        AdaptiveStack(spacing: 8) {
            Button {
                if reduceMotion {
                    isDeckExpanded.toggle()
                } else {
                    withAnimation(.smooth(duration: 0.22)) {
                        isDeckExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isDeckExpanded ? "chevron.down" : "chevron.up")
                        .font(.symbolCompact)
                    Text(isDeckExpanded ? "Hide" : "Explore")
                        .font(.badge)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.atlasInk)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .floatingChrome(in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDeckExpanded ? "Hide Places and Regions Panel" : "Show Places and Regions Panel")

            Spacer(minLength: 4)

            if !locationService.isRecordingRoute {
                Button {
                    _ = locationService.startRouteRecording()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "figure.walk")
                            .font(.symbolCompact)
                        Text("Walk")
                            .font(.badge)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(Color.atlasMoss)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .floatingChrome(in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record Walk")
            }

            Button {
                placeCoordinateForSheet = visibleRegion.map {
                    Coordinate(latitude: $0.center.latitude, longitude: $0.center.longitude)
                } ?? locationService.currentCoordinate
                isShowingPlaceSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.symbolCompact)
                    Text("Save Place")
                        .font(.badge.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(minHeight: 38)
                .background(Color.atlasPrimaryButton, in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("save-place-button")
        }
    }

    @ViewBuilder
    private var bottomDeck: some View {
        if isDeckExpanded {
            VStack(alignment: .leading, spacing: 12) {
                bottomActionRow

                Divider()

                SectionHeading(title: "Downloaded Regions", actionTitle: "Manage") {
                    selectedTab = .offline
                }

                if atlas.regions.isEmpty {
                    let featuredIstanbul = AtlasCatalog.regions.filter {
                        $0.slug == "tr-istanbul-core" || $0.slug == "tr-istanbul-metro"
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(featuredIstanbul) { region in
                                CompactRegionPill(region: region) {
                                    if let bounds = region.bounds {
                                        moveCamera(
                                            to: MKCoordinateRegion(
                                                center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                                                span: MKCoordinateSpan(latitudeDelta: bounds.latitudeDelta, longitudeDelta: bounds.longitudeDelta)
                                            )
                                        )
                                    }
                                }
                            }
                            Button {
                                isShowingRegionSheet = true
                            } label: {
                                Label("All \(AtlasCatalog.regions.count)", systemImage: "arrow.down.circle")
                                    .font(.badge)
                                    .foregroundStyle(Color.atlasClay)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .background(Color.atlasFieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(atlas.regions) { region in
                                CompactRegionPill(region: region) {
                                    if let bounds = region.bounds {
                                        moveCamera(
                                            to: MKCoordinateRegion(
                                                center: CLLocationCoordinate2D(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude),
                                                span: MKCoordinateSpan(latitudeDelta: bounds.latitudeDelta, longitudeDelta: bounds.longitudeDelta)
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                SectionHeading(title: "Recent Places", actionTitle: "See All") {
                    selectedTab = .history
                }

                if filteredPlaces.isEmpty {
                    HStack {
                        Text("No saved places match this filter yet.")
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if activeCategoryFilter != nil {
                            Button("Clear Filter") {
                                activeCategoryFilter = nil
                            }
                            .font(.badge)
                            .frame(minHeight: 44)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredPlaces.prefix(2)) { place in
                            let firstPhoto = atlas.attachments(for: place.id).first { $0.kind == .photo }
                            Button {
                                navigatedPlaceID = place.id
                            } label: {
                                CompactPlaceRow(place: place, previewPhoto: firstPhoto)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardSurface(cornerRadius: 20)
        } else {
            bottomActionRow
        }
    }

    // MARK: - Camera Helpers

    private func moveCamera(to region: MKCoordinateRegion, animated: Bool = true) {
        let shouldAnimate = animated && !reduceMotion
        cameraRequest = MapCameraRequest(region: region, animated: shouldAnimate)
        if !shouldAnimate {
            cameraPosition = .region(region)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                cameraPosition = .region(region)
            }
        }
    }

    private func focusMap(on route: TravelRoute) {
        guard !route.points.isEmpty else { return }
        let lats = route.points.map(\.latitude)
        let lons = route.points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.015, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.015, (maxLon - minLon) * 1.4)
        )
        moveCamera(to: MKCoordinateRegion(center: center, span: span))
    }
}

private struct PlaceMapPin: View {
    let place: Place
    let isSelected: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(place.category.pinFillColor)
                .frame(width: isSelected ? 40 : 32, height: isSelected ? 40 : 32)
                .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 2))
                .shadow(radius: isSelected ? 6 : 2)
            Image(systemName: place.category.systemImage)
                .font(isSelected ? .symbol : .symbolCompact)
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .contentShape(.rect)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.name), \(place.category.displayName)\(place.isFavorite ? ", Favorite" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows place preview card")
    }
}

private struct CompactRegionPill: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    let region: AtlasRegion
    let onTap: () -> Void

    var body: some View {
        AdaptiveStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(region.name)
                            .font(.badge)
                            .foregroundStyle(Color.atlasInk)
                        Text(stateLabel)
                            .font(.note)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            if case .downloading(let progress) = region.downloadState {
                ProgressView(value: progress)
                    .frame(width: 34)
                Button {
                    atlas.cancelDownload(for: region)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Cancel \(region.name) download")
            } else if case .available = region.downloadState {
                Button {
                    atlas.download(region: region)
                } label: {
                    Text("Get")
                        .font(.badge)
                        .foregroundStyle(Color.atlasSelectedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.atlasSelectedBackground, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if case .failed = region.downloadState {
                Button {
                    atlas.download(region: region)
                } label: {
                    Text("Retry")
                        .font(.badge)
                        .foregroundStyle(Color.atlasClay)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.atlasClay.opacity(0.14), in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.atlasFieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var iconName: String {
        switch region.downloadState {
        case .available: "icloud.and.arrow.down"
        case .downloading: "arrow.down.circle"
        case .downloaded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch region.downloadState {
        case .available: Color.atlasClay
        case .downloading: Color.atlasSlate
        case .downloaded: Color.atlasMoss
        case .failed: Color.atlasClay
        }
    }

    private var stateLabel: String {
        switch region.downloadState {
        case .available: "~\(region.mapPackageSize.formatted(.byteCount(style: .file)))"
        case .downloading(let progress): "\(Int(progress * 100))%"
        case .downloaded:
            atlas.downloadedBytes(for: region).map { "Offline · \($0.formatted(.byteCount(style: .file)))" } ?? "Ready offline"
        case .failed: "Retry download"
        }
    }
}

private struct CompactPlaceRow: View {
    let place: Place
    let previewPhoto: PlaceAttachment?

    var body: some View {
        AdaptiveStack(spacing: 12) {
            if let previewPhoto {
                AttachmentThumbnailView(attachment: previewPhoto, cornerRadius: 10)
                    .frame(width: 40, height: 40)
            } else {
                IconTile(systemImage: place.category.systemImage, color: place.category.pinFillColor, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.rowTitle)
                        .foregroundStyle(Color.atlasInk)
                    if place.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.symbolCompact)
                            .foregroundStyle(Color.atlasAmber)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(place.subtitle)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(place.visitedAt, format: .dateTime.month(.abbreviated).day())
                .font(.rowDetail)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.symbolCompact)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(10)
        .frame(minHeight: 44)
        .background(Color.atlasFieldFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct FinishRouteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let pointCount: Int
    let onSave: (String, String) -> Void

    @State private var title: String
    @State private var note = ""

    init(
        defaultTitle: String,
        distanceMeters: Double,
        durationSeconds: TimeInterval,
        pointCount: Int,
        onSave: @escaping (String, String) -> Void
    ) {
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.pointCount = pointCount
        self.onSave = onSave
        _title = State(initialValue: defaultTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Walk Summary") {
                    LabeledContent("Distance", value: DistanceFormatting.string(forMeters: distanceMeters))
                    LabeledContent("Duration", value: VoiceRecorderService.formattedDuration(durationSeconds))
                    LabeledContent("GPS Points", value: "\(pointCount)")
                }
                Section("Details") {
                    TextField("Walk title", text: $title)
                    TextField("Notes about this walk (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Resume") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, note)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct RegionDownloadSheet: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Environment(\.dismiss) private var dismiss

    let currentViewport: MKCoordinateRegion?
    var onSelectRegionBounds: ((RegionBounds) -> Void)? = nil

    @State private var searchText = ""
    @State private var selectedGroup = "All"
    @State private var customName = ""

    private let catalogGroups = ["All", "Istanbul", "Turkey", "Europe", "Asia & Middle East", "Americas & Oceania"]

    private var catalogItems: [AtlasRegion] {
        let existingBySlug = Dictionary(atlas.regions.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = AtlasCatalog.regions.map { existingBySlug[$0.slug] ?? $0 }
        let groupFiltered = selectedGroup == "All"
            ? merged
            : merged.filter { $0.catalogGroup == selectedGroup }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groupFiltered }
        return groupFiltered.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.countryCode.localizedCaseInsensitiveContains(trimmed)
                || $0.catalogGroup.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var customViewportEstimateText: String? {
        guard let currentViewport else { return nil }
        let bounds = RegionBounds(
            centerLatitude: currentViewport.center.latitude,
            centerLongitude: currentViewport.center.longitude,
            latitudeDelta: currentViewport.span.latitudeDelta,
            longitudeDelta: currentViewport.span.longitudeDelta
        )
        let bytes = bounds.estimatedOfflineBytes()
        return "Est. \(bytes.formatted(.byteCount(style: .file))) vector tiles (max zoom z\(bounds.safeOfflineMaxZoom()))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(catalogGroups, id: \.self) { group in
                                Button {
                                    selectedGroup = group
                                } label: {
                                    Text(group)
                                        .font(.badge)
                                        .foregroundStyle(selectedGroup == group ? Color.atlasSelectedForeground : Color.atlasInk)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            selectedGroup == group ? Color.atlasSelectedBackground : Color.atlasFieldFill,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                Section("Catalog Regions (\(catalogItems.count))") {
                    ForEach(catalogItems) { region in
                        AdaptiveStack(spacing: 12) {
                            Button {
                                if let bounds = region.bounds {
                                    onSelectRegionBounds?(bounds)
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(region.name)
                                        .font(.rowTitle)
                                        .foregroundStyle(Color.atlasInk)
                                    Text(regionDetailSubtitle(region))
                                        .font(.rowDetail)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            regionAction(for: region)
                        }
                    }
                }

                Section {
                    TextField("Custom area name (e.g. Karaköy – Bebek)", text: $customName)
                    if let customViewportEstimateText {
                        Text(customViewportEstimateText)
                            .font(.note)
                            .foregroundStyle(.secondary)
                    }
                    Button("Download Current Map Area") {
                        let bounds = currentViewport.map {
                            RegionBounds(
                                centerLatitude: $0.center.latitude,
                                centerLongitude: $0.center.longitude,
                                latitudeDelta: $0.span.latitudeDelta,
                                longitudeDelta: $0.span.longitudeDelta
                            )
                        }
                        atlas.addCustomRegion(name: customName, bounds: bounds)
                        customName = ""
                        dismiss()
                    }
                    .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Custom Region")
                } footer: {
                    Text(atlas.mapConfiguration.attributionText)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $searchText, prompt: "Filter Istanbul, Turkey, or world cities")
            .navigationTitle("Offline Maps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func regionDetailSubtitle(_ region: AtlasRegion) -> String {
        if case .downloaded = region.downloadState, let actualBytes = atlas.downloadedBytes(for: region) {
            return "\(region.catalogGroup) · \(actualBytes.formatted(.byteCount(style: .file))) on disk"
        }
        return "\(region.catalogGroup) · ~\(region.mapPackageSize.formatted(.byteCount(style: .file)))"
    }

    @ViewBuilder
    private func regionAction(for region: AtlasRegion) -> some View {
        switch region.downloadState {
        case .available:
            Button("Download") {
                atlas.download(region: region)
            }
            .buttonStyle(.borderless)
            .font(.badge)
            .foregroundStyle(Color.atlasSelectedForeground)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.atlasSelectedBackground, in: Capsule())
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 56)
                Button("Cancel") {
                    atlas.cancelDownload(for: region)
                }
                .buttonStyle(.borderless)
                .font(.badge)
                .frame(minHeight: 44)
            }
        case .downloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.badge)
                .foregroundStyle(Color.atlasMoss)
        case .failed:
            Button("Retry") {
                atlas.download(region: region)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }
}
