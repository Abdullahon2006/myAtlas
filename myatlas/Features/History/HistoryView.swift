import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Binding var selectedTab: AtlasTab
    @Binding var focusedRoute: RouteFocusRequest?

    enum HistoryMode: String, CaseIterable, Identifiable {
        case places = "Places"
        case routes = "Routes"

        var id: String { rawValue }
    }

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    @State private var mode: HistoryMode = .places
    @State private var searchText = ""
    @State private var selectedFilter: PlaceMediaFilter = .all
    @State private var selectedCategory: PlaceCategory?
    @State private var routeToDelete: TravelRoute?
    @State private var editingRoute: TravelRoute?
    @State private var exportedGPXShare: ExportSharePayload?

    private var filteredPlaces: [Place] {
        atlas.filteredPlaces(query: searchText, category: selectedCategory, mediaFilter: selectedFilter)
    }

    private var groupedByMonth: [(title: String, places: [Place])] {
        let groups = Dictionary(grouping: filteredPlaces) { Self.monthYearFormatter.string(from: $0.visitedAt) }
        return groups.map { key, value in
            (title: key, places: value.sorted { $0.visitedAt > $1.visitedAt })
        }
        .sorted { ($0.places.first?.visitedAt ?? .distantPast) > ($1.places.first?.visitedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("A quiet record of where life took you.")
                        .font(.rowSubtitle)
                        .foregroundStyle(Color.atlasMoss)

                    statsStrip

                    Picker("History View", selection: $mode) {
                        Text("Places (\(atlas.places.count))").tag(HistoryMode.places)
                        Text("Routes (\(atlas.routes.count))").tag(HistoryMode.routes)
                    }
                    .pickerStyle(.segmented)

                    if mode == .places {
                        placesContent
                    } else {
                        routesContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.atlasCanvas.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search places, notes, or entries")
            .sheet(item: $editingRoute) { route in
                EditRouteSheet(route: route)
            }
            .sheet(item: $exportedGPXShare) { payload in
                ShareActivitySheet(items: [payload.url])
            }
            .confirmationDialog(
                "Delete \"\(routeToDelete?.title ?? "Route")\"?",
                isPresented: Binding(
                    get: { routeToDelete != nil },
                    set: { if !$0 { routeToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Route", role: .destructive) {
                    if let routeToDelete {
                        atlas.delete(route: routeToDelete)
                    }
                    routeToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    routeToDelete = nil
                }
            } message: {
                Text("This permanently removes the recorded GPS track from your device.")
            }
        }
    }

    // MARK: - Sections

    private var statsStrip: some View {
        let stats = atlas.summaryStats
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            StatTile(
                title: "Places",
                value: "\(stats.totalPlaces)",
                systemImage: "mappin.and.ellipse",
                tint: Color.atlasClay
            )
            StatTile(
                title: "Favorites",
                value: "\(stats.favoritePlaces)",
                systemImage: "star.fill",
                tint: Color.atlasAmber
            )
            StatTile(
                title: "Walked",
                value: DistanceFormatting.string(forMeters: stats.totalRouteDistanceMeters),
                systemImage: "figure.walk",
                tint: Color.atlasMoss
            )
        }
    }

    @ViewBuilder
    private var placesContent: some View {
        let attachmentsByPlace = Dictionary(grouping: atlas.attachments, by: \.placeID)
        let entryCountByPlace = Dictionary(grouping: atlas.entries, by: \.placeID).mapValues(\.count)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PlaceMediaFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.label)
                            .font(.badge)
                            .lineLimit(1)
                            .foregroundStyle(selectedFilter == filter ? Color.atlasSelectedForeground : Color.atlasInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selectedFilter == filter ? Color.atlasSelectedBackground : Color.atlasSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.atlasHairline, lineWidth: selectedFilter == filter ? 0 : 1))
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedFilter == filter ? [.isSelected] : [])
                }

                Menu {
                    Button("All Categories") { selectedCategory = nil }
                    Divider()
                    ForEach(PlaceCategory.allCases) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Label(category.displayName, systemImage: category.systemImage)
                        }
                    }
                } label: {
                    Label(selectedCategory?.displayName ?? "Category", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.badge)
                        .foregroundStyle(selectedCategory == nil ? Color.atlasInk : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(selectedCategory == nil ? Color.atlasSurface : Color.atlasMossButton, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.atlasHairline, lineWidth: selectedCategory == nil ? 1 : 0))
                }
            }
        }

        if groupedByMonth.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No places recorded" : "No matching places",
                systemImage: "figure.walk.motion",
                description: Text(
                    searchText.isEmpty
                        ? "Places you save will gather here in chronological order."
                        : "Try clearing a filter or searching for another city or note."
                )
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            ForEach(groupedByMonth, id: \.title) { group in
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: group.title)

                    ForEach(Array(group.places.enumerated()), id: \.element.id) { index, place in
                        NavigationLink {
                            PlaceDetailView(placeID: place.id)
                        } label: {
                            PlaceHistoryRow(
                                place: place,
                                attachments: attachmentsByPlace[place.id] ?? [],
                                entryCount: entryCountByPlace[place.id] ?? 0,
                                isLastInGroup: index == group.places.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var routesContent: some View {
        let routes = atlas.sortedRoutes.filter { route in
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return route.title.localizedCaseInsensitiveContains(trimmed)
                || (route.note?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }

        if routes.isEmpty {
            ContentUnavailableView(
                "No walks recorded yet",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                description: Text("Start a foreground walk from the Atlas tab to log your path offline.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            ForEach(routes) { route in
                VStack(alignment: .leading, spacing: 10) {
                    AdaptiveStack(spacing: 10) {
                        IconTile(systemImage: "figure.walk", color: Color.atlasMossButton, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.title)
                                .font(.rowTitle)
                                .foregroundStyle(Color.atlasInk)
                            Text(route.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                                .font(.rowDetail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button {
                                focusedRoute = RouteFocusRequest(routeID: route.id)
                                selectedTab = .atlas
                            } label: {
                                Label("Show on Atlas Map", systemImage: "map")
                            }
                            Button {
                                editingRoute = route
                            } label: {
                                Label("Edit Title & Note", systemImage: "pencil")
                            }
                            Button {
                                exportGPX(route)
                            } label: {
                                Label("Export GPX", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button(role: .destructive) {
                                routeToDelete = route
                            } label: {
                                Label("Delete Route", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.symbol)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Actions for \(route.title)")
                    }

                    AdaptiveStack(spacing: 12) {
                        Label(DistanceFormatting.string(forMeters: route.totalDistanceMeters), systemImage: "ruler")
                            .font(.rowSubtitle)
                            .monospacedDigit()
                        Label(VoiceRecorderService.formattedDuration(route.duration), systemImage: "clock")
                            .font(.rowSubtitle)
                            .monospacedDigit()
                        Label("\(route.points.count) pts", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.rowSubtitle)
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.atlasMoss)

                    if let note = route.note, !note.isEmpty {
                        Text(note)
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        focusedRoute = RouteFocusRequest(routeID: route.id)
                        selectedTab = .atlas
                    } label: {
                        Label("View on Atlas", systemImage: "map")
                            .font(.badge)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .cardSurface(cornerRadius: 16)
                .contextMenu {
                    Button {
                        focusedRoute = RouteFocusRequest(routeID: route.id)
                        selectedTab = .atlas
                    } label: {
                        Label("Show on Atlas Map", systemImage: "map")
                    }
                    Button {
                        editingRoute = route
                    } label: {
                        Label("Edit Title & Note", systemImage: "pencil")
                    }
                    Button {
                        exportGPX(route)
                    } label: {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        routeToDelete = route
                    } label: {
                        Label("Delete Route", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: "Show on Atlas Map") {
                    focusedRoute = RouteFocusRequest(routeID: route.id)
                    selectedTab = .atlas
                }
                .accessibilityAction(named: "Edit Route") {
                    editingRoute = route
                }
                .accessibilityAction(named: "Delete Route") {
                    routeToDelete = route
                }
            }
        }
    }

    private func exportGPX(_ route: TravelRoute) {
        let filename = "\(AtlasExporter.sanitizedExportFilename(route.title, fallback: "walk-route")).gpx"
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                let gpx = AtlasExporter.exportGPX(routes: [route])
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? Data(gpx.utf8).write(to: tempURL, options: .atomic)
                return tempURL
            }.value
            exportedGPXShare = ExportSharePayload(url: url)
        }
    }
}

private struct EditRouteSheet: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Environment(\.dismiss) private var dismiss

    let route: TravelRoute
    @State private var title: String
    @State private var note: String

    init(route: TravelRoute) {
        self.route = route
        _title = State(initialValue: route.title)
        _note = State(initialValue: route.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Walk Details") {
                    TextField("Title", text: $title)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = route
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.title = cleanTitle.isEmpty ? route.title : cleanTitle
                        updated.note = cleanNote.isEmpty ? nil : cleanNote
                        atlas.update(route: updated)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct PlaceHistoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let place: Place
    let attachments: [PlaceAttachment]
    let entryCount: Int
    let isLastInGroup: Bool

    private var firstPhoto: PlaceAttachment? {
        attachments.first { $0.kind == .photo }
    }

    private var photoCount: Int {
        attachments.filter { $0.kind == .photo }.count
    }

    private var voiceCount: Int {
        attachments.filter { $0.kind == .voice }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(place.category.tintColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
                if !isLastInGroup {
                    Rectangle()
                        .fill(Color.atlasMist)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                AdaptiveStack(spacing: 8) {
                    CategoryBadge(category: place.category)
                    if place.isFavorite {
                        Label("Favorite", systemImage: "star.fill")
                            .font(.badge)
                            .foregroundStyle(Color.atlasAmber)
                    }
                    if let rating = place.rating, rating > 0 {
                        Label("\(rating)/5", systemImage: "star")
                            .font(.badge)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(place.visitedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                }

                AdaptiveStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name)
                            .font(.rowTitle)
                            .foregroundStyle(Color.atlasInk)
                        Text(place.subtitle)
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let firstPhoto {
                        AttachmentThumbnailView(attachment: firstPhoto, cornerRadius: 10)
                            .frame(width: 56, height: 56)
                    }
                }

                if let note = place.note, !note.isEmpty {
                    Text(note)
                        .font(.rowSubtitle)
                        .foregroundStyle(Color.atlasMoss)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                }

                if photoCount > 0 || voiceCount > 0 || entryCount > 0 {
                    AdaptiveStack(spacing: 12) {
                        if photoCount > 0 {
                            Label("\(photoCount) photo\(photoCount == 1 ? "" : "s")", systemImage: "photo")
                        }
                        if voiceCount > 0 {
                            Label("\(voiceCount) voice note\(voiceCount == 1 ? "" : "s")", systemImage: "waveform")
                        }
                        if entryCount > 0 {
                            Label("\(entryCount) entr\(entryCount == 1 ? "y" : "ies")", systemImage: "book.closed")
                        }
                    }
                    .font(.note)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .cardSurface(cornerRadius: 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
