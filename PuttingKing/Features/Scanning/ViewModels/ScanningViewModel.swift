import Foundation
import ARKit
import Combine
import UIKit

/// ViewModel for the scanning flow
@MainActor
final class ScanningViewModel: ObservableObject {
    // Published state
    @Published private(set) var scanState: ScanSession.ScanState = .idle
    @Published private(set) var scanProgress: Float = 0.0
    @Published private(set) var scanQuality: ScanQuality = .unknown
    @Published private(set) var holePosition: HolePosition?
    @Published private(set) var ballPosition: BallPosition?
    @Published private(set) var puttingLine: PuttingLine?
    @Published private(set) var isAnalyzing: Bool = false
    @Published private(set) var error: ScanError?
    @Published private(set) var vertexCount: Int = 0
    @Published var courseName: String = ""
    @Published var holeNumber: Int = 1
    @Published var showSavePrompt: Bool = false

    // Settings
    let settings: AppSettings

    // Services (injected)
    private let lidarService: LiDARScanningService
    private let meshService: MeshReconstructionServiceProtocol
    private let slopeService: SlopeAnalysisServiceProtocol
    private let pathService: PathSimulationServiceProtocol
    private let breakService: BreakCalculationServiceProtocol
    private let historyService: ScanHistoryService?

    // Session
    private var currentSession: ScanSession?
    private var cancellables = Set<AnyCancellable>()
    private var analysisTask: Task<Void, Never>?

    enum ScanQuality: String {
        case unknown = "Unknown"
        case poor = "Poor"
        case fair = "Fair"
        case good = "Good"
        case excellent = "Excellent"

        var color: String {
            switch self {
            case .unknown, .poor: return "red"
            case .fair: return "orange"
            case .good: return "yellow"
            case .excellent: return "green"
            }
        }
    }

    /// Instruction text based on current state
    var instructionText: String {
        scanState.instruction
    }

    /// Whether the mark ball button should be enabled
    /// Must have sufficient scan data matching `hasMinimumData` requirements
    /// Lowered to 15% / 500 vertices based on user feedback (Phase 5)
    var canMarkBall: Bool {
        scanState.canMarkBall && scanProgress >= 0.15 && vertexCount >= 500
    }

    /// Convenience initializer using DI container
    convenience init(settings: AppSettings) {
        self.init(
            settings: settings,
            lidarService: LiDARScanningService.shared,
            meshService: MeshReconstructionService(),
            slopeService: SlopeAnalysisService(),
            pathService: nil,
            breakService: nil,
            historyService: nil
        )
    }

    /// Full initializer with dependency injection
    init(
        settings: AppSettings,
        lidarService: LiDARScanningService,
        meshService: MeshReconstructionServiceProtocol,
        slopeService: SlopeAnalysisServiceProtocol,
        pathService: PathSimulationServiceProtocol?,
        breakService: BreakCalculationServiceProtocol?,
        historyService: ScanHistoryService?
    ) {
        self.settings = settings
        self.lidarService = lidarService
        self.meshService = meshService
        self.slopeService = slopeService

        // Create path service if not provided
        if let pathService = pathService {
            self.pathService = pathService
        } else {
            self.pathService = PathSimulationService(slopeAnalysisService: slopeService)
        }

        // Create break service if not provided
        if let breakService = breakService {
            self.breakService = breakService
        } else {
            self.breakService = BreakCalculationService(
                pathSimulationService: self.pathService,
                slopeAnalysisService: slopeService
            )
        }

        self.historyService = historyService

        // Load defaults from settings
        self.courseName = settings.defaultCourseName
        self.holeNumber = settings.defaultHoleNumber

        setupSubscriptions()
    }

    private func setupSubscriptions() {
        // Subscribe to LiDAR service state changes
        // Use dropFirst to skip initial value during setup and throttle to reduce UI updates
        lidarService.$vertexCount
            .dropFirst()
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                guard let self = self else { return }
                // Only update if we're actually scanning
                guard self.scanState == .scanningGreen else { return }
                self.vertexCount = count
                self.updateScanProgress()
                
                // Play subtle texture haptic (Phase 2 Optimization)
                TactileFeedbackService.shared.playScanTexture()
            }
            .store(in: &cancellables)

