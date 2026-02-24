import Foundation
import SwiftUI

/// Dependency Injection Container using thread-safe lazy initialization
final class DependencyContainer: @unchecked Sendable {
    static let shared = DependencyContainer()

    // Thread-safety lock for lazy initialization
    private let lock = NSLock()

    private init() {}

    // MARK: - Private Storage

    private var _meshReconstructionService: MeshReconstructionServiceProtocol?
    private var _slopeAnalysisService: SlopeAnalysisServiceProtocol?
    private var _pathSimulationService: PathSimulationServiceProtocol?
    private var _breakCalculationService: BreakCalculationServiceProtocol?
    private var _scanHistoryService: ScanHistoryService?

    // MARK: - Thread-Safe Service Accessors

    var lidarScanningService: LiDARScanningService {
        // Singleton is already thread-safe
        LiDARScanningService.shared
    }

    var meshReconstructionService: MeshReconstructionServiceProtocol {
        lock.lock()
        defer { lock.unlock() }

        if let service = _meshReconstructionService {
            return service
        }

        let service = MeshReconstructionService()
        _meshReconstructionService = service
        return service
    }

    var slopeAnalysisService: SlopeAnalysisServiceProtocol {
        lock.lock()
        defer { lock.unlock() }

        if let service = _slopeAnalysisService {
            return service
        }

        let service = SlopeAnalysisService()
        _slopeAnalysisService = service
        return service
    }

    var pathSimulationService: PathSimulationServiceProtocol {
        // Resolve dependency BEFORE acquiring lock to avoid lock inversion
        // (slopeAnalysisService acquisition requires a lock too)
        let slopeService = slopeAnalysisService
        
        lock.lock()
        defer { lock.unlock() }
        
        if let service = _pathSimulationService {
            return service
        }
        
        let service = PathSimulationService(slopeAnalysisService: slopeService)
        _pathSimulationService = service
        return service
    }

    var breakCalculationService: BreakCalculationServiceProtocol {
        // Resolve dependencies BEFORE acquiring lock to avoid lock inversion
        let pathService = pathSimulationService
        let slopeService = slopeAnalysisService
        
        lock.lock()
        defer { lock.unlock() }
        
        if let service = _breakCalculationService {
            return service
        }
        
        let service = BreakCalculationService(
            pathSimulationService: pathService,
            slopeAnalysisService: slopeService
        )
        _breakCalculationService = service
        return service
    }

    @MainActor var scanHistoryService: ScanHistoryService {
        lock.lock()
        defer { lock.unlock() }

        if let service = _scanHistoryService {
            return service
        }

        let service = ScanHistoryService(persistenceController: PersistenceController.shared)
        _scanHistoryService = service
        return service
    }

    // MARK: - Persistence

    var persistenceController: PersistenceController {
        // Singleton is already thread-safe
        PersistenceController.shared
    }

    // MARK: - Factory Methods

    @MainActor
    func makeScanningViewModel(settings: AppSettings) -> ScanningViewModel {
        ScanningViewModel(
            settings: settings,
            lidarService: lidarScanningService,
            meshService: meshReconstructionService,
            slopeService: slopeAnalysisService,
            pathService: pathSimulationService,
            breakService: breakCalculationService,
            historyService: scanHistoryService
        )
    }

    @MainActor func makeARSessionManager() -> ARSessionManager {
        ARSessionManager()
    }

    // MARK: - Testing Support

    /// Reset all services (for testing purposes only)
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }

        _meshReconstructionService = nil
        _slopeAnalysisService = nil
        _pathSimulationService = nil
        _breakCalculationService = nil
        _scanHistoryService = nil
    }
}

/// Property wrapper for injecting dependencies
@propertyWrapper
struct Injected<T> {
    private let keyPath: KeyPath<DependencyContainer, T>

    var wrappedValue: T {
        DependencyContainer.shared[keyPath: keyPath]
    }

    init(_ keyPath: KeyPath<DependencyContainer, T>) {
        self.keyPath = keyPath
    }
}

// MARK: - Design System (Colocated for build simplicity)

/// Centralized design system for consistent styling across the app
enum DesignSystem {
    
    // MARK: - Colors
    
    enum Colors {
        // Primary palette
        static let primary = Color.green
        static let secondary = Color.white.opacity(0.8)
        static let background = Color(red: 0.02, green: 0.12, blue: 0.08)
        
        // Semantic colors
        static let success = Color.green
        static let warning = Color.orange
        static let error = Color.red
        static let info = Color.blue
        
        // Confidence levels
        static func confidence(_ level: Float) -> Color {
            if level >= 0.8 { return .green }
            if level >= 0.6 { return .yellow }
            return .orange
        }
        
        // Break direction colors
        static let breakLeft = Color.cyan
        static let breakRight = Color.orange
        static let breakStraight = Color.green
    }
    
    // MARK: - Typography
    
    enum Typography {
        static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 14, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let micro = Font.system(size: 10, weight: .semibold)
    }
    
    // MARK: - Spacing
    
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    
    // MARK: - Corner Radius
    
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let pill: CGFloat = 20
        static let circle: CGFloat = 999
    }
    
    // MARK: - Shadows
    
    enum Shadows {
        static let subtle = Color.black.opacity(0.1)
        static let medium = Color.black.opacity(0.2)
        static let strong = Color.black.opacity(0.3)
    }
}

// MARK: - View Modifiers

/// Glass morphism card style
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.large
    
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.9))
            .cornerRadius(cornerRadius)
    }
}

/// Primary button style with gradient
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = DesignSystem.Colors.primary
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignSystem.Typography.headline)
            .foregroundColor(.white)
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.8)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(DesignSystem.CornerRadius.medium)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Secondary/ghost button style
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignSystem.Typography.body)
            .foregroundColor(.white)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(.ultraThinMaterial.opacity(0.6))
            .cornerRadius(DesignSystem.CornerRadius.medium)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Pill badge modifier for status indicators
struct PillBadgeModifier: ViewModifier {
    var backgroundColor: Color
    var foregroundColor: Color = .white
    
    func body(content: Content) -> some View {
        content
            .font(DesignSystem.Typography.caption)
            .foregroundColor(foregroundColor)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(backgroundColor.opacity(0.2))
            .background(.ultraThinMaterial)
            .cornerRadius(DesignSystem.CornerRadius.pill)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.pill)
                    .stroke(backgroundColor.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - View Extensions

extension View {
    func glassCard(cornerRadius: CGFloat = DesignSystem.CornerRadius.large) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
    
    func pillBadge(backgroundColor: Color, foregroundColor: Color = .white) -> some View {
        modifier(PillBadgeModifier(backgroundColor: backgroundColor, foregroundColor: foregroundColor))
    }
}
