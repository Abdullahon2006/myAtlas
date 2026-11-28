import PhotosUI
import SwiftUI
import UIKit

struct PlaceDetailView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @EnvironmentObject private var voiceService: VoiceRecorderService
    @Environment(\.dismiss) private var dismiss

    let placeID: UUID

    @State private var isShowingEditSheet = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingAddEntrySheet = false
    @State private var editingEntry: JournalEntry?
    @State private var entryToDelete: JournalEntry?
    @State private var attachmentToDelete: PlaceAttachment?
    @State private var selectedPhotoAttachment: PlaceAttachment?
    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    @State private var isShowingCamera = false
    @State private var copiedCoordinates = false
    @State private var sharePayload: ExportSharePayload?

    private var place: Place? {
        atlas.places.first { $0.id == placeID }
    }

    private var placeAttachments: [PlaceAttachment] {
        atlas.attachments(for: placeID)
    }

    private var photoAttachments: [PlaceAttachment] {
        placeAttachments.filter { $0.kind == .photo }
    }

    private var voiceAttachments: [PlaceAttachment] {
        placeAttachments.filter { $0.kind == .voice }
    }

    private var journalEntries: [JournalEntry] {
        atlas.entries(for: placeID)
    }

    var body: some View {
        Group {
            if let place {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerMapCard(place: place)
                        noteCard(place: place)
                        photosSection(place: place)
                        voiceNotesSection(place: place)
                        journalEntriesSection(place: place)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color.atlasCanvas.ignoresSafeArea())
                .navigationTitle(place.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            atlas.toggleFavorite(for: place)
                        } label: {
                            Image(systemName: place.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(place.isFavorite ? Color.atlasAmber : Color.atlasInk)
                        }
                        .accessibilityLabel(place.isFavorite ? "Remove from Favorites" : "Mark as Favorite")

                        Button {
                            sharePlaceMarkdown(place)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share Place Memory")

                        Menu {
                            Button {
                                isShowingEditSheet = true
                            } label: {
                                Label("Edit Place", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                isShowingDeleteConfirmation = true
                            } label: {
                                Label("Delete Place", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More Place Actions")
                    }
                }
                .sheet(isPresented: $isShowingEditSheet) {
                    EditPlaceSheet(place: place)
                }
                .sheet(isPresented: $isShowingAddEntrySheet) {
                    JournalEntryEditorSheet(placeID: place.id, existingEntry: nil)
                }
                .sheet(item: $editingEntry) { entry in
                    JournalEntryEditorSheet(placeID: place.id, existingEntry: entry)
                }
                .sheet(isPresented: $isShowingCamera) {
                    CameraCaptureView { image in
                        Task {
                            let data = await Task.detached(priority: .userInitiated) {
                                image.jpegData(compressionQuality: 0.9)
                            }.value
                            if let data {
                                await atlas.addPhotoAndAwait(data, to: place.id)
                            }
                        }
                    }
                }
                .fullScreenCover(item: $selectedPhotoAttachment) { attachment in
                    FullScreenPhotoViewer(attachment: attachment) {
                        attachmentToDelete = attachment
                    }
                }
                .sheet(item: $sharePayload) { payload in
                    ShareActivitySheet(items: [payload.url])
                }
                .confirmationDialog(
                    "Delete \"\(place.name)\"?",
                    isPresented: $isShowingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Place & Attachments", role: .destructive) {
                        voiceService.cancelRecording()
                        voiceService.stopPlayback()
                        atlas.delete(place: place)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes the place, its journal entries, photos, and voice notes from this device.")
                }
                .confirmationDialog(
                    "Delete Attachment?",
                    isPresented: Binding(
                        get: { attachmentToDelete != nil },
                        set: { if !$0 { attachmentToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Attachment", role: .destructive) {
                        if let attachmentToDelete {
                            if voiceService.playingAttachmentID == attachmentToDelete.id {
                                voiceService.stopPlayback()
                            }
                            atlas.delete(attachment: attachmentToDelete)
                        }
                        attachmentToDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        attachmentToDelete = nil
                    }
                } message: {
                    Text("This permanently removes the media file from this device.")
                }
                .confirmationDialog(
                    "Delete Journal Entry?",
                    isPresented: Binding(
                        get: { entryToDelete != nil },
                        set: { if !$0 { entryToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Entry", role: .destructive) {
                        if let entryToDelete {
                            atlas.delete(entry: entryToDelete)
                        }
                        entryToDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        entryToDelete = nil
                    }
                } message: {
                    Text("This permanently deletes this journal entry.")
                }
            } else {
                ContentUnavailableView("Place Removed", systemImage: "mappin.slash")
            }
        }
        .onDisappear {
            voiceService.cancelRecording()
            voiceService.stopPlayback()
        }
    }

    // MARK: - Subviews

    private func headerMapCard(place: Place) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MapLibreMiniMapView(
                coordinate: place.coordinate,
                category: place.category,
                zoomLevel: 14.0
            )
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                AdaptiveStack(spacing: 8) {
                    CategoryBadge(category: place.category)
                    if let rating = place.rating, rating > 0 {
                        Label("\(rating)/5", systemImage: "star.fill")
                            .font(.badge)
                            .foregroundStyle(Color.atlasAmber)
                    }
                    Spacer()
                    Text(place.visitedAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                }

                Text(place.name)
                    .font(.detailTitle)
                    .foregroundStyle(Color.atlasInk)

                Text(place.subtitle)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = place.coordinate.formattedString
                    copiedCoordinates = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedCoordinates = false
                    }
                } label: {
                    Label(
                        copiedCoordinates ? "Copied \(place.coordinate.formattedString)" : place.coordinate.formattedString,
                        systemImage: copiedCoordinates ? "checkmark" : "doc.on.doc"
                    )
                    .font(.coordinate)
                    .foregroundStyle(Color.atlasMoss)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Copy coordinates \(place.coordinate.formattedString)")
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .cardSurface(cornerRadius: 18)
    }

    @ViewBuilder
    private func noteCard(place: Place) -> some View {
        if let note = place.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "Field Note", actionTitle: "Edit") {
                    isShowingEditSheet = true
                }
                Text(note)
                    .font(.bodyText)
                    .foregroundStyle(Color.atlasInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .cardSurface(cornerRadius: 14)
            }
        }
    }

    private func photosSection(place: Place) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveStack {
                Text("Photos (\(photoAttachments.count))")
                    .font(.sectionLabel)
                    .foregroundStyle(Color.atlasMoss)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: 12) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            isShowingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera")
                                .font(.rowSubtitle.weight(.semibold))
                                .foregroundStyle(Color.atlasClay)
                                .frame(minHeight: 44)
                        }
                    }
                    PhotosPicker(selection: $pickedPhotoItems, maxSelectionCount: 6, matching: .images) {
                        Label("Add", systemImage: "plus")
                            .font(.rowSubtitle.weight(.semibold))
                            .foregroundStyle(Color.atlasClay)
                            .frame(minHeight: 44)
                    }
                    .onChange(of: pickedPhotoItems) {
                        Task {
                            isLoadingPhotos = true
                            defer { isLoadingPhotos = false }
                            for item in pickedPhotoItems {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    await atlas.addPhotoAndAwait(data, to: place.id)
                                }
                            }
                            pickedPhotoItems = []
                        }
                    }
                }
            }

            if isLoadingPhotos {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Adding photos…")
                        .font(.note)
                        .foregroundStyle(.secondary)
                }
            }

            if photoAttachments.isEmpty && !isLoadingPhotos {
                Text("Tap Add to attach photos from your library or camera.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 14)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(photoAttachments) { attachment in
                        Button {
                            selectedPhotoAttachment = attachment
                        } label: {
                            AttachmentThumbnailView(attachment: attachment, cornerRadius: 12)
                                .frame(height: 104)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                attachmentToDelete = attachment
                            } label: {
                                Label("Delete Photo", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: "Delete Photo") {
                            attachmentToDelete = attachment
                        }
                        .accessibilityLabel("Open photo added \(attachment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
    }

    private func voiceNotesSection(place: Place) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveStack {
                Text("Voice Notes (\(voiceAttachments.count))")
                    .font(.sectionLabel)
                    .foregroundStyle(Color.atlasMoss)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if voiceService.isRecording {
                    HStack(spacing: 12) {
                        Button("Stop & Save") {
                            if let result = voiceService.stopRecording() {
                                Task {
                                    await atlas.addVoiceNote(from: result.url, duration: result.duration, to: place.id)
                                    try? FileManager.default.removeItem(at: result.url)
                                }
                            }
                        }
                        .font(.rowSubtitle.weight(.semibold))
                        .foregroundStyle(Color.atlasClay)
                        .frame(minHeight: 44)

                        Button("Cancel", role: .destructive) {
                            voiceService.cancelRecording()
                        }
                        .font(.rowSubtitle)
                        .frame(minHeight: 44)
                    }
                } else {
                    Button {
                        Task { _ = await voiceService.startRecording() }
                    } label: {
                        Label("Record", systemImage: "mic.fill")
                            .font(.rowSubtitle.weight(.semibold))
                            .foregroundStyle(Color.atlasClay)
                            .frame(minHeight: 44)
                    }
                }
            }

            if voiceService.isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    AdaptiveStack {
                        Label("Recording voice note…", systemImage: "waveform")
                            .font(.rowTitle)
                            .foregroundStyle(Color.atlasClay)
                        Spacer()
                        Text(VoiceRecorderService.formattedDuration(voiceService.recordingDuration))
                            .font(.coordinate)
                    }
                    WaveformBarStrip(samples: voiceService.meterSamples, tint: Color.atlasClay)
                        .frame(height: 24)
                }
                .padding(14)
                .cardSurface(cornerRadius: 14)
            }

            if let voiceError = voiceService.errorMessage {
                Text(voiceError)
                    .font(.note)
                    .foregroundStyle(Color.atlasClay)
            }

            if voiceAttachments.isEmpty && !voiceService.isRecording {
                Text("Tap Record to capture ambient sound or spoken reflections offline.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 14)
            } else {
                ForEach(voiceAttachments) { attachment in
                    VoiceAttachmentRow(attachment: attachment) {
                        attachmentToDelete = attachment
                    }
                }
            }
        }
    }

    private func journalEntriesSection(place: Place) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Journal Entries (\(journalEntries.count))", actionTitle: "Add Entry") {
                isShowingAddEntrySheet = true
            }

            if journalEntries.isEmpty {
                Text("Tap Add Entry to build a dated travelogue for this spot.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 14)
            } else {
                ForEach(journalEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        AdaptiveStack(spacing: 8) {
                            if let title = entry.title, !title.isEmpty {
                                Text(title)
                                    .font(.rowTitle)
                                    .foregroundStyle(Color.atlasInk)
                            }
                            Spacer()
                            Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.rowDetail)
                                .foregroundStyle(.secondary)

                            Menu {
                                Button {
                                    editingEntry = entry
                                } label: {
                                    Label("Edit Entry", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    entryToDelete = entry
                                } label: {
                                    Label("Delete Entry", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Entry actions")
                        }

                        Text(entry.body)
                            .font(.bodyText)
                            .foregroundStyle(Color.atlasInk)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface(cornerRadius: 14)
                    .contextMenu {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label("Edit Entry", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            entryToDelete = entry
                        } label: {
                            Label("Delete Entry", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Edit Entry") {
                        editingEntry = entry
                    }
                    .accessibilityAction(named: "Delete Entry") {
                        entryToDelete = entry
                    }
                }
            }
        }
    }

    private func sharePlaceMarkdown(_ place: Place) {
        let entries = journalEntries
        let attachments = placeAttachments
        let filename = "\(AtlasExporter.sanitizedExportFilename(place.name, fallback: "place-memory")).md"
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                let md = AtlasExporter.exportSinglePlaceMarkdown(
                    place: place,
                    entries: entries,
                    attachments: attachments
                )
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? Data(md.utf8).write(to: tempURL, options: .atomic)
                return tempURL
            }.value
            sharePayload = ExportSharePayload(url: url)
        }
    }
}

private struct VoiceAttachmentRow: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @EnvironmentObject private var voiceService: VoiceRecorderService
    let attachment: PlaceAttachment
    let onRequestDelete: () -> Void

    private var isActive: Bool {
        voiceService.playingAttachmentID == attachment.id
    }

    var body: some View {
        AdaptiveStack(spacing: 12) {
            Button {
                if let url = atlas.voiceFileURL(for: attachment) {
                    voiceService.togglePlayback(url: url, attachmentID: attachment.id)
                }
            } label: {
                Image(systemName: isActive && voiceService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.symbolLarge)
                    .foregroundStyle(Color.atlasClay)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(isActive && voiceService.isPlaying ? "Pause voice note" : "Play voice note")

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.rowTitle)
                    .foregroundStyle(Color.atlasInk)
                if isActive, voiceService.playbackDuration > 0 {
                    ProgressView(value: voiceService.playbackCurrentTime, total: voiceService.playbackDuration)
                        .tint(Color.atlasClay)
                }
                Text(VoiceRecorderService.formattedDuration(attachment.durationSeconds ?? 0))
                    .font(.coordinate)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: onRequestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Delete voice note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cardSurface(cornerRadius: 14)
    }
}

private struct FullScreenPhotoViewer: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Environment(\.dismiss) private var dismiss
    let attachment: PlaceAttachment
    let onRequestDelete: () -> Void

    @State private var fullImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let fullImage {
                    Image(uiImage: fullImage)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(.white)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        dismiss()
                        onRequestDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                    .accessibilityLabel("Delete Photo")
                }
            }
            .task(id: attachment.id) {
                fullImage = await atlas.loadFullPhotoImage(for: attachment)
            }
        }
    }
}

