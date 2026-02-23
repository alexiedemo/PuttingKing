import Foundation
import SwiftUI
import Combine

/// Global application state
final class AppState: ObservableObject {
    @Published var currentScreen: Screen = .home
    @Published var isOnboardingComplete: Bool {
        didSet {
            UserDefaults.standard.set(isOnboardingComplete, forKey: Keys.onboardingComplete)
        }
    }
    @Published var settings: AppSettings {
        didSet {
            settings.save()
        }
    }

    private enum Keys {
        static let onboardingComplete = "onboardingComplete"
    }

    enum Screen {
        case home
        case onboarding
        case scanning
        case settings
        case history
    }

    init() {
        self.isOnboardingComplete = UserDefaults.standard.bool(forKey: Keys.onboardingComplete)
        self.settings = AppSettings.load()
    }

    func completeOnboarding() {
        isOnboardingComplete = true
    }

    func resetOnboarding() {
        isOnboardingComplete = false
    }
}

/// Green conditions for moisture
enum GreenCondition: String, Codable, CaseIterable {
    case dry = "Dry"
    case normal = "Normal"
    case wet = "Wet (Dew/Rain)"

    var moistureLevel: Float {
        switch self {
        case .dry: return 0.0
        case .normal: return 0.15
        case .wet: return 0.4
        }
    }

    var description: String {
        switch self {
        case .dry: return "Dry conditions - fastest speed"
        case .normal: return "Normal conditions"
        case .wet: return "Wet from dew or rain - slower"
        }
    }
}

/// User preferences with improved persistence and validation
struct AppSettings: Codable, Equatable {
    // Validated properties with clamping
    private var _stimpmeterSpeed: Float = 10.0
    var stimpmeterSpeed: Float {
        get { _stimpmeterSpeed }
        set { _stimpmeterSpeed = max(6.0, min(14.0, newValue)) }
    }

    var useMetricUnits: Bool = true
    var showSlopeHeatmap: Bool = false
    var hapticFeedbackEnabled: Bool = true
    var lineColor: LineColor = .yellow  // Yellow for best outdoor visibility
    var autoSaveScans: Bool = true
    var defaultCourseName: String = ""

    private var _defaultHoleNumber: Int = 1
    var defaultHoleNumber: Int {
        get { _defaultHoleNumber }
        set { _defaultHoleNumber = max(1, min(18, newValue)) }
    }

    // Enhanced physics settings
    var grassType: GrassType = .bentGrass
    var greenCondition: GreenCondition = .normal

    // Grain direction in degrees (0 = North, 90 = East, 180 = South, 270 = West)
    // Grain typically grows toward the setting sun (west) or toward water drainage
    private var _grainDirectionDegrees: Float = 270.0
    var grainDirectionDegrees: Float {
        get { _grainDirectionDegrees }
        set {
            var v = newValue.truncatingRemainder(dividingBy: 360.0)
            if v < 0 { v += 360.0 }
            _grainDirectionDegrees = v
        }
    }

    /// Grain direction in radians for physics calculations
    var grainDirectionRadians: Float {
        _grainDirectionDegrees * .pi / 180.0
    }

    // Environmental conditions
    private var _temperatureCelsius: Float = 20.0
    var temperatureCelsius: Float {
        get { _temperatureCelsius }
        set { _temperatureCelsius = max(-10.0, min(50.0, newValue)) }
    }

    private var _altitudeMeters: Float = 0.0
    var altitudeMeters: Float {
        get { _altitudeMeters }
        set { _altitudeMeters = max(0.0, min(5000.0, newValue)) }
    }

    // Accessibility settings
    var highContrastMode: Bool = false
    var showConfidenceBand: Bool = true
    var colorblindMode: ColorblindMode = .none

    // Custom coding keys to handle private storage
    private enum CodingKeys: String, CodingKey {
        case _stimpmeterSpeed = "stimpmeterSpeed"
        case useMetricUnits, showSlopeHeatmap, hapticFeedbackEnabled
        case lineColor, autoSaveScans, defaultCourseName
        case _defaultHoleNumber = "defaultHoleNumber"
        case grassType, greenCondition
        case _grainDirectionDegrees = "grainDirectionDegrees"
        case _temperatureCelsius = "temperatureCelsius"
        case _altitudeMeters = "altitudeMeters"
        case highContrastMode, showConfidenceBand, colorblindMode
    }

    enum LineColor: String, Codable, CaseIterable {
        case green, blue, yellow, white, orange

        var color: (r: Float, g: Float, b: Float) {
            switch self {
            case .green: return (0.0, 0.8, 0.4)  // Accessible green
            case .blue: return (0.3, 0.5, 1.0)
            case .yellow: return (1.0, 0.84, 0.0) // High visibility yellow
            case .white: return (1.0, 1.0, 1.0)
            case .orange: return (1.0, 0.6, 0.0)  // High contrast orange
            }
        }

        var swiftUIColor: Color {
            switch self {
            case .green: return Color(red: 0.0, green: 0.8, blue: 0.4)
            case .blue: return Color(red: 0.3, green: 0.5, blue: 1.0)
            case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.0)
            case .white: return .white
            case .orange: return .orange
            }
        }

        var displayName: String {
            switch self {
            case .green: return "Green"
            case .blue: return "Blue"
            case .yellow: return "Yellow (Recommended)"
            case .white: return "White"
            case .orange: return "Orange"
            }
        }
    }

    enum ColorblindMode: String, Codable, CaseIterable {
        case none = "None"
        case deuteranopia = "Red-Green (Deuteranopia)"
        case protanopia = "Red-Green (Protanopia)"
        case tritanopia = "Blue-Yellow (Tritanopia)"

        var adjustsColors: Bool {
            self != .none
        }
    }

    private static let storageKey = "appSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    mutating func reset() {
        self = AppSettings()
        save()
    }
}

