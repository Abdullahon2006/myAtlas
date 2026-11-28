import SwiftUI

@main
struct MyAtlasApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var atlas = AtlasViewModel()
    @StateObject private var locationService = LocationService()
    @StateObject private var voiceService = VoiceRecorderService()

    init() {
        MapLibreRuntime.configureIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(atlas)
                .environmentObject(locationService)
                .environmentObject(voiceService)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                atlas.flushPersistence()
            }
        }
    }
}
