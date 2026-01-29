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
    @Published private(set) var currentMeshAnchors: [ARMeshAnchor] = []
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
    private let meshUpdatesSubject = PassthroughSubject<[ARMeshAnchor], Never>()
    var meshUpdates: AnyPublisher<[ARMeshAnchor], Never> {
        meshUpdatesSubject.eraseToAnyPublisher()
    }

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

        // Update published properties on main thread
        DispatchQueue.main.async { [weak self] in
            self?.currentMeshAnchors = []
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = true
        }

        scanQualitySubject.send(0)

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

        // Update published properties on main thread
        DispatchQueue.main.async { [weak self] in
            self?.currentMeshAnchors = []
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = true
        }

        scanQualitySubject.send(0)

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

    /// Reset scan data
    func reset() {
        meshAnchorsLock.lock()
        _internalMeshAnchors = []
        _internalIsScanning = false
        meshAnchorsLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.currentMeshAnchors = []
            self?.vertexCount = 0
            self?.scanQualityValue = 0
            self?.isScanning = false
        }

        scanQualitySubject.send(0)
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

        // Enable scene depth for additional accuracy
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        // Enable plane detection for ground reference
        config.planeDetection = [.horizontal]

        // Environment texturing for visual quality
        config.environmentTexturing = .automatic

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

    /// Update published properties on main thread for SwiftUI observation
    private func updateMetricsOnMainThread(with anchors: [ARMeshAnchor]) {
        let newVertexCount = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let newQuality = calculateScanQuality(from: anchors)

        DispatchQueue.main.async { [weak self] in
            self?.currentMeshAnchors = anchors
            self?.vertexCount = newVertexCount
            self?.scanQualityValue = newQuality
        }

        scanQualitySubject.send(newQuality)
        meshUpdatesSubject.send(anchors)
    }
}
