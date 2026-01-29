import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isOnboardingComplete {
                OnboardingView()
            } else {
                switch appState.currentScreen {
                case .home:
                    HomeView()
                case .scanning:
                    ScanningContainerView()
                case .settings:
                    SettingsView()
                case .history:
                    HistoryView()
                case .onboarding:
                    OnboardingView()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
