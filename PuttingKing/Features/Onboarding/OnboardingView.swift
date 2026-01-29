import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0
    @State private var cameraPermissionGranted = false
    @State private var showingPermissionAlert = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "viewfinder",
            title: "Scan the Green",
            description: "Use your iPhone's LiDAR to capture the exact surface of the putting green.",
            color: .green
        ),
        OnboardingPage(
            icon: "flag.fill",
            title: "Mark the Hole",
            description: "Walk to the hole and tap to mark its position. The app will remember where it is.",
            color: .orange
        ),
        OnboardingPage(
            icon: "figure.walk",
            title: "Walk & Scan",
            description: "Walk back to your ball while moving your phone side-to-side to scan the green's surface.",
            color: .blue
        ),
        OnboardingPage(
            icon: "arrow.triangle.turn.up.right.diamond.fill",
            title: "Get Your Line",
            description: "The app calculates the perfect putting line, showing you exactly where to aim.",
            color: .purple
        )
    ]

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack {
                // Skip button
                HStack {
                    Spacer()
                    if currentPage < pages.count - 1 {
                        Button("Skip") {
                            checkPermissionsAndComplete()
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .padding()
                    }
                }

                Spacer()

                // Page content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        pageView(for: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.vertical, 20)

                // Continue / Get Started button
                Button(action: {
                    if currentPage < pages.count - 1 {
                        withAnimation {
                            currentPage += 1
                        }
                    } else {
                        checkPermissionsAndComplete()
                    }
                }) {
                    Text(currentPage < pages.count - 1 ? "Continue" : "Get Started")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(DesignSystem.Colors.primary)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .alert("Camera Access Required", isPresented: $showingPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("PuttingKing needs camera access to scan the green using LiDAR. Please enable camera access in Settings.")
        }
    }

    private func pageView(for page: OnboardingPage) -> some View {
        VStack(spacing: 30) {
            // Icon
            ZStack {
                Circle()
                    .fill(page.color.opacity(0.2))
                    .frame(width: 150, height: 150)

                Image(systemName: page.icon)
                    .font(.system(size: 60))
                    .foregroundColor(page.color)
            }

            // Title
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            // Description
            Text(page.description)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding()
    }

    private func checkPermissionsAndComplete() {
        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completeOnboarding()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        completeOnboarding()
                    } else {
                        showingPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingPermissionAlert = true
        @unknown default:
            showingPermissionAlert = true
        }
    }

    private func completeOnboarding() {
        appState.completeOnboarding()
        appState.currentScreen = .home
    }
}

struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
    let color: Color
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
