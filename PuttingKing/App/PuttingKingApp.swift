import SwiftUI

@main
struct PuttingKingApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                // Flush any pending settings to disk before backgrounding
                appState.settings.save()
            case .active, .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
