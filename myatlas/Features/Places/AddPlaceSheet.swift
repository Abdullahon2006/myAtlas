import MapKit
import PhotosUI
import SwiftUI
import UIKit

private struct DraftPhoto: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: UIImage?
}

struct AddPlaceSheet: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var voiceService: VoiceRecorderService
    @Environment(\.dismiss) private var dismiss

    private let initialCoordinate: Coordinate?

    @State private var name = ""
    @State private var subtitle = ""
    @State private var note = ""
    @State private var category: PlaceCategory = .gem
    @State private var isFavorite = false
    @State private var rating: Int = 0
    @State private var visitedAt = Date.now

    @State private var latitude: Double
    @State private var longitude: Double

    @State private var searchQuery = ""
    @State private var searchSuggestions: [PlaceSearchSuggestion] = []
    @State private var searchNotice: String?
    @State private var isSearching = false
    @State private var showManualCoordinates = false

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var draftPhotos: [DraftPhoto] = []
    @State private var isLoadingPhotos = false
    @State private var isShowingCamera = false

    @State private var recordedVoiceURL: URL?
    @State private var recordedVoiceDuration: TimeInterval = 0
    @State private var isSaving = false
    @State private var isShowingDiscardConfirm = false

    init(initialCoordinate: Coordinate? = nil) {
        self.initialCoordinate = initialCoordinate
        let start = initialCoordinate ?? Coordinate(latitude: 41.0256, longitude: 28.9741)
        _latitude = State(initialValue: start.latitude)
        _longitude = State(initialValue: start.longitude)
    }

    private var hasUnsavedChanges: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftPhotos.isEmpty
            || recordedVoiceURL != nil
            || voiceService.isRecording
    }

    var body: some View {
        NavigationStack {
            Form {
                locationSection
                detailsSection
                memorySection
                photosSection
                voiceSection
                saveSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save Place")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(voiceService.isRecording || isSaving || hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges {
                            isShowingDiscardConfirm = true
                        } else {
                            cleanupTempMedia()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await commitSave() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("confirm-save-place-button")
                }
            }
            .confirmationDialog("Discard this place?", isPresented: $isShowingDiscardConfirm, titleVisibility: .visible) {
                Button("Discard Draft", role: .destructive) {
                    cleanupTempMedia()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your typed notes, selected photos, and recorded voice note will be discarded.")
            }
            .sheet(isPresented: $isShowingCamera) {
                CameraCaptureView { image in
                    Task {
                        let draft = await Self.makeDraftPhoto(from: image)
                        if let draft {
                            draftPhotos.append(draft)
                        }
                    }
                }
            }
            .onDisappear {
                cleanupTempMedia()
            }
            .task {
                if initialCoordinate == nil, let coord = locationService.currentCoordinate {
                    applyCoordinate(coord, fillSubtitleIfEmpty: true)
                } else if let initialCoordinate {
                    await fillSubtitleIfEmpty(for: initialCoordinate)
                }
            }
        }
    }

    // MARK: - Sections

    private var locationSection: some View {
        Section {
            MapLibreMiniMapView(
                coordinate: Coordinate(latitude: clampedLatitude, longitude: clampedLongitude),
                category: category,
                zoomLevel: 13.5
            ) { tapped in
                applyCoordinate(tapped, fillSubtitleIfEmpty: true)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            AdaptiveStack(spacing: 10) {
                Button {
                    Task {
                        if let coord = await locationService.requestCurrentCoordinate() {
                            applyCoordinate(coord, fillSubtitleIfEmpty: true)
                        }
                    }
                } label: {
                    Label(
                        locationService.isRequestingLocation ? "Locating…" : "Use My Location",
                        systemImage: "location.fill"
                    )
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(locationService.isRequestingLocation)

                Spacer()

                Text(Coordinate(latitude: clampedLatitude, longitude: clampedLongitude).formattedString)
                    .font(.coordinate)
                    .foregroundStyle(.secondary)
            }

            if let locationError = locationService.locationErrorMessage {
                Text(locationError)
                    .font(.note)
                    .foregroundStyle(Color.atlasClay)
            }

            HStack {
                TextField("Search city, landmark, or address", text: $searchQuery)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await performSearch() }
                    }
                if isSearching {
                    ProgressView()
                } else if !searchQuery.isEmpty {
                    Button("Find") {
                        Task { await performSearch() }
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }

            if let searchNotice {
                Text(searchNotice)
                    .font(.note)
                    .foregroundStyle(.secondary)
            }

            ForEach(searchSuggestions) { suggestion in
                Button {
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = suggestion.name
                    }
                    subtitle = suggestion.subtitle
                    applyCoordinate(suggestion.coordinate, fillSubtitleIfEmpty: false)
                    searchSuggestions = []
                    searchNotice = nil
                    searchQuery = ""
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.name)
                            .font(.rowTitle)
                            .foregroundStyle(Color.atlasInk)
                        Text(suggestion.subtitle)
                            .font(.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup("Manual Coordinates", isExpanded: $showManualCoordinates) {
                HStack {
                    Text("Latitude")
                    Spacer()
                    TextField("Latitude", value: $latitude, format: .number.precision(.fractionLength(4)))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: latitude) { _, newValue in
                            if !newValue.isFinite { latitude = 0 }
                            latitude = min(90, max(-90, latitude))
                        }
                }
                HStack {
                    Text("Longitude")
                    Spacer()
                    TextField("Longitude", value: $longitude, format: .number.precision(.fractionLength(4)))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: longitude) { _, newValue in
                            if !newValue.isFinite { longitude = 0 }
                            longitude = min(180, max(-180, longitude))
                        }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Tap the map to move the pin, use GPS, or enter coordinates offline.")
        }
    }

    private var detailsSection: some View {
        Section("Place Details") {
            TextField("Place name (e.g. Miradouro)", text: $name)
                .textInputAutocapitalization(.words)
            TextField("City or region", text: $subtitle)
                .textInputAutocapitalization(.words)

            Picker("Category", selection: $category) {
                ForEach(PlaceCategory.allCases) { item in
                    Label(item.displayName, systemImage: item.systemImage)
                        .tag(item)
                }
            }

            Toggle(isOn: $isFavorite) {
                Label("Favorite Place", systemImage: isFavorite ? "star.fill" : "star")
            }
            .tint(Color.atlasAmber)

            DatePicker("Visited", selection: $visitedAt, displayedComponents: [.date, .hourAndMinute])

            StarRatingControl(rating: $rating)
        }
    }

    private var memorySection: some View {
        Section("Memory Note") {
            TextField("What do you want to remember about this place?", text: $note, axis: .vertical)
                .lineLimit(3...8)
        }
    }

    private var photosSection: some View {
        Section("Photos") {
            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 8, matching: .images) {
                Label(
                    draftPhotos.isEmpty ? "Choose Photos" : "Add More Photos (\(draftPhotos.count))",
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .onChange(of: selectedPhotoItems) {
                Task { await loadPickedPhotos() }
            }

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    isShowingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }

            if isLoadingPhotos {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing selected photos…")
                        .font(.note)
                        .foregroundStyle(.secondary)
                }
            }

            if !draftPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(draftPhotos.enumerated()), id: \.element.id) { index, draft in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let thumb = draft.thumbnail {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color.atlasMist
                                    }
                                }
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel("Attached photo \(index + 1)")

                                Button {
                                    draftPhotos.removeAll { $0.id == draft.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.symbol)
                                        .foregroundStyle(.white, Color.atlasInk)
                                        .frame(width: 44, height: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove photo \(index + 1)")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var voiceSection: some View {
        Section("Voice Note") {
            if voiceService.isRecording {
                VStack(alignment: .leading, spacing: 10) {
                    AdaptiveStack {
                        Label("Recording", systemImage: "waveform")
                            .foregroundStyle(Color.atlasClay)
                            .font(.rowTitle)
                        Spacer()
                        Text(VoiceRecorderService.formattedDuration(voiceService.recordingDuration))
                            .font(.coordinate)
                    }

                    WaveformBarStrip(samples: voiceService.meterSamples, tint: Color.atlasClay)
                        .frame(height: 28)

                    AdaptiveStack(spacing: 12) {
                        Button("Stop & Attach") {
                            if let result = voiceService.stopRecording() {
                                if let previous = recordedVoiceURL {
                                    try? FileManager.default.removeItem(at: previous)
                                }
                                recordedVoiceURL = result.url
                                recordedVoiceDuration = result.duration
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.atlasPrimaryButton)
                        .frame(minHeight: 44)

                        Button("Discard", role: .destructive) {
                            voiceService.cancelRecording()
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                    }
                }
            } else if let recordedVoiceURL {
                AdaptiveStack(spacing: 10) {
                    Button {
                        voiceService.togglePlayback(url: recordedVoiceURL, attachmentID: Self.draftVoiceID)
                    } label: {
                        Label(
                            voiceService.playingAttachmentID == Self.draftVoiceID && voiceService.isPlaying
                                ? "Pause Voice Note (\(VoiceRecorderService.formattedDuration(recordedVoiceDuration)))"
                                : "Play Voice Note (\(VoiceRecorderService.formattedDuration(recordedVoiceDuration)))",
                            systemImage: voiceService.playingAttachmentID == Self.draftVoiceID && voiceService.isPlaying
                                ? "pause.circle.fill"
                                : "play.circle.fill"
                        )
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        voiceService.stopPlayback()
                        try? FileManager.default.removeItem(at: recordedVoiceURL)
                        self.recordedVoiceURL = nil
                        self.recordedVoiceDuration = 0
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete recorded voice note")
                }
            } else {
                Button {
                    Task {
                        _ = await voiceService.startRecording()
                    }
                } label: {
                    Label("Record Voice Note", systemImage: "mic.fill")
                        .frame(minHeight: 44)
                }
            }

            if let voiceError = voiceService.errorMessage {
                Text(voiceError)
                    .font(.note)
                    .foregroundStyle(Color.atlasClay)
            }
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                Task { await commitSave() }
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save Place")
                            .font(.buttonLabel)
                    }
                    Spacer()
                }
                .frame(minHeight: 44)
            }
            .disabled(!canSave)
            .accessibilityIdentifier("bottom-save-place-button")
        }
    }

    // MARK: - Helpers

    private static let draftVoiceID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private var clampedLatitude: Double {
        latitude.isFinite ? min(90, max(-90, latitude)) : 0
    }

    private var clampedLongitude: Double {
        longitude.isFinite ? min(180, max(-180, longitude)) : 0
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoadingPhotos
            && !isSaving
            && !voiceService.isRecording
    }

    private func applyCoordinate(_ coord: Coordinate, fillSubtitleIfEmpty shouldFillSubtitle: Bool) {
        latitude = min(90, max(-90, coord.latitude))
        longitude = min(180, max(-180, coord.longitude))
        if shouldFillSubtitle {
            Task { await fillSubtitleIfEmpty(for: coord) }
        }
    }

    private func fillSubtitleIfEmpty(for coord: Coordinate) async {
        guard subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let city = await locationService.reverseGeocodeSubtitle(for: coord) {
            if subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subtitle = city
            }
        }
    }

    private func performSearch() async {
        isSearching = true
        defer { isSearching = false }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: clampedLatitude, longitude: clampedLongitude),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        let result = await locationService.searchPlaces(query: searchQuery, near: region)
        if result.suggestions.isEmpty {
            let offlineMatches = localOfflineSuggestions(matching: searchQuery)
            if !offlineMatches.isEmpty {
                searchSuggestions = offlineMatches
                searchNotice = "Showing offline matches in your atlas & catalog."
                return
            }
        }
        searchSuggestions = result.suggestions
        searchNotice = result.offlineNotice
    }

    private func localOfflineSuggestions(matching query: String) -> [PlaceSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var matches: [PlaceSearchSuggestion] = []
        for place in atlas.recentPlaces {
            if place.name.localizedCaseInsensitiveContains(trimmed)
                || place.subtitle.localizedCaseInsensitiveContains(trimmed) {
                matches.append(
                    PlaceSearchSuggestion(
                        name: place.name,
                        subtitle: place.subtitle,
                        coordinate: place.coordinate
                    )
                )
            }
        }

        let istanbulSpots: [(String, String, Double, Double)] = [
            ("Galata Tower", "Beyoğlu, Istanbul", 41.0256, 28.9741),
            ("Sultanahmet Square", "Fatih, Istanbul", 41.0054, 28.9768),
            ("Taksim Square", "Beyoğlu, Istanbul", 41.0369, 28.9851),
            ("Karaköy Ferry Terminal", "Beyoğlu, Istanbul", 41.0218, 28.9769),
            ("Kadıköy Pier", "Kadıköy, Istanbul", 40.9929, 29.0230),
            ("Moda Sahil Park", "Kadıköy, Istanbul", 40.9794, 29.0251),
            ("Üsküdar Square", "Üsküdar, Istanbul", 41.0266, 29.0156),
            ("Ortaköy Mosque", "Beşiktaş, Istanbul", 41.0472, 29.0269),
            ("Beşiktaş Pier", "Beşiktaş, Istanbul", 41.0419, 29.0072),
            ("Bebek Bay", "Beşiktaş, Istanbul", 41.0766, 29.0439),
            ("Büyükada Pier", "Adalar, Istanbul", 40.8744, 29.1277),
            ("Dolmabahçe", "Beşiktaş, Istanbul", 41.0391, 29.0005),
            ("Balat & Fener", "Fatih, Istanbul", 41.0306, 28.9488),
            ("Bağdat Avenue (Suadiye)", "Kadıköy, Istanbul", 40.9602, 29.0830),
            ("Emirgan Grove", "Sarıyer, Istanbul", 41.1088, 29.0558)
        ]

        for (spotName, spotSubtitle, lat, lon) in istanbulSpots {
            if spotName.localizedCaseInsensitiveContains(trimmed)
                || spotSubtitle.localizedCaseInsensitiveContains(trimmed) {
                matches.append(
                    PlaceSearchSuggestion(
                        name: spotName,
                        subtitle: spotSubtitle,
                        coordinate: Coordinate(latitude: lat, longitude: lon)
                    )
                )
            }
        }

        for catalogRegion in AtlasCatalog.regions {
            if let bounds = catalogRegion.bounds,
               (catalogRegion.name.localizedCaseInsensitiveContains(trimmed)
                || catalogRegion.countryCode.localizedCaseInsensitiveContains(trimmed)) {
                matches.append(
                    PlaceSearchSuggestion(
                        name: catalogRegion.name,
                        subtitle: "\(catalogRegion.countryCode) · Catalog Region",
                        coordinate: Coordinate(latitude: bounds.centerLatitude, longitude: bounds.centerLongitude)
                    )
                )
            }
        }

        return Array(matches.prefix(8))
    }

    private func loadPickedPhotos() async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        var loaded: [DraftPhoto] = []
        for item in selectedPhotoItems {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let thumb = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
                }.value
                loaded.append(DraftPhoto(data: data, thumbnail: thumb))
            }
        }
        draftPhotos.append(contentsOf: loaded)
        selectedPhotoItems = []
    }

    private static func makeDraftPhoto(from image: UIImage) async -> DraftPhoto? {
        await Task.detached(priority: .userInitiated) {
            guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            let thumb = image.preparingThumbnail(of: CGSize(width: 240, height: 240))
            return DraftPhoto(data: data, thumbnail: thumb)
        }.value
    }

    private func commitSave() async {
        isSaving = true
        defer { isSaving = false }
        voiceService.stopPlayback()
        _ = await atlas.saveNewPlace(
            name: name,
            subtitle: subtitle,
            latitude: clampedLatitude,
            longitude: clampedLongitude,
            visitedAt: visitedAt,
            category: category,
            isFavorite: isFavorite,
            rating: rating > 0 ? rating : nil,
            note: note,
            photoItemsData: draftPhotos.map(\.data),
            pendingVoiceURL: recordedVoiceURL,
            pendingVoiceDuration: recordedVoiceDuration
        )
        recordedVoiceURL = nil
        dismiss()
    }

    private func cleanupTempMedia() {
        if voiceService.isRecording {
            voiceService.cancelRecording()
        }
        voiceService.stopPlayback()
        if let recordedVoiceURL {
            try? FileManager.default.removeItem(at: recordedVoiceURL)
            self.recordedVoiceURL = nil
        }
    }
}

struct WaveformBarStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let samples: [Float]
    let tint: Color

    var body: some View {
        if reduceMotion {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.symbol)
                    .foregroundStyle(tint)
                Text("Recording audio…")
                    .font(.note)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            GeometryReader { proxy in
                let count = max(samples.count, 1)
                let barWidth = max(2, (proxy.size.width - CGFloat(count - 1) * 3) / CGFloat(count))
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        Capsule()
                            .fill(tint)
                            .frame(width: barWidth, height: max(4, proxy.size.height * CGFloat(sample)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .accessibilityHidden(true)
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
