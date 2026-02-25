import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings: AppSettings
    @State private var showingResetConfirmation = false

    init() {
        _settings = State(initialValue: AppSettings.load())
    }

    var body: some View {
        NavigationView {
            Form {
                // Green Speed Section
                greenSpeedSection

                // Green Conditions Section
                greenConditionsSection

                // Environmental Section
                environmentalSection

                // Display Section
                displaySection

                // Accessibility Section
                accessibilitySection

                // Feedback Section
                feedbackSection

                // History Section
                historySection

                // About Section
                aboutSection

                // Actions Section
                actionsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        saveSettings()
                        appState.currentScreen = .home
                    }
                }
            }
        }
        // Removed .onChange auto-save — settings save on Done tap only.
        // This prevents double UserDefaults writes (old .onChange + AppState.didSet both triggered save()).
        .alert("Reset Settings", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                settings.reset()
                appState.settings = settings
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will reset all settings to their default values. This cannot be undone.")
        }
    }

    // MARK: - Green Speed Section

    private var greenSpeedSection: some View {
        Section(header: Text("Green Speed")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Stimpmeter")
                    Spacer()
                    Text(String(format: "%.1f", settings.stimpmeterSpeed))
                        .foregroundColor(.green)
                        .fontWeight(.semibold)
                }

                Slider(value: $settings.stimpmeterSpeed, in: 6...14, step: 0.5)
                    .accentColor(.green)
                    .onChange(of: settings.stimpmeterSpeed) { _ in
                        if settings.hapticFeedbackEnabled {
                            HapticManager.shared.selectionChanged()
                        }
                    }

                HStack {
                    Text("6 - Slow")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("14 - Fast")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            // Speed category indicator
            speedCategoryBadge
        }
    }

    private var speedCategoryBadge: some View {
        let (text, color) = speedCategoryInfo
        return HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var speedCategoryInfo: (String, Color) {
        switch settings.stimpmeterSpeed {
        case 6..<8: return ("Slow - Practice Green", .blue)
        case 8..<10: return ("Medium - Public Course", .cyan)
        case 10..<12: return ("Fast - Private Club", .green)
        case 12..<14: return ("Very Fast - Tournament", .yellow)
        default: return ("Championship Speed", .orange)
        }
    }

    // MARK: - Green Conditions Section

    private var greenConditionsSection: some View {
        Section(header: Text("Green Conditions")) {
            Picker("Grass Type", selection: $settings.grassType) {
                ForEach(GrassType.allCases, id: \.self) { grassType in
                    VStack(alignment: .leading) {
                        Text(grassType.rawValue)
                    }
                    .tag(grassType)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(settings.grassType.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Picker("Moisture", selection: $settings.greenCondition) {
                ForEach(GreenCondition.allCases, id: \.self) { condition in
                    Text(condition.rawValue)
                        .tag(condition)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(settings.greenCondition.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Grain direction (important for bermuda and poa)
            if settings.grassType.grainFactor > 0.03 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Grain Direction")
                        Spacer()
                        Text(grainDirectionLabel)
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
                    }

                    Slider(value: $settings.grainDirectionDegrees, in: 0...359, step: 15)
                        .accentColor(.green)

                    HStack {
                        Text("N")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Grain grows toward this direction")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var grainDirectionLabel: String {
        let deg = settings.grainDirectionDegrees
        switch deg {
        case 337.5..<360, 0..<22.5: return "N (\(Int(deg))°)"
        case 22.5..<67.5: return "NE (\(Int(deg))°)"
        case 67.5..<112.5: return "E (\(Int(deg))°)"
        case 112.5..<157.5: return "SE (\(Int(deg))°)"
        case 157.5..<202.5: return "S (\(Int(deg))°)"
        case 202.5..<247.5: return "SW (\(Int(deg))°)"
        case 247.5..<292.5: return "W (\(Int(deg))°)"
        case 292.5..<337.5: return "NW (\(Int(deg))°)"
        default: return "\(Int(deg))°"
        }
    }

    // MARK: - Environmental Section

    private var environmentalSection: some View {
        Section(header: Text("Environment")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    if settings.useMetricUnits {
                        Text(String(format: "%.0f°C", settings.temperatureCelsius))
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                    } else {
                        Text(String(format: "%.0f°F", settings.temperatureCelsius * 9/5 + 32))
                            .foregroundColor(.orange)
                            .fontWeight(.semibold)
                    }
                }

                Slider(value: $settings.temperatureCelsius, in: -10...50, step: 1)
                    .accentColor(.orange)

                HStack {
                    Text("Cold (slower)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Hot (faster)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Altitude")
                    Spacer()
                    if settings.useMetricUnits {
                        Text(String(format: "%.0fm", settings.altitudeMeters))
                            .foregroundColor(.cyan)
                            .fontWeight(.semibold)
                    } else {
                        Text(String(format: "%.0fft", settings.altitudeMeters * 3.281))
                            .foregroundColor(.cyan)
                            .fontWeight(.semibold)
                    }
                }

                Slider(value: $settings.altitudeMeters, in: 0...5000, step: 100)
                    .accentColor(.cyan)

                HStack {
                    Text("Sea Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("High Altitude")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Temperature affects green speed. Warmer conditions make greens faster. Altitude has minimal effect on putting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Display Section

    private var displaySection: some View {
        Section(header: Text("Display")) {
            Toggle("Use Metric Units", isOn: $settings.useMetricUnits)

            Toggle("Show Slope Heatmap", isOn: $settings.showSlopeHeatmap)

            Toggle("Show Confidence Band", isOn: $settings.showConfidenceBand)

            Picker("Line Color", selection: $settings.lineColor) {
                ForEach(AppSettings.LineColor.allCases, id: \.self) { color in
                    HStack {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 20, height: 20)
                        Text(color.displayName)
                    }
                    .tag(color)
                }
            }

            // Color recommendation note
            if settings.lineColor == .yellow {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Best visibility in outdoor conditions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Accessibility Section

    private var accessibilitySection: some View {
        Section(header: Text("Accessibility")) {
            Toggle("High Contrast Mode", isOn: $settings.highContrastMode)

            Picker("Color Blind Mode", selection: $settings.colorblindMode) {
                ForEach(AppSettings.ColorblindMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                        .tag(mode)
                }
            }

            if settings.colorblindMode != .none {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("Colors will be adjusted for better visibility")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        Section(header: Text("Feedback")) {
            Toggle("Haptic Feedback", isOn: $settings.hapticFeedbackEnabled)

            // Demo haptic button — uses pre-prepared generator via HapticManager
            if settings.hapticFeedbackEnabled {
                Button(action: {
                    HapticManager.shared.success()
                }) {
                    HStack {
                        Image(systemName: "hand.tap.fill")
                        Text("Test Haptic")
                    }
                    .foregroundColor(.blue)
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        Section(header: Text("History & Defaults")) {
            Toggle("Auto-Save Scans", isOn: $settings.autoSaveScans)

            HStack {
                Text("Default Course")
                Spacer()
                TextField("Course Name", text: $settings.defaultCourseName)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
            }

            Stepper(value: $settings.defaultHoleNumber, in: 1...18) {
                HStack {
                    Text("Default Hole")
                    Spacer()
                    Text("\(settings.defaultHoleNumber)")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About")) {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Device")
                Spacer()
                Text(LiDARScanningService.isLiDARSupported ? "LiDAR Supported" : "No LiDAR")
                    .foregroundColor(LiDARScanningService.isLiDARSupported ? .green : .orange)
            }

            // Physics info
            VStack(alignment: .leading, spacing: 4) {
                Text("Physics Engine")
                    .font(.subheadline)
                Text("Research-based putting simulation using Penner physics model, RK4 integration, and Quintic Ball Roll skid-to-roll transition.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section {
            Button(action: {
                appState.resetOnboarding()
            }) {
                HStack {
                    Image(systemName: "questionmark.circle")
                    Text("Show Tutorial")
                }
            }

            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset All Settings")
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func saveSettings() {
        appState.settings = settings
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
