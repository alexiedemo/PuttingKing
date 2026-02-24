import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // M18 fix: added transition animation for smoother screen changes
        Group {
            if !appState.isOnboardingComplete {
                OnboardingView()
                    .transition(.opacity)
            } else {
                switch appState.currentScreen {
                case .home:
                    HomeView()
                        .transition(.opacity)
                case .scanning:
                    ScanningContainerView()
                        .transition(.opacity)
                case .settings:
                    SettingsView()
                        .transition(.opacity)
                case .history:
                    HistoryView()
                        .transition(.opacity)
                case .onboarding:
                    // Reached only via AppState.resetOnboarding() from Settings
                    OnboardingView()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.currentScreen)
        .animation(.easeInOut(duration: 0.25), value: appState.isOnboardingComplete)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
