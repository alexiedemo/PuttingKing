import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var stimpmeterSpeed: Float
    @State private var animateGradient = false
    @State private var showStartButton = false
    /// Debounce timer — saves settings 0.3s after the last slider change
    /// instead of on every tick (was 60 writes/sec, now ~3/sec max)
    @State private var saveTimer: Timer?

    init() {
        // Initial value — will be kept in sync via .onChange below
        _stimpmeterSpeed = State(initialValue: AppSettings.load().stimpmeterSpeed)
    }

    var body: some View {
        // Bug 3 fix: Removed unnecessary NavigationView wrapper — HomeView has
        // no toolbar items and was hiding the nav bar. ContentView handles navigation.
        ZStack {
            // Animated background gradient
            backgroundGradient

            VStack(spacing: 0) {
                Spacer()

                // Logo/Title Section
                logoSection
                    .padding(.bottom, DesignSystem.Spacing.xxl)

                // Green Speed Card
                greenSpeedCard
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.xl)

                // Start Button
                startButton
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.lg)

                // LiDAR Status
                lidarStatusBadge
                    .padding(.bottom, DesignSystem.Spacing.xl)

                Spacer()

                // Bottom Navigation
                bottomNavigation
                    .padding(.bottom, DesignSystem.Spacing.md)
            }
        }
        .onAppear {
            // Sync slider with latest live settings whenever HomeView appears
            stimpmeterSpeed = appState.settings.stimpmeterSpeed
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                animateGradient = true
            }
            withAnimation(DesignSystem.Springs.gentle.delay(0.3)) {
                showStartButton = true
            }
        }
        // Keep local slider in sync if settings change from another screen
        .onChange(of: appState.settings.stimpmeterSpeed) { newValue in
            stimpmeterSpeed = newValue
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
                .drawingGroup() // Bug 14 fix: rasterize to Metal texture for better performance
        )
    }

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // App Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                DesignSystem.Colors.primary.opacity(DesignSystem.Opacity.subtle),
                                DesignSystem.Colors.primary.opacity(0.1)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "flag.fill")
                    .font(.system(size: 44))
                    .foregroundColor(DesignSystem.Colors.primary)
            }

            // App Name
            Text("PuttingKing")
                .font(DesignSystem.Typography.display)
                .foregroundColor(.white)

            // Tagline
            Text("LiDAR Putting Assistant")
                .font(DesignSystem.Typography.footnote)
                .foregroundColor(.white.opacity(DesignSystem.Opacity.medium))
                .tracking(2)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PuttingKing, LiDAR Putting Assistant")
    }

    // MARK: - Green Speed Card

    private var greenSpeedCard: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GREEN SPEED")
                        .font(DesignSystem.Typography.small)
                        .foregroundColor(.white.opacity(DesignSystem.Opacity.medium))
                        .tracking(1.5)

                    Text("Stimpmeter")
                        .font(DesignSystem.Typography.subheadline)
                        .foregroundColor(.white)
                }

                Spacer()

                // Speed Value
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", stimpmeterSpeed))
                        .font(DesignSystem.Typography.displayValue)
                        .foregroundColor(DesignSystem.Colors.primary)

                    Text("ft")
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(.white.opacity(DesignSystem.Opacity.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Green speed: \(String(format: "%.1f", stimpmeterSpeed)) feet")
            }

            // Slider
            VStack(spacing: DesignSystem.Spacing.xs) {
                Slider(value: $stimpmeterSpeed, in: 6...14, step: 0.5)
                    .accentColor(DesignSystem.Colors.primary)
                    .accessibilityLabel("Green speed, Stimpmeter")
                    .accessibilityValue("\(String(format: "%.1f", stimpmeterSpeed)) feet")
                    .onChange(of: stimpmeterSpeed) { newValue in
                        // L12 fix: use centralized HapticManager (pre-prepared generator)
                        // and respect the haptic enabled setting
                        if appState.settings.hapticFeedbackEnabled {
                            HapticManager.shared.selectionChanged()
                        }

                        // Debounce the settings write — persist 0.3s after last slider change
                        // instead of on every tick (was 60 UserDefaults writes/sec).
                        // Local @State stimpmeterSpeed keeps the UI responsive immediately.
                        saveTimer?.invalidate()
                        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                            Task { @MainActor in
                                var settings = appState.settings
                                settings.stimpmeterSpeed = newValue
                                appState.settings = settings  // didSet triggers save()
                            }
                        }
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
                .font(DesignSystem.Typography.caption)
                .foregroundColor(.white.opacity(DesignSystem.Opacity.strong))
            Text(description)
                .font(DesignSystem.Typography.micro)
                .foregroundColor(.white.opacity(DesignSystem.Opacity.subtle))
        }
    }

    private var speedDescriptionBadge: some View {
        let (text, color) = speedDescription
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(.white.opacity(DesignSystem.Opacity.strong))
        }
        .pillBadge(backgroundColor: color)
    }

    private var speedDescription: (String, Color) {
        switch stimpmeterSpeed {
        case 6..<8: return ("Slow - Practice Green", DesignSystem.Colors.info)
        case 8..<10: return ("Medium - Public Course", .cyan)
        case 10..<12: return ("Fast - Private Club", DesignSystem.Colors.primary)
        case 12..<14: return ("Very Fast - Tournament", .yellow)
        default: return ("Championship Speed", DesignSystem.Colors.warning)
        }
    }

    // MARK: - Start Button

    @State private var isStarting = false

    private var startButton: some View {
        Button(action: {
            guard !isStarting else { return }
            isStarting = true

            HapticManager.shared.mediumImpact()

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
            .cornerRadius(DesignSystem.CornerRadius.large)
            .shadow(color: Color.green.opacity(0.4), radius: 20, y: 8)
        }
        .disabled(isStarting)
        .scaleEffect(showStartButton ? 1.0 : 0.8)
        .opacity(showStartButton ? 1.0 : 0.0)
        .accessibilityLabel(isStarting ? "Loading" : "Start Scanning")
        .accessibilityHint("Double tap to begin putting analysis")
    }

    // MARK: - LiDAR Status

    private var lidarStatusBadge: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: LiDARScanningService.isLiDARSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(DesignSystem.Typography.body)

            Text(LiDARScanningService.isLiDARSupported ? "LiDAR Ready" : "LiDAR Not Available")
                .font(.system(size: 13, weight: .medium))
        }
        .pillBadge(
            backgroundColor: LiDARScanningService.isLiDARSupported ? DesignSystem.Colors.success : DesignSystem.Colors.warning,
            foregroundColor: LiDARScanningService.isLiDARSupported ? DesignSystem.Colors.success : DesignSystem.Colors.warning
        )
        .accessibilityLabel("LiDAR status")
        .accessibilityValue(LiDARScanningService.isLiDARSupported ? "Ready" : "Not available")
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
            VStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 22))

                Text(title)
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundColor(.white.opacity(DesignSystem.Opacity.medium))
            .frame(width: 70)
        }
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to open \(title.lowercased())")
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