        lidarService.$scanQualityValue
            .dropFirst()
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .map { quality -> ScanQuality in
                switch quality {
                case 0..<0.25: return .poor
                case 0.25..<0.5: return .fair
                case 0.5..<0.75: return .good
                default: return .excellent
                }
            }
            .sink { [weak self] quality in
                guard let self = self else { return }
                // Only update if we're actually scanning
                guard self.scanState == .scanningGreen else { return }
                self.scanQuality = quality
            }
            .store(in: &cancellables)
    }

    private func updateScanProgress() {
        // Target: 15,000 vertices for minimum viable scan
        let targetVertices: Float = 15000
        scanProgress = min(Float(vertexCount) / targetVertices, 1.0)
        currentSession?.scanProgress = scanProgress

        print("[ViewModel] Scan progress: \(Int(scanProgress * 100))%, vertices: \(vertexCount)")
    }

    // MARK: - User Actions

    /// Start a new scanning session
    func startNewScan() {
        currentSession = ScanSession(
            id: UUID(),
            state: .markingHole
        )

        scanState = .markingHole
        scanProgress = 0
        holePosition = nil
        ballPosition = nil
        puttingLine = nil
        error = nil
        vertexCount = 0
        isAnalyzing = false

        // Reset LiDAR service
        lidarService.reset()

        print("[ViewModel] Started new scan - state: markingHole")
    }

    /// Mark the hole position
    func markHole(at position: SIMD3<Float>) {
        guard scanState == .markingHole else {
            print("[ViewModel] Cannot mark hole - wrong state: \(scanState)")
            return
        }

        let hole = HolePosition(worldPosition: position)
        holePosition = hole
        currentSession?.holePosition = hole

        // Transition to scanning state
        scanState = .scanningGreen
        currentSession?.state = .scanningGreen

        // Start LiDAR scanning
        do {
            try lidarService.startScanning()
            print("[ViewModel] Marked hole at \(position), started scanning")
        } catch {
            print("[ViewModel] Failed to start scanning: \(error)")
            self.error = .lidarUnavailable
            scanState = .error(.lidarUnavailable)
        }
    }

    /// Mark the ball position
    func markBall(at position: SIMD3<Float>) {
        guard scanState == .scanningGreen else {
            print("[ViewModel] Cannot mark ball - wrong state: \(scanState)")
            return
        }

        let ball = BallPosition(worldPosition: position)
        ballPosition = ball
        currentSession?.ballPosition = ball

        // Transition to marking ball (confirmation) state
        scanState = .markingBall
        currentSession?.state = .markingBall

        print("[ViewModel] Marked ball at \(position)")
    }

    /// Confirm ball position and start analysis
    func confirmBallPosition() {
        guard scanState == .markingBall,
              let ball = ballPosition,
              let hole = holePosition else {
            print("[ViewModel] Cannot confirm - missing data")
            return
        }

        // Cancel any existing analysis task
        analysisTask?.cancel()

        // Stop LiDAR scanning
        lidarService.stopScanning()

        scanState = .analyzing
        isAnalyzing = true
        currentSession?.state = .analyzing

        print("[ViewModel] Starting analysis with \(lidarService.currentMeshAnchors.count) anchors")

        analysisTask = Task {
            // Timeout protection: 15 seconds max
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.analyzeAndCalculateLine(ball: ball, hole: hole)
                }
                group.addTask { @MainActor in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if self.isAnalyzing {
                        self.error = .unknown("Analysis timed out. Try scanning again.")
                        self.scanState = .error(.unknown("Analysis timed out. Try scanning again."))
                        self.isAnalyzing = false
                    }
                }
                // Wait for whichever completes first
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// Start a new putt (keep hole, clear ball)
    func startNewPutt() {
        ballPosition = nil
        puttingLine = nil

        // Reset scanning
        lidarService.reset()
        scanProgress = 0
        vertexCount = 0
        isAnalyzing = false

        scanState = .scanningGreen
        currentSession?.state = .scanningGreen
        currentSession?.ballPosition = nil

        // Restart scanning
        do {
            try lidarService.startScanning()
            print("[ViewModel] Started new putt")
        } catch {
            print("[ViewModel] Failed to restart scanning: \(error)")
        }
    }

    /// Cancel current scan
    func cancel() {
        // Cancel any running analysis task
        analysisTask?.cancel()
        analysisTask = nil

        lidarService.stopScanning()
        lidarService.reset()

        scanState = .idle
        currentSession = nil
        holePosition = nil
        ballPosition = nil
        puttingLine = nil
        error = nil
        vertexCount = 0
        scanProgress = 0
        isAnalyzing = false

        print("[ViewModel] Cancelled scan")
    }

    deinit {
        // Clean up subscriptions and tasks
        analysisTask?.cancel()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    /// Redo hole marking
    func redoHole() {
        holePosition = nil
        currentSession?.holePosition = nil

        // Stop and reset scanning
        lidarService.stopScanning()
        lidarService.reset()
        scanProgress = 0
        vertexCount = 0
        isAnalyzing = false

        scanState = .markingHole
        currentSession?.state = .markingHole

        print("[ViewModel] Redoing hole marking")
    }

    /// Save the current scan to history
    func saveScan() {
        guard let line = puttingLine else {
            print("[ViewModel] No putting line to save")
            return
        }

        let name = courseName.isEmpty ? "Unknown Course" : courseName

        let result = historyService?.saveScan(
            from: line,
            courseName: name,
            holeNumber: holeNumber,
            stimpmeterSpeed: settings.stimpmeterSpeed
        )

        switch result {
        case .success:
            print("[ViewModel] Saved scan to history: \(name) Hole \(holeNumber)")
            // Increment hole number for next scan
            holeNumber += 1
            if holeNumber > 18 {
                holeNumber = 1
            }
        case .failure(let error):
            print("[ViewModel] Save failed: \(error.localizedDescription)")
            // Note: Could add a @Published saveError property here for UI display
        case .none:
            print("[ViewModel] No history service configured")
        }
    }

    /// Prompt user to save if auto-save is disabled
    func promptSaveIfNeeded() {
        if settings.autoSaveScans {
            saveScan()
        } else {
            showSavePrompt = true
        }
    }

    // MARK: - Private Methods

    private func analyzeAndCalculateLine(ball: BallPosition, hole: HolePosition) async {
        let meshAnchors = lidarService.getCurrentMeshAnchors()

        guard !meshAnchors.isEmpty else {
            self.error = .insufficientData
            self.scanState = .error(.insufficientData)
            self.isAnalyzing = false
            return
        }

        do {
            print("[ViewModel] Reconstructing surface from \(meshAnchors.count) anchors")

            // Step 1: Reconstruct surface from mesh data
            let surface = try await meshService.reconstructSurface(from: meshAnchors)

            // Check cancellation after each expensive async step to respect timeout
            guard !Task.isCancelled else { return }

            print("[ViewModel] Surface reconstructed: \(surface.vertexCount) vertices")

            // Step 2: Filter to relevant area (between ball and hole + buffer)
            let center = (ball.worldPosition + hole.worldPosition) / 2
            let distance = ball.worldPosition.horizontalDistance(to: hole.worldPosition)
            let radius = distance / 2 + 1.0 // 1m buffer

            let filteredSurface = meshService.filterGreenMesh(from: surface, around: center, radius: radius)

            print("[ViewModel] Filtered surface: \(filteredSurface.vertexCount) vertices")

            // Step 3: Analyze slopes
            let slopeData = slopeService.analyzeSurface(filteredSurface)

            guard !Task.isCancelled else { return }

            print("[ViewModel] Slope analyzed: avg \(slopeData.averageSlope)%")

            // Step 4: Calculate optimal putting line with enhanced physics
            let parameters = PhysicsParameters(
                stimpmeterSpeed: settings.stimpmeterSpeed,
                grassType: settings.grassType,
                moistureLevel: settings.greenCondition.moistureLevel,
                grainDirection: settings.grainDirectionRadians,
                temperatureCelsius: settings.temperatureCelsius,
                altitudeMeters: settings.altitudeMeters
            )

            if let line = await breakService.findOptimalPutt(
                from: ball,
                to: hole,
                on: filteredSurface,
                with: slopeData,
                parameters: parameters
            ) {
                // Check cancellation before updating state — timeout may have fired
                guard !Task.isCancelled else { return }

                self.puttingLine = line
                self.scanState = .displayingResult
                self.currentSession?.state = .displayingResult
                self.isAnalyzing = false
                print("[ViewModel] Analysis complete - showing result")

                // Auto-save if enabled
                if self.settings.autoSaveScans && self.historyService != nil {
                    self.saveScan()
                }
            } else {
                guard !Task.isCancelled else { return }

                // Create a simple straight line if optimal path not found
                self.puttingLine = createSimpleLine(from: ball, to: hole)
                self.scanState = .displayingResult
                self.currentSession?.state = .displayingResult
                self.isAnalyzing = false
                print("[ViewModel] Using simple straight line")

                // Auto-save if enabled
                if self.settings.autoSaveScans && self.historyService != nil {
                    self.saveScan()
                }
            }
        } catch let scanError as ScanError {
            guard !Task.isCancelled else { return }
            self.error = scanError
            self.scanState = .error(scanError)
            self.isAnalyzing = false
            print("[ViewModel] Analysis error: \(scanError.message)")
        } catch {
            guard !Task.isCancelled else { return }
            self.error = .unknown(error.localizedDescription)
            self.scanState = .error(.unknown(error.localizedDescription))
            self.isAnalyzing = false
            print("[ViewModel] Analysis error: \(error)")
        }
    }

    /// Create a simple straight line when optimal path calculation fails
    private func createSimpleLine(from ball: BallPosition, to hole: HolePosition) -> PuttingLine {
        let distance = ball.worldPosition.horizontalDistance(to: hole.worldPosition)
        let diff = hole.worldPosition - ball.worldPosition
        let direction = simd_length(diff) > 0.001 ? simd_normalize(diff) : SIMD3<Float>(1, 0, 0)

        // Create path points
        var pathPoints: [PuttingLine.PathPoint] = []
        let numPoints = 20

        for i in 0...numPoints {
            let t = Float(i) / Float(numPoints)
            let position = ball.worldPosition + direction * distance * t
            let speed = max(0.1, 1.0 - t)

            pathPoints.append(PuttingLine.PathPoint(
                position: position,
                velocity: direction * speed,
                timestamp: TimeInterval(t * 2.0)
            ))
        }

        return PuttingLine(
            id: UUID(),
            pathPoints: pathPoints,
            aimPoint: hole.worldPosition,
            estimatedBreak: .straight,
            recommendedSpeed: .moderate,
            confidence: 0.25, // Low confidence - fallback straight line
            distance: distance
        )
    }
}

// MARK: - Services (Colocated for build simplicity)

import CoreHaptics

/// Service for advanced haptic feedback
final class TactileFeedbackService {
    static let shared = TactileFeedbackService()
    
    private var hapticEngine: CHHapticEngine?
    private var isEnabled: Bool = true
    
    private init() {
        prepareHapticEngine()
    }
    
    /// Play a subtle texture haptic simulating surface scanning
    func playScanTexture() {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = hapticEngine else { return }
        
        do {
            // Restart if needed
            try? engine.start()
            
            // Create a low-rumble continuous texture
            let rumble = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                ],
                relativeTime: 0,
                duration: 0.15
            )
            
            // Overlay random transient ticks for "digital" feel
            var events = [rumble]
            
            for i in 0..<3 {
                let tick = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: 0.04 * Double(i + 1)
                )
                events.append(tick)
            }
            
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[TactileFeedback] Failed to play scan texture: \(error)")
        }
    }
    
    private func prepareHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
            
            hapticEngine?.resetHandler = { [weak self] in
                try? self?.hapticEngine?.start()
            }
        } catch {
            print("Tactile engine creation error: \(error)")
        }
    }
}