private struct EditPlaceSheet: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Environment(\.dismiss) private var dismiss

    let place: Place

    @State private var name: String
    @State private var subtitle: String
    @State private var note: String
    @State private var category: PlaceCategory
    @State private var isFavorite: Bool
    @State private var rating: Int
    @State private var visitedAt: Date
    @State private var latitude: Double
    @State private var longitude: Double

    init(place: Place) {
        self.place = place
        _name = State(initialValue: place.name)
        _subtitle = State(initialValue: place.subtitle)
        _note = State(initialValue: place.note ?? "")
        _category = State(initialValue: place.category)
        _isFavorite = State(initialValue: place.isFavorite)
        _rating = State(initialValue: place.rating ?? 0)
        _visitedAt = State(initialValue: place.visitedAt)
        _latitude = State(initialValue: place.latitude)
        _longitude = State(initialValue: place.longitude)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location (Tap map to adjust pin)") {
                    MapLibreMiniMapView(
                        coordinate: Coordinate(latitude: latitude, longitude: longitude),
                        category: category,
                        zoomLevel: 14.0
                    ) { coord in
                        latitude = min(90, max(-90, coord.latitude))
                        longitude = min(180, max(-180, coord.longitude))
                    }
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section("Place Details") {
                    TextField("Name", text: $name)
                    TextField("City or region", text: $subtitle)
                    Picker("Category", selection: $category) {
                        ForEach(PlaceCategory.allCases) { item in
                            Label(item.displayName, systemImage: item.systemImage).tag(item)
                        }
                    }
                    Toggle("Favorite", isOn: $isFavorite)
                        .tint(Color.atlasAmber)
                    DatePicker("Visited", selection: $visitedAt, displayedComponents: [.date, .hourAndMinute])
                    StarRatingControl(rating: $rating)
                }

                Section("Memory Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = place
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.name = cleanName.isEmpty ? place.name : cleanName
                        updated.subtitle = cleanSubtitle.isEmpty ? place.subtitle : cleanSubtitle
                        updated.latitude = latitude
                        updated.longitude = longitude
                        updated.category = category
                        updated.isFavorite = isFavorite
                        updated.rating = rating > 0 ? rating : nil
                        updated.visitedAt = visitedAt
                        updated.note = cleanNote.isEmpty ? nil : cleanNote
                        atlas.update(place: updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct JournalEntryEditorSheet: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Environment(\.dismiss) private var dismiss

    let placeID: UUID
    let existingEntry: JournalEntry?

    @State private var title: String
    @State private var bodyText: String

    init(placeID: UUID, existingEntry: JournalEntry?) {
        self.placeID = placeID
        self.existingEntry = existingEntry
        _title = State(initialValue: existingEntry?.title ?? "")
        _bodyText = State(initialValue: existingEntry?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    TextField("Title (optional)", text: $title)
                    TextField("Write what happened here…", text: $bodyText, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existingEntry == nil ? "New Journal Entry" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingEntry == nil ? "Add" : "Save") {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if var updated = existingEntry {
                            updated.title = cleanTitle.isEmpty ? nil : cleanTitle
                            updated.body = cleanBody
                            atlas.update(entry: updated)
                        } else {
                            let entry = JournalEntry(
                                placeID: placeID,
                                title: cleanTitle.isEmpty ? nil : cleanTitle,
                                body: cleanBody
                            )
                            atlas.add(entry: entry)
                        }
                        dismiss()
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
