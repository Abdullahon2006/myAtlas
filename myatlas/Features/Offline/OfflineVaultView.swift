import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ExportSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct OfflineVaultView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @Binding var selectedTab: AtlasTab
    @Binding var focusedRegion: RegionFocusRequest?
    @State private var isShowingCatalogSheet = false
    @State private var regionToRemove: AtlasRegion?
    @State private var sharePayload: ExportSharePayload?
    @State private var isExporting = false
    @State private var isShowingImporter = false
    @State private var pendingImportData: Data?
    @State private var importStatusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                regionsSection
                catalogSection
                storageSection
                exportSection
                privacySection
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.atlasCanvas.ignoresSafeArea())
            .navigationTitle("Offline & Vault")
            .sheet(isPresented: $isShowingCatalogSheet) {
                RegionDownloadSheet(currentViewport: nil) { bounds in
                    focusedRegion = RegionFocusRequest(bounds: bounds)
                    selectedTab = .atlas
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $sharePayload) { payload in
                ShareActivitySheet(items: [payload.url])
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handlePickedBackupFile(result)
            }
            .confirmationDialog(
                "Restore Atlas Backup",
                isPresented: Binding(
                    get: { pendingImportData != nil },
                    set: { if !$0 { pendingImportData = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Merge with Current Atlas") {
                    commitImport(merge: true)
                }
                Button("Replace Current Atlas", role: .destructive) {
                    commitImport(merge: false)
                }
                Button("Cancel", role: .cancel) {
                    pendingImportData = nil
                }
            } message: {
                Text("Merge keeps existing items and adds new ones from the backup. Replace overwrites your current places, entries, and routes.")
            }
            .confirmationDialog(
                "Remove \"\(regionToRemove?.name ?? "Region")\"?",
                isPresented: Binding(
                    get: { regionToRemove != nil },
                    set: { if !$0 { regionToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Offline Map Pack", role: .destructive) {
                    if let regionToRemove {
                        Task { await atlas.remove(region: regionToRemove) }
                    }
                    regionToRemove = nil
                }
                Button("Cancel", role: .cancel) {
                    regionToRemove = nil
                }
            } message: {
                Text("Your saved places, notes, photos, and voice notes inside this region will stay untouched.")
            }
            .alert(
                "Backup Restore",
                isPresented: Binding(
                    get: { importStatusMessage != nil },
                    set: { if !$0 { importStatusMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importStatusMessage = nil }
            } message: {
                Text(importStatusMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var regionsSection: some View {
        Section {
            if atlas.regions.isEmpty {
                Text("No offline packs downloaded yet. Download Istanbul or pick any city below to use maps in Airplane Mode.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(atlas.regions) { region in
                    AdaptiveStack(spacing: 12) {
                        Button {
                            if let bounds = region.bounds {
                                focusedRegion = RegionFocusRequest(bounds: bounds)
                                selectedTab = .atlas
                            }
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(
                                    systemImage: "map.fill",
                                    color: region.downloadState.isDownloaded ? Color.atlasMossButton : Color.atlasPrimaryButton,
                                    size: 34
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.name)
                                        .font(.rowTitle)
                                        .foregroundStyle(Color.atlasInk)
                                    Text(regionSubtitle(region))
                                        .font(.rowDetail)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        regionControls(for: region)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            regionToRemove = region
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Your Regions")
        } footer: {
            Text(atlas.mapConfiguration.attributionText)
        }
    }

    private var catalogSection: some View {
        Section("Available to Download") {
            let suggestions = atlas.availableCatalogRegions
            if suggestions.isEmpty {
                Text("All curated catalog regions are already in your atlas.")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions.prefix(6)) { region in
                    AdaptiveStack {
                        Button {
                            if let bounds = region.bounds {
                                focusedRegion = RegionFocusRequest(bounds: bounds)
                                selectedTab = .atlas
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(region.name)
                                    .font(.rowTitle)
                                    .foregroundStyle(Color.atlasInk)
                                Text("\(region.catalogGroup) · ~\(region.mapPackageSize.formatted(.byteCount(style: .file)))")
                                    .font(.rowDetail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Download") {
                            atlas.download(region: region)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.atlasClay)
                        .frame(minHeight: 44)
                    }
                }
                Button("Browse Full Catalog (\(AtlasCatalog.regions.count) Regions)") {
                    isShowingCatalogSheet = true
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var storageSection: some View {
        let stats = atlas.summaryStats
        return Section {
            LabeledContent("Saved Places", value: "\(stats.totalPlaces)")
            LabeledContent("Journal Entries", value: "\(stats.journalEntryCount)")
            LabeledContent("Photos (\(stats.photoCount))", value: atlas.mediaStorage.photoBytes.formatted(.byteCount(style: .file)))
            LabeledContent("Thumbnails", value: atlas.mediaStorage.thumbnailBytes.formatted(.byteCount(style: .file)))
            LabeledContent("Voice Notes (\(stats.voiceNoteCount))", value: atlas.mediaStorage.voiceBytes.formatted(.byteCount(style: .file)))
            LabeledContent("Offline Maps (Disk)", value: atlas.actualMapPackBytes.formatted(.byteCount(style: .file)))
            LabeledContent("Catalog Size Budget", value: stats.downloadedMapBytes.formatted(.byteCount(style: .file)))
        } header: {
            Text("On-Device Storage")
        } footer: {
            Text("Offline Maps (Disk) measures real vector tiles stored in MapLibre offline storage. Maps stay available even with Wi-Fi and cellular turned off.")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                exportCompleteBackup()
            } label: {
                Label("Export Full Backup with Media (.myatlas.json)", systemImage: "archivebox.fill")
                    .frame(minHeight: 44)
            }
            .disabled(isExporting)

            Button {
                exportMarkdown()
            } label: {
                Label("Export Travel Journal (Markdown)", systemImage: "doc.richtext")
                    .frame(minHeight: 44)
            }
            .disabled(isExporting)

            Button {
                exportLightweightJSON()
            } label: {
                Label("Export Metadata Snapshot (JSON)", systemImage: "externaldrive.badge.checkmark")
                    .frame(minHeight: 44)
            }
            .disabled(isExporting)

            Button {
                exportGPX()
            } label: {
                Label("Export Routes & Pins (GPX)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .frame(minHeight: 44)
            }
            .disabled(isExporting)

            Button {
                isShowingImporter = true
            } label: {
                Label("Import / Restore Backup…", systemImage: "square.and.arrow.down")
                    .frame(minHeight: 44)
            }
            .disabled(isExporting)
        } header: {
            Text("Local Backup & Restore")
        } footer: {
            Text("Your atlas lives exclusively on this device (excluded from iCloud Device Backup). Export a full backup with embedded photos and voice notes anytime.")
        }
    }

    private var privacySection: some View {
        Section("Privacy Promise") {
            Label("No accounts, no cloud sync, no analytics", systemImage: "lock.shield.fill")
                .foregroundStyle(Color.atlasMoss)
            Label("Foreground-only, opt-in route recording", systemImage: "location.slash.fill")
                .foregroundStyle(Color.atlasInk)
            Label("Device-protected local storage (excluded from cloud backup)", systemImage: "internaldrive.fill")
                .foregroundStyle(Color.atlasInk)
        }
    }

    // MARK: - Actions & Helpers

    private func exportCompleteBackup() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let data = try await atlas.buildCompleteBackupData()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("myatlas-complete-backup.myatlas.json")
                try data.write(to: url, options: .atomic)
                sharePayload = ExportSharePayload(url: url)
            } catch {
                importStatusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportLightweightJSON() {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let data = try await atlas.buildJSONExportData()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("myatlas-backup.json")
                try data.write(to: url, options: .atomic)
                sharePayload = ExportSharePayload(url: url)
            } catch {
                importStatusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportMarkdown() {
        isExporting = true
        let snapshot = atlas.makeExportSnapshot()
        Task {
            defer { isExporting = false }
            let markdown = await Task.detached(priority: .userInitiated) {
                AtlasExporter.exportMarkdown(snapshot: snapshot)
            }.value
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("myatlas-journal.md")
            try? Data(markdown.utf8).write(to: url, options: .atomic)
            sharePayload = ExportSharePayload(url: url)
        }
    }

    private func exportGPX() {
        isExporting = true
        let routes = atlas.sortedRoutes
        let places = atlas.recentPlaces
        Task {
            defer { isExporting = false }
            let gpx = await Task.detached(priority: .userInitiated) {
                AtlasExporter.exportGPX(routes: routes, places: places)
            }.value
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("myatlas-tracks.gpx")
            try? Data(gpx.utf8).write(to: url, options: .atomic)
            sharePayload = ExportSharePayload(url: url)
        }
    }

    private func handlePickedBackupFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }.value
                    pendingImportData = data
                } catch {
                    importStatusMessage = "Could not read backup file: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            importStatusMessage = "Could not open file picker: \(error.localizedDescription)"
        }
    }

    private func commitImport(merge: Bool) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        Task {
            do {
                let count = try await atlas.importBackup(from: data, merge: merge)
                importStatusMessage = "Restored \(count) place\(count == 1 ? "" : "s") from backup."
            } catch {
                importStatusMessage = "Invalid backup file: \(error.localizedDescription)"
            }
        }
    }

    private func regionSubtitle(_ region: AtlasRegion) -> String {
        switch region.downloadState {
        case .available:
            return "Ready to download · ~\(region.mapPackageSize.formatted(.byteCount(style: .file)))"
        case .downloading(let progress):
            return "Downloading vector tiles \(Int(progress * 100))%"
        case .downloaded:
            if let actualBytes = atlas.downloadedBytes(for: region) {
                return "Offline tiles ready · \(actualBytes.formatted(.byteCount(style: .file))) on disk"
            }
            return "Offline tiles ready · ~\(region.mapPackageSize.formatted(.byteCount(style: .file)))"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    @ViewBuilder
    private func regionControls(for region: AtlasRegion) -> some View {
        switch region.downloadState {
        case .available:
            Button("Download") {
                atlas.download(region: region)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 48)
                Button("Cancel") {
                    atlas.cancelDownload(for: region)
                }
                .buttonStyle(.borderless)
                .font(.badge)
                .frame(minHeight: 44)
            }
        case .downloaded:
            Button(role: .destructive) {
                regionToRemove = region
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(region.name)")
        case .failed:
            Button("Retry") {
                atlas.download(region: region)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
    }
}

struct ShareActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
