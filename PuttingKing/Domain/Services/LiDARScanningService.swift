import Foundation
import ARKit
import Combine

/// Service that manages LiDAR scanning and mesh capture
/// Uses singleton pattern to ensure single source of truth for mesh data
/// Thread-safe: All @Published properties are updated on the main thread
final class LiDARScanningService: NSObject, ObservableObject {
    // Singleton for shared access across the app
    static let shared = LiDARScanningService()

    // Published state for SwiftUI observation (always updated on main thread)
    // NOTE: currentMeshAnchors intentionally NOT @Published — publishing a large
    // [ARMeshAnchor] array 10-30x/sec was duplicating 30-120MB of geometry buffers
    // into main-thread closures, Combine subscribers, and SwiftUI observation.
    // Use getCurrentMeshAnchors() for thread-safe access instead.
    @Published private(set) var scanQualityValue: Float = 0.0
    @Published private(set) var isScanning = false
    @Published private(set) var vertexCount: Int = 0

    // Thread-safe internal storage
    private let meshAnchorsLock = NSLock()
    private var _internalMeshAnchors: [ARMeshAnchor] = []
    private var _internalIsScanning = false

    // AR Session reference
    private weak var arSession: ARSession?

    // Combine publishers for external subscribers
    private let scanQualitySubject = CurrentValueSubject<Float, Never>(0.0)
    var scanQuality: AnyPublisher<Float, Never> {
        scanQualitySubject.eraseToAnyPublisher()
    }

    private override init() {
        super.init()
    }

    /// Check if device supports LiDAR
    static var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// Configure with AR session (call this once when ARView is created)
    func configure(session: ARSession) {
        self.arSession = session
    }

    /// Start LiDAR scanning (begins collecting mesh data from the running AR session)
    func startScanning() throws {
        guard Self.isLiDARSupported else {
            throw ScanError.lidarUnavailable
        }

        guard arSession != nil else {
            throw ScanError.unknown("AR Session not configured")
        }

        // Reset data collection state (thread-safe)
        meshAnchorsLock.lock()
        _internalMeshAnchors = []
        _internalIsScanning = true
        meshAnchorsLock.unlock()

        // Update published scalar metrics on main thread
        DispatchQueue.main.async { [weak self] in
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = true
            self?.scanQualitySubject.send(0)
        }

        print("[LiDAR] Started scanning")
    }

    /// Start LiDAR scanning with full session reset (use only when needed)
    func startScanningWithReset() throws {
        guard Self.isLiDARSupported else {
            throw ScanError.lidarUnavailable
        }

        guard let session = arSession else {
            throw ScanError.unknown("AR Session not configured")
        }

        // Reset state (thread-safe)
        meshAnchorsLock.lock()
        _internalMeshAnchors = []
        _internalIsScanning = true
        meshAnchorsLock.unlock()

        // Update published scalar metrics on main thread
        DispatchQueue.main.async { [weak self] in
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = true
            self?.scanQualitySubject.send(0)
        }

        let config = createConfiguration()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        print("[LiDAR] Started scanning with session reset")
    }

    /// Stop scanning
    func stopScanning() {
        meshAnchorsLock.lock()
        _internalIsScanning = false
        meshAnchorsLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
        }

