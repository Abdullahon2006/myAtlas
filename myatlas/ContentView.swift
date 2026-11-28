import SwiftUI

struct RouteFocusRequest: Equatable {
    let token = UUID()
    let routeID: UUID
}

struct RegionFocusRequest: Equatable {
    let token = UUID()
    let bounds: RegionBounds
}

enum AtlasTab: Hashable {
    case atlas
    case history
    case offline
}

struct ContentView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    @State private var selectedTab: AtlasTab = .atlas
    @State private var focusedRoute: RouteFocusRequest?
    @State private var focusedRegion: RegionFocusRequest?
    @State private var isShowingRecoveryAlert = false

    var body: some View {
        TabView(selection: $selectedTab) {
            AtlasHomeView(selectedTab: $selectedTab, focusedRoute: $focusedRoute, focusedRegion: $focusedRegion)
                .tabItem {
                    Label("Atlas", systemImage: "map.fill")
                }
                .tag(AtlasTab.atlas)

            HistoryView(selectedTab: $selectedTab, focusedRoute: $focusedRoute)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(AtlasTab.history)

            OfflineVaultView(selectedTab: $selectedTab, focusedRegion: $focusedRegion)
                .tabItem {
                    Label("Offline", systemImage: "arrow.down.circle.fill")
                }
                .tag(AtlasTab.offline)
        }
        .tint(Color.atlasClay)
        .sensoryFeedback(.success, trigger: atlas.lastSaveFeedbackID)
        .onAppear {
            if atlas.recoveryWarning != nil {
                isShowingRecoveryAlert = true
            }
        }
        .alert("Atlas Data Notice", isPresented: $isShowingRecoveryAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(atlas.recoveryWarning ?? "")
        }
        .alert(
            "Unable to Complete Action",
            isPresented: Binding(
                get: { atlas.bannerErrorMessage != nil },
                set: { if !$0 { atlas.bannerErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                atlas.bannerErrorMessage = nil
            }
        } message: {
            Text(atlas.bannerErrorMessage ?? "")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AtlasViewModel())
        .environmentObject(LocationService())
        .environmentObject(VoiceRecorderService())
}
