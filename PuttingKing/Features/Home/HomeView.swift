import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var stimpmeterSpeed: Float
    @State private var animateGradient = false
    @State private var showStartButton = false

    init() {
        // Initial value — will be kept in sync via .onChange below
        _stimpmeterSpeed = State(initialValue: AppSettings.load().stimpmeterSpeed)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Animated background gradient
                backgroundGradient

                VStack(spacing: 0) {
                    Spacer()

                    // Logo/Title Section
                    logoSection
                        .padding(.bottom, 50)

                    // Green Speed Card
                    greenSpeedCard
                        .padding(.horizontal, 24)
                        .padding(.bottom, 30)

                    // Start Button
                    startButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                    // LiDAR Status
                    lidarStatusBadge
                        .padding(.bottom, 30)

                    Spacer()

                    // Bottom Navigation
                    bottomNavigation
                        .padding(.bottom, 16)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                // Sync slider with latest live settings whenever HomeView appears
                stimpmeterSpeed = appState.settings.stimpmeterSpeed
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    animateGradient = true
                }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.3)) {
                    showStartButton = true
                }
            }
            // Keep local slider in sync if settings change from another screen
            .onChange(of: appState.settings.stimpmeterSpeed) { newValue in
                stimpmeterSpeed = newValue
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                DesignSystem.Colors.background,
                Color.black // Deepen the bottom for contrast
            ]),
            startPoint: animateGradient ? .topLeading : .topTrailing,
            endPoint: animateGradient ? .bottomTrailing : .bottomLeading
        )
        .ignoresSafeArea()
        .overlay(
            // Subtle pattern overlay
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            DesignSystem.Colors.primary.opacity(0.15),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(width: 600, height: 600)
                .offset(x: animateGradient ? 100 : -100, y: -200)
                .blur(radius: 60)
        )
    }

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: 16) {
            // App Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.green.opacity(0.3),
                                Color.green.opacity(0.1)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "flag.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
            }

            // App Name
            Text("PuttingKing")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            // Tagline
            Text("LiDAR Putting Assistant")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .tracking(2)
                .textCase(.uppercase)
        }
    }

    // MARK: - Green Speed Card

    private var greenSpeedCard: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GREEN SPEED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(1.5)

                    Text("Stimpmeter")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                // Speed Value
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", stimpmeterSpeed))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.green)

                    Text("ft")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            // Slider
            VStack(spacing: 8) {
                Slider(value: $stimpmeterSpeed, in: 6...14, step: 0.5)
                    .accentColor(.green)
                    .onChange(of: stimpmeterSpeed) { newValue in
                        var settings = appState.settings
                        settings.stimpmeterSpeed = newValue
                        appState.settings = settings

                        // Haptic feedback
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                    }

                // Speed Labels
                HStack {
                    speedLabel("6", description: "Slow")
                    Spacer()
                    speedLabel("10", description: "Medium")
                    Spacer()
                    speedLabel("14", description: "Fast")
                }
            }

            // Speed Description
            speedDescriptionBadge
        }
        .padding(DesignSystem.Spacing.lg)
        .glassCard(cornerRadius: DesignSystem.CornerRadius.pill)
    }

    private func speedLabel(_ value: String, description: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text(description)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var speedDescriptionBadge: some View {
        let (text, color) = speedDescription
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
        .pillBadge(backgroundColor: color)
    }

    private var speedDescription: (String, Color) {
        switch stimpmeterSpeed {
        case 6..<8: return ("Slow - Practice Green", .blue)
        case 8..<10: return ("Medium - Public Course", .cyan)
        case 10..<12: return ("Fast - Private Club", .green)
        case 12..<14: return ("Very Fast - Tournament", .yellow)
        default: return ("Championship Speed", .orange)
        }
    }

    // MARK: - Start Button

    @State private var isStarting = false

    private var startButton: some View {
        Button(action: {
            guard !isStarting else { return }
            isStarting = true
            
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            
            // Brief loading state for smoother transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                appState.currentScreen = .scanning
                isStarting = false
            }
        }) {
            HStack(spacing: 14) {
                if isStarting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 22, weight: .semibold))
                }

                Text(isStarting ? "Loading..." : "Start Scanning")
                    .font(.system(size: 19, weight: .bold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.2, green: 0.9, blue: 0.4),
                        Color(red: 0.15, green: 0.75, blue: 0.35)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(16)
            .shadow(color: Color.green.opacity(0.4), radius: 20, y: 8)
        }
        .disabled(isStarting)
        .scaleEffect(showStartButton ? 1.0 : 0.8)
        .opacity(showStartButton ? 1.0 : 0.0)
    }

    // MARK: - LiDAR Status

    private var lidarStatusBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: LiDARScanningService.isLiDARSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))

            Text(LiDARScanningService.isLiDARSupported ? "LiDAR Ready" : "LiDAR Not Available")
                .font(.system(size: 13, weight: .medium))
        }
        .pillBadge(
            backgroundColor: LiDARScanningService.isLiDARSupported ? .green : .orange,
            foregroundColor: LiDARScanningService.isLiDARSupported ? .green : .orange
        )
    }

    // MARK: - Bottom Navigation

    private var bottomNavigation: some View {
        HStack(spacing: 60) {
            navButton(icon: "gearshape.fill", title: "Settings") {
                appState.currentScreen = .settings
            }

            navButton(icon: "clock.fill", title: "History") {
                appState.currentScreen = .history
            }
        }
        .padding(.horizontal, 40)
    }

    private func navButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.6))
            .frame(width: 70)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