        print("[LiDAR] Stopped scanning")
    }

    /// Resume scanning without clearing existing data (e.g., after app foreground).
    /// Unlike startScanning(), this preserves all collected mesh anchors.
    func resumeScanning() {
        meshAnchorsLock.lock()
        _internalIsScanning = true
        meshAnchorsLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isScanning = true
        }

        print("[LiDAR] Resumed scanning (preserved existing data)")
    }

    /// Reset scan data
    func reset() {
        meshAnchorsLock.lock()
        _internalMeshAnchors = []
        _internalIsScanning = false
        meshAnchorsLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = false
            self?.scanQualitySubject.send(0)
        }
    }

    /// Get current mesh anchors (thread-safe copy)
    func getCurrentMeshAnchors() -> [ARMeshAnchor] {
        meshAnchorsLock.lock()
        defer { meshAnchorsLock.unlock() }
        return _internalMeshAnchors
    }

    /// Create AR configuration for LiDAR scanning
    private func createConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()

        // Enable scene reconstruction with mesh
        config.sceneReconstruction = .meshWithClassification

        // NOTE: sceneDepth / smoothedSceneDepth intentionally NOT enabled.
        // They allocate ~1MB depth buffers per frame but the app never reads
        // ARFrame.sceneDepth — mesh reconstruction works without them.

        // Enable plane detection for ground reference
        config.planeDetection = [.horizontal]

        // Environment texturing disabled — saves 20-50MB of cubemap probe textures.
        // App uses only SimpleMaterial with solid colors; no reflections needed.
        config.environmentTexturing = .none

        return config
    }

    /// Calculate scan quality based on mesh coverage and density
    private func calculateScanQuality(from anchors: [ARMeshAnchor]) -> Float {
        guard !anchors.isEmpty else { return 0 }

        let totalVertices = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let anchorCount = anchors.count

        // Quality based on vertex count and anchor coverage
        let vertexScore = min(Float(totalVertices) / 30000.0, 1.0)
        let coverageScore = min(Float(anchorCount) / 8.0, 1.0)

        return (vertexScore * 0.7 + coverageScore * 0.3)
    }

    // MARK: - Called by ARSessionManager to forward anchor events
    // These methods may be called from ARSession delegate threads

    func handleAnchorsAdded(_ anchors: [ARAnchor]) {
        meshAnchorsLock.lock()
        guard _internalIsScanning else {
            meshAnchorsLock.unlock()
            return
        }

        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            meshAnchorsLock.unlock()
            return
        }

        _internalMeshAnchors.append(contentsOf: meshAnchors)
        let updatedAnchors = _internalMeshAnchors
        meshAnchorsLock.unlock()

        updateMetricsOnMainThread(with: updatedAnchors)

        print("[LiDAR] Added \(meshAnchors.count) anchors, total: \(updatedAnchors.count)")
    }

    func handleAnchorsUpdated(_ anchors: [ARAnchor]) {
        meshAnchorsLock.lock()
        guard _internalIsScanning else {
            meshAnchorsLock.unlock()
            return
        }

        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else {
            meshAnchorsLock.unlock()
            return
        }

        for updatedAnchor in meshAnchors {
            if let index = _internalMeshAnchors.firstIndex(where: { $0.identifier == updatedAnchor.identifier }) {
                _internalMeshAnchors[index] = updatedAnchor
            } else {
                // Anchor not in internal storage (cleared by reset) — recapture it.
                // ARKit only fires didAdd once per anchor lifetime; subsequent
                // deliveries come through didUpdate, so we must re-add here.
                _internalMeshAnchors.append(updatedAnchor)
            }
        }

        let updatedAnchors = _internalMeshAnchors
        meshAnchorsLock.unlock()

        updateMetricsOnMainThread(with: updatedAnchors)
    }

    func handleAnchorsRemoved(_ anchors: [ARAnchor]) {
        meshAnchorsLock.lock()

        let removedIds = Set(anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier })
        _internalMeshAnchors.removeAll { removedIds.contains($0.identifier) }

        let updatedAnchors = _internalMeshAnchors
        meshAnchorsLock.unlock()

        updateMetricsOnMainThread(with: updatedAnchors)
    }

    /// Update published scalar metrics on main thread for SwiftUI observation.
    /// Only publishes lightweight scalars (vertex count, quality float) — never
    /// the full [ARMeshAnchor] array, which would duplicate 30-120MB of geometry
    /// buffers into the main-thread closure on every anchor update (10-30x/sec).
    private func updateMetricsOnMainThread(with anchors: [ARMeshAnchor]) {
        let newVertexCount = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let newQuality = calculateScanQuality(from: anchors)

        DispatchQueue.main.async { [weak self] in
            self?.vertexCount = newVertexCount
            self?.scanQualityValue = newQuality
            self?.scanQualitySubject.send(newQuality)
        }
    }
}
