import Foundation
import ARKit
import RealityKit
import Combine

/// Manages AR session lifecycle and content
@MainActor
final class ARSessionManager: NSObject, ObservableObject {
    private(set) var arView: ARView?

    // AR Anchors
    private var holeAnchor: AnchorEntity?
    private var ballAnchor: AnchorEntity?
    private var puttingLineAnchor: AnchorEntity?
    private var crosshairAnchor: AnchorEntity?

    // State
    @Published private(set) var isSessionRunning = false
    @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable

    // Reference to shared LiDAR service
    private let lidarService = LiDARScanningService.shared

    // Cancellables
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
    }

    /// Configure AR view
    func configure(arView: ARView) {
        self.arView = arView

        // Basic configuration
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField]

        // Enable environment lighting
        arView.environment.sceneUnderstanding.options = [.receivesLighting]

        // Configure the shared LiDAR service with this session
        lidarService.configure(session: arView.session)

        // Set ourselves as delegate to forward events
        arView.session.delegate = self

        print("[ARSession] Configured")
    }

    /// Shared AR configuration factory — single source of truth (fixes H1 duplication)
    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none // Saves 20-50MB — app uses only SimpleMaterial, no reflections

        // Enable full scene reconstruction with classification, fallback to mesh-only
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        // NOTE: sceneDepth / smoothedSceneDepth intentionally NOT enabled.
        // They allocate ~1MB depth buffers per frame (60fps) but the app never reads
        // ARFrame.sceneDepth — mesh reconstruction uses the depth sensor internally
        // regardless of these frame semantics. Removing them saves significant memory churn.

        return config
    }

    /// Start AR session (without starting LiDAR scanning - that happens when hole is marked)
    func startSession() throws {
        guard let arView = arView else { return }

        guard LiDARScanningService.isLiDARSupported else {
            throw ScanError.lidarUnavailable
        }

        arView.session.run(Self.makeConfiguration())
        isSessionRunning = true

        // Show mesh visualization
        arView.debugOptions.insert(.showSceneUnderstanding)

        print("[ARSession] Started")
    }

    /// Stop AR session
    func stopSession() {
        lidarService.stopScanning()
        arView?.session.pause()
        isSessionRunning = false
        clearAllAnchors()
        print("[ARSession] Stopped")
    }

    /// Reset AR session to recalibrate tracking
    func resetSession() {
        guard let arView = arView else { return }

        // Pause current session
        arView.session.pause()

        // Reset anchors and tracking
        clearAllAnchors()
        lidarService.reset()

        // Run with reset options using shared config factory
        arView.session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true

        print("[ARSession] Reset for recalibration")
    }

    /// Pause AR session
    func pauseSession() {
        arView?.session.pause()
    }

    /// Resume AR session
    func resumeSession() {
        guard let arView = arView else { return }
        arView.session.run(Self.makeConfiguration())
        isSessionRunning = true
        print("[ARSession] Resumed")
    }

    // MARK: - Position Marking

    /// Get world position from screen point
    func getWorldPosition(from screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }

        // Raycast to find ground position
        let results = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal)

        if let firstResult = results.first {
            return firstResult.worldTransform.translation
        }

        // Fallback: use center of screen with estimated distance
        return getEstimatedGroundPosition(from: screenPoint)
    }

    /// Get estimated ground position (fallback)
    private func getEstimatedGroundPosition(from screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return nil }

        let camera = frame.camera
        let cameraTransform = camera.transform

        // Project ray from camera through screen point
        let normalizedPoint = CGPoint(
            x: screenPoint.x / arView.bounds.width,
            y: screenPoint.y / arView.bounds.height
        )

        // Estimate ground at 2m distance
        let distance: Float = 2.0
        let direction = SIMD3<Float>(
            Float(normalizedPoint.x - 0.5) * 2,
            -0.5, // Slightly downward
            -1.0
        )
        let normalizedDirection = simd_normalize(direction)

        let worldDirection = cameraTransform.transformDirection(normalizedDirection)
        let cameraPosition = cameraTransform.translation

        return cameraPosition + worldDirection * distance
    }

    // MARK: - Marker Management

    /// Place hole marker
    func placeHoleMarker(at position: SIMD3<Float>) {
        guard let arView = arView else { return }

        // Remove existing hole marker
        holeAnchor?.removeFromParent()

        // Create new anchor
        let anchor = AnchorEntity(world: position)

        // Create hole visualization (flag pole) - using box as cylinder alternative
        let poleHeight: Float = 0.5
        let poleWidth: Float = 0.01
        let pole = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(poleWidth, poleHeight, poleWidth)),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        pole.position = SIMD3<Float>(0, poleHeight / 2, 0)

        // Flag
        let flag = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.15, 0.1, 0.002)),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        flag.position = SIMD3<Float>(0.08, poleHeight - 0.05, 0)

        // Hole ring
        let ring = createRingEntity(radius: HolePosition.holeRadius, color: .black)
        ring.position = SIMD3<Float>(0, 0.001, 0)

        anchor.addChild(pole)
        anchor.addChild(flag)
        anchor.addChild(ring)

        arView.scene.addAnchor(anchor)
        holeAnchor = anchor

        print("[ARSession] Placed hole marker at \(position)")
    }

    /// Place ball marker
    func placeBallMarker(at position: SIMD3<Float>) {
        guard let arView = arView else { return }

        // Remove existing ball marker
        ballAnchor?.removeFromParent()

        // Create new anchor
        let anchor = AnchorEntity(world: position)

        // Create ball visualization
        let ball = ModelEntity(
            mesh: .generateSphere(radius: BallPosition.ballRadius),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        ball.position = SIMD3<Float>(0, BallPosition.ballRadius, 0)

        anchor.addChild(ball)

        arView.scene.addAnchor(anchor)
        ballAnchor = anchor

        print("[ARSession] Placed ball marker at \(position)")
    }

    /// Show crosshair at screen center
    func showCrosshair(mode: CrosshairMode) {
        guard let arView = arView else { return }

        // Remove existing crosshair
        crosshairAnchor?.removeFromParent()

        // Get position at screen center
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let position = getWorldPosition(from: screenCenter) else { return }

        let anchor = AnchorEntity(world: position)

        // Create crosshair based on mode
        let crosshair: ModelEntity
        switch mode {
        case .hole:
            crosshair = createRingEntity(radius: HolePosition.holeRadius, color: .systemYellow)
        case .ball:
            crosshair = createRingEntity(radius: 0.03, color: .systemGreen)
        }

        anchor.addChild(crosshair)
        arView.scene.addAnchor(anchor)
        crosshairAnchor = anchor
    }

    /// Update crosshair position
    func updateCrosshairPosition() {
        guard let arView = arView,
              let crosshairAnchor = crosshairAnchor else { return }

        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let position = getWorldPosition(from: screenCenter) {
            crosshairAnchor.transform.translation = position
        }
    }

    /// Hide crosshair
    func hideCrosshair() {
        crosshairAnchor?.removeFromParent()
        crosshairAnchor = nil
    }

    // MARK: - Putting Line Display

    /// Display putting line with confidence band and enhanced visualization
    func displayPuttingLine(_ line: PuttingLine, color: AppSettings.LineColor, showConfidenceBand: Bool = true) {
        guard let arView = arView else { return }

        // Remove existing line
        puttingLineAnchor?.removeFromParent()

        guard let startPoint = line.pathPoints.first,
              let endPoint = line.pathPoints.last,
              line.pathPoints.count >= 2 else { return }

        // Create anchor at first point (ball position)
        let startPosition = startPoint.position
        let endPosition = endPoint.position
        let anchor = AnchorEntity(world: startPosition)

        // Create direct line to hole/flag first (rendered behind everything else)
        let directLineEntity = createDirectLineToHole(from: startPosition, to: endPosition)
        anchor.addChild(directLineEntity)

        // Create confidence band (rendered behind main line)
        if showConfidenceBand {
            let confidenceBandEntity = createConfidenceBandEntity(from: line, confidence: line.confidence)
            anchor.addChild(confidenceBandEntity)
        }

        // Create the curved path line with gradient based on velocity
        let lineEntity = createEnhancedPuttingLineEntity(from: line, color: color)
        anchor.addChild(lineEntity)

        // Create aim point marker (where to aim, not where ball goes)
        let aimPointEntity = createEnhancedAimPointEntity(
            at: line.aimPoint - startPosition,
            aimDirection: simd_normalize(line.aimPoint - startPosition),
            confidence: line.confidence
        )
        anchor.addChild(aimPointEntity)

        // Add direction arrows along the path
        let arrowsEntity = createDirectionArrows(from: line, color: color)
        anchor.addChild(arrowsEntity)

        // Add starting ball highlight
        let startHighlight = createStartPositionHighlight()
        anchor.addChild(startHighlight)

        // Add break indicator at apex if there's significant break
        if line.estimatedBreak.totalBreak > 0.05 {
            let breakIndicator = createBreakIndicatorEntity(from: line, color: color)
            anchor.addChild(breakIndicator)
        }

        arView.scene.addAnchor(anchor)
        puttingLineAnchor = anchor
    }

    /// Clear putting line
    func clearPuttingLine() {
        puttingLineAnchor?.removeFromParent()
        puttingLineAnchor = nil
    }

    // MARK: - Mesh Visualization

    /// Show/hide mesh overlay
    func setMeshVisualizationEnabled(_ enabled: Bool) {
        guard let arView = arView else { return }

        if enabled {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    // MARK: - Private Helpers

    /// Create ring entity — M13 fix: reduced from 32 to 16 segments per ring
    /// to halve ModelEntity count. Rings are small; 16 segments is visually sufficient.
    /// Also reuse mesh/material across segments to reduce GPU resource allocations.
    private func createRingEntity(radius: Float, color: UIColor) -> ModelEntity {
        let entity = ModelEntity()
        let segments = 16
        let tubeRadius: Float = 0.004 // Slightly larger to compensate for fewer segments
        let material = SimpleMaterial(color: color, isMetallic: false)
        let segmentMesh = MeshResource.generateSphere(radius: tubeRadius)

        for i in 0..<segments {
            let angle = Float(i) / Float(segments) * .pi * 2
            let x = cos(angle) * radius
            let z = sin(angle) * radius

            let segment = ModelEntity(mesh: segmentMesh, materials: [material])
            segment.position = SIMD3<Float>(x, tubeRadius, z)
            entity.addChild(segment)
        }

        return entity
    }

    /// Create putting line entity from path points - renders smooth curved path on ground
    private func createPuttingLineEntity(from line: PuttingLine, color: AppSettings.LineColor) -> Entity {
        return createEnhancedPuttingLineEntity(from: line, color: color)
    }

    /// Create enhanced putting line with velocity-based coloring and better visibility
    private func createEnhancedPuttingLineEntity(from line: PuttingLine, color: AppSettings.LineColor) -> Entity {
        let entity = Entity()
        let pathPoints = line.pathPoints

        guard pathPoints.count >= 2,
              let firstPoint = pathPoints.first else { return entity }

        let startPosition = firstPoint.position
        let maxSpeed = pathPoints.map { $0.speed }.max() ?? 1.0

        // Create smooth line segments with velocity-based intensity
        // Use Catmull-Rom spline for smooth path visualization (O-3)
        let smoothedPoints = smoothPathPoints(pathPoints)
        
        for i in 0..<(smoothedPoints.count - 1) {
            let startPoint = smoothedPoints[i]
            let endPoint = smoothedPoints[i + 1]

            let start = startPoint.position - startPosition
            let end = endPoint.position - startPosition

            let segmentLength = simd_distance(start, end)
            guard segmentLength > 0.001 else { continue }
            
            // Calculate intensity based on velocity (faster = brighter)
            let avgSpeed = (startPoint.speed + endPoint.speed) / 2
            let speedRatio = avgSpeed / maxSpeed
            let intensity = 0.6 + speedRatio * 0.4 // Range 0.6 - 1.0

            let lineColor = UIColor(
                red: CGFloat(color.color.r * intensity),
                green: CGFloat(color.color.g * intensity),
                blue: CGFloat(color.color.b * intensity),
                alpha: 0.95
            )
            let material = SimpleMaterial(color: lineColor, isMetallic: false)

            let segmentEntity = createHorizontalLineSegment(from: start, to: end, material: material)
            entity.addChild(segmentEntity)
        }

        // Add glow effect spheres along the path for visibility
        let glowColor = UIColor(
            red: CGFloat(color.color.r),
            green: CGFloat(color.color.g),
            blue: CGFloat(color.color.b),
            alpha: 0.7
        )
        let glowMaterial = SimpleMaterial(color: glowColor, isMetallic: false)

        let step = max(1, pathPoints.count / 20) // Place ~20 glow points
        for i in stride(from: 0, to: pathPoints.count, by: step) {
            let pos = pathPoints[i].position - startPosition
            let glow = ModelEntity(
                mesh: .generateSphere(radius: 0.014),
                materials: [glowMaterial]
            )
            glow.position = SIMD3<Float>(pos.x, 0.006, pos.z)
            entity.addChild(glow)
        }

        return entity
    }

    /// Smooth path using Catmull-Rom spline interpolation (Phase 2 Optimization)
    /// L7 fix: lowered guard from 4 to 3 — for exactly 3 points, duplicate the
    /// first/last to create phantom control points so Catmull-Rom can still interpolate.
    private func smoothPathPoints(_ points: [PuttingLine.PathPoint], segmentsPerPoint: Int = 4) -> [PuttingLine.PathPoint] {
        guard points.count >= 3 else { return points }

        // Pad to 4+ points by duplicating endpoints for Catmull-Rom phantom control points
        var padded = points
        if padded.count == 3 {
            padded.insert(padded[0], at: 0)
            padded.append(padded[padded.count - 1])
        }
        
        var smoothed: [PuttingLine.PathPoint] = []

        // Add first point
        smoothed.append(padded[0])

        for i in 0..<(padded.count - 3) {
            let p0 = padded[i]
            let p1 = padded[i + 1]
            let p2 = padded[i + 2]
            let p3 = padded[i + 3]
            
            for t in 1...segmentsPerPoint {
                let tVal = Float(t) / Float(segmentsPerPoint)
                let t2 = tVal * tVal
                let t3 = t2 * tVal
                
                // Catmull-Rom formula
                let q0 = -t3 + 2.0*t2 - tVal
                let q1 = 3.0*t3 - 5.0*t2 + 2.0
                let q2 = -3.0*t3 + 4.0*t2 + tVal
                let q3 = t3 - t2
                
                let pos = 0.5 * (p0.position * q0 + p1.position * q1 + p2.position * q2 + p3.position * q3)
                let vel = 0.5 * (p0.velocity * q0 + p1.velocity * q1 + p2.velocity * q2 + p3.velocity * q3)
                
                let interpolatedPoint = PuttingLine.PathPoint(
                    position: pos,
                    velocity: vel,
                    timestamp: p1.timestamp + Double(tVal) * (p2.timestamp - p1.timestamp)
                )
                
                smoothed.append(interpolatedPoint)
            }
        }
        
        // Add final point
        if padded.count > 3 {
             smoothed.append(padded[padded.count - 1])
        }
        
        return smoothed
    }

    /// Create confidence band showing uncertainty range
    private func createConfidenceBandEntity(from line: PuttingLine, confidence: Float) -> Entity {
        let entity = Entity()
        let pathPoints = line.pathPoints

        guard pathPoints.count >= 2,
              let firstPoint = pathPoints.first else { return entity }

        let startPosition = firstPoint.position

        // Band width inversely proportional to confidence
        // High confidence (0.9) = narrow band, low confidence (0.3) = wide band
        let baseWidth: Float = 0.03 // 3cm at 100% confidence
        let confidenceMultiplier = 1.0 + (1.0 - confidence) * 3.0 // 1x to 4x
        let bandWidth = baseWidth * confidenceMultiplier

        // Semi-transparent band color
        let bandColor = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.2)
        let bandMaterial = SimpleMaterial(color: bandColor, isMetallic: false)

        // Create band segments
        let step = max(1, pathPoints.count / 30)
        for i in stride(from: 0, to: pathPoints.count - step, by: step) {
            let pos = pathPoints[i].position - startPosition

            // Create flat ellipse on ground representing uncertainty
            let band = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(bandWidth * 2, 0.002, bandWidth)),
                materials: [bandMaterial]
            )
            band.position = SIMD3<Float>(pos.x, 0.001, pos.z)

            // Rotate band perpendicular to path direction
            if i + step < pathPoints.count {
                let nextPos = pathPoints[i + step].position - startPosition
                let direction = nextPos - pos
                let angle = atan2(direction.x, direction.z)
                band.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            }

            entity.addChild(band)
        }

        return entity
    }

    /// Create break indicator at the apex of the curve
    private func createBreakIndicatorEntity(from line: PuttingLine, color: AppSettings.LineColor) -> Entity {
        let entity = Entity()
        let pathPoints = line.pathPoints

        guard pathPoints.count >= 3,
              let firstPoint = pathPoints.first else { return entity }

        let startPosition = firstPoint.position
        let breakInfo = line.estimatedBreak

        // Find the point with maximum deviation (apex of break)
        let directLine = simd_normalize(line.aimPoint - startPosition)
        var maxDeviation: Float = 0
        var apexIndex = pathPoints.count / 2

        for (index, point) in pathPoints.enumerated() {
            let relativePos = point.position - startPosition
            let alongLine = simd_dot(relativePos, directLine)
            let projection = directLine * alongLine
            let deviation = simd_length(relativePos - projection)

            if deviation > maxDeviation {
                maxDeviation = deviation
                apexIndex = index
            }
        }

        guard apexIndex > 0 && apexIndex < pathPoints.count else { return entity }

        let apexPos = pathPoints[apexIndex].position - startPosition

        // Create break direction arrow
        let arrowColor: UIColor
        switch breakInfo.breakDirection {
        case .left:
            arrowColor = UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.9) // Cyan for left
        case .right:
            arrowColor = UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 0.9) // Orange for right
        case .straight:
            return entity // No break indicator for straight putts
        }

        let arrowMaterial = SimpleMaterial(color: arrowColor, isMetallic: false)

        // Perpendicular direction (break direction)
        let perpDir: SIMD3<Float>
        if breakInfo.breakDirection == .left {
            perpDir = SIMD3<Float>(-directLine.z, 0, directLine.x)
        } else {
            perpDir = SIMD3<Float>(directLine.z, 0, -directLine.x)
        }

        // Create arrow pointing in break direction
        let arrowBase = SIMD3<Float>(apexPos.x, 0.015, apexPos.z)
        let arrowTip = arrowBase + simd_normalize(perpDir) * 0.04

        // Arrow head
        let tip = ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [arrowMaterial])
        tip.position = arrowTip
        entity.addChild(tip)

        // Arrow shaft
        let shaftLength = simd_distance(arrowBase, arrowTip)
        let shaftMid = (arrowBase + arrowTip) / 2
        let shaft = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.006, 0.006, shaftLength)),
            materials: [arrowMaterial]
        )
        shaft.position = shaftMid
        let shaftAngle = atan2(perpDir.x, perpDir.z)
        shaft.orientation = simd_quatf(angle: shaftAngle, axis: SIMD3<Float>(0, 1, 0))
        entity.addChild(shaft)

        return entity
    }

    /// Create a horizontal line segment on the ground plane (XZ)
    private func createHorizontalLineSegment(from start: SIMD3<Float>, to end: SIMD3<Float>, material: SimpleMaterial) -> ModelEntity {
        // Project points onto ground plane for horizontal line
        let startXZ = SIMD3<Float>(start.x, 0.003, start.z) // Slightly above ground
        let endXZ = SIMD3<Float>(end.x, 0.003, end.z)

        let length = simd_distance(startXZ, endXZ)
        guard length > 0.0001 else {
            return ModelEntity()
        }

        let midpoint = (startXZ + endXZ) / 2

        // Create flat box lying on ground (width along line, thin height, small depth)
        let lineWidth: Float = 0.025 // Width of the line
        let lineHeight: Float = 0.006 // Height (thickness) above ground
        let mesh = MeshResource.generateBox(size: SIMD3<Float>(lineWidth, lineHeight, length))
        let entity = ModelEntity(mesh: mesh, materials: [material])

        // Position at midpoint
        entity.position = midpoint

        // Calculate rotation angle in XZ plane
        let direction = endXZ - startXZ
        let angle = atan2(direction.x, direction.z)
        entity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

        return entity
    }

    /// Create direction arrows along the path to show ball direction
    private func createDirectionArrows(from line: PuttingLine, color: AppSettings.LineColor) -> Entity {
        let entity = Entity()
        let points = line.pathPoints.map { $0.position }

        guard points.count >= 4,
              let firstPoint = points.first else { return entity }

        let startPosition = firstPoint
        let arrowColor = UIColor(
            red: CGFloat(color.color.r),
            green: CGFloat(color.color.g),
            blue: CGFloat(color.color.b),
            alpha: 0.9
        )
        let material = SimpleMaterial(color: arrowColor, isMetallic: false)

        // Place arrows at 25%, 50%, 75% of path
        let positions = [0.25, 0.5, 0.75]

        for fraction in positions {
            let idx = min(Int(Float(points.count - 1) * Float(fraction)), points.count - 2)
            let pos = points[idx] - startPosition
            let nextPos = points[idx + 1] - startPosition

            // Direction of movement
            let dir = simd_normalize(SIMD3<Float>(nextPos.x - pos.x, 0, nextPos.z - pos.z))

            // Create arrow (small triangle pointing in direction)
            let arrow = createArrowEntity(at: pos, direction: dir, material: material)
            entity.addChild(arrow)
        }

        return entity
    }

    /// Create a small arrow entity
    private func createArrowEntity(at position: SIMD3<Float>, direction: SIMD3<Float>, material: SimpleMaterial) -> Entity {
        let entity = Entity()

        // Arrow head - small cone-like shape using 3 small spheres
        let arrowSize: Float = 0.015
        let basePos = SIMD3<Float>(position.x, 0.01, position.z)

        // Center sphere (tip)
        let tip = ModelEntity(mesh: .generateSphere(radius: arrowSize * 0.6), materials: [material])
        tip.position = basePos + direction * arrowSize
        entity.addChild(tip)

        // Side spheres (wings)
        let perpendicular = SIMD3<Float>(-direction.z, 0, direction.x)

        let leftWing = ModelEntity(mesh: .generateSphere(radius: arrowSize * 0.5), materials: [material])
        leftWing.position = basePos + perpendicular * arrowSize * 0.5 - direction * arrowSize * 0.3
        entity.addChild(leftWing)

        let rightWing = ModelEntity(mesh: .generateSphere(radius: arrowSize * 0.5), materials: [material])
        rightWing.position = basePos - perpendicular * arrowSize * 0.5 - direction * arrowSize * 0.3
        entity.addChild(rightWing)

        return entity
    }

    /// Create highlight ring at start position
    private func createStartPositionHighlight() -> Entity {
        let entity = Entity()

        // Pulsing ring at ball position
        let ring = createRingEntity(radius: 0.05, color: .white)
        ring.position = SIMD3<Float>(0, 0.002, 0)
        entity.addChild(ring)

        return entity
    }

    /// Create a direct dashed line from ball to hole/flag
    private func createDirectLineToHole(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Entity {
        let entity = Entity()

        // Calculate relative position (since anchor is at start)
        let endRelative = end - start
        let distance = simd_distance(
            SIMD2<Float>(start.x, start.z),
            SIMD2<Float>(end.x, end.z)
        )

        guard distance > 0.1 else { return entity }

        // Direction in XZ plane
        let direction = simd_normalize(SIMD3<Float>(endRelative.x, 0, endRelative.z))

        // Create dashed line with semi-transparent white segments
        let dashLength: Float = 0.05 // 5cm dashes
        let gapLength: Float = 0.05 // 5cm gaps
        let segmentSpacing = dashLength + gapLength

        let lineColor = UIColor(white: 1.0, alpha: 0.4) // Semi-transparent white
        let material = SimpleMaterial(color: lineColor, isMetallic: false)

        var currentDistance: Float = 0
        while currentDistance < distance - dashLength {
            let segmentStart = direction * currentDistance
            let segmentEnd = direction * min(currentDistance + dashLength, distance)

            let segmentMid = (segmentStart + segmentEnd) / 2
            let segmentLength = simd_distance(segmentStart, segmentEnd)

            // Create flat line segment on ground
            let segment = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.015, 0.003, segmentLength)),
                materials: [material]
            )

            // Position slightly below the main path line
            segment.position = SIMD3<Float>(segmentMid.x, 0.001, segmentMid.z)

            // Rotate to align with direction
            let angle = atan2(direction.x, direction.z)
            segment.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

            entity.addChild(segment)

            currentDistance += segmentSpacing
        }

        return entity
    }

    /// Create aim point entity - simplified, clear target marker
    private func createAimPointEntity(at position: SIMD3<Float>, aimDirection: SIMD3<Float>) -> Entity {
        return createEnhancedAimPointEntity(at: position, aimDirection: aimDirection, confidence: 0.7)
    }

    /// Create enhanced aim point with confidence-based sizing
    private func createEnhancedAimPointEntity(at position: SIMD3<Float>, aimDirection: SIMD3<Float>, confidence: Float) -> Entity {
        let entity = Entity()

        // Project position onto ground plane
        let groundPos = SIMD3<Float>(position.x, 0.005, position.z)

        // Color based on confidence level
        let targetColor: UIColor
        if confidence >= 0.8 {
            targetColor = UIColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1.0) // Green for high confidence
        } else if confidence >= 0.6 {
            targetColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0) // Yellow for medium
        } else {
            targetColor = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0) // Orange for low
        }

        // Main target - size varies with confidence (larger = less certain aim area)
        let baseRadius: Float = 0.03
        let radiusMultiplier = 1.0 + (1.0 - confidence) * 0.5 // 1.0x to 1.5x
        let targetRadius = baseRadius * radiusMultiplier

        let targetBall = ModelEntity(
            mesh: .generateSphere(radius: targetRadius),
            materials: [SimpleMaterial(color: targetColor, isMetallic: false)]
        )
        targetBall.position = groundPos + SIMD3<Float>(0, 0.1, 0)
        entity.addChild(targetBall)

        // Pole underneath the target ball
        let poleHeight: Float = 0.1
        let pole = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.01, poleHeight, 0.01)),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        pole.position = groundPos + SIMD3<Float>(0, poleHeight / 2, 0)
        entity.addChild(pole)

        // Ground ring - size represents aim tolerance
        let ringRadius: Float = 0.04 + (1.0 - confidence) * 0.03
        let groundRing = createRingEntity(radius: ringRadius, color: targetColor)
        groundRing.position = groundPos
        entity.addChild(groundRing)

        // Inner ring for high confidence
        if confidence >= 0.7 {
            let innerRing = createRingEntity(radius: ringRadius * 0.5, color: targetColor)
            innerRing.position = groundPos + SIMD3<Float>(0, 0.001, 0)
            entity.addChild(innerRing)
        }

        // Center dot on ground
        let centerDot = ModelEntity(
            mesh: .generateSphere(radius: 0.01),
            materials: [SimpleMaterial(color: targetColor, isMetallic: false)]
        )
        centerDot.position = groundPos + SIMD3<Float>(0, 0.006, 0)
        entity.addChild(centerDot)

        // Add "AIM HERE" text indicator (using small spheres as guide)
        let guideColor = UIColor.white.withAlphaComponent(0.8)
        let guideMaterial = SimpleMaterial(color: guideColor, isMetallic: false)

        // Create small guide dots leading to aim point
        for i in 1...3 {
            let t = Float(i) * 0.12
            let guidePos = groundPos - SIMD3<Float>(aimDirection.x, 0, aimDirection.z) * t
            let guideDot = ModelEntity(
                mesh: .generateSphere(radius: 0.006),
                materials: [guideMaterial]
            )
            guideDot.position = SIMD3<Float>(guidePos.x, 0.008, guidePos.z)
            entity.addChild(guideDot)
        }

        return entity
    }

    /// Clear all anchors
    private func clearAllAnchors() {
        holeAnchor?.removeFromParent()
        ballAnchor?.removeFromParent()
        puttingLineAnchor?.removeFromParent()
        crosshairAnchor?.removeFromParent()

        holeAnchor = nil
        ballAnchor = nil
        puttingLineAnchor = nil
        crosshairAnchor = nil
    }

    enum CrosshairMode {
        case hole
        case ball
    }
}

// MARK: - ARSessionDelegate
extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Forward to LiDAR service (thread-safe internally)
        lidarService.handleAnchorsAdded(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Forward to LiDAR service (thread-safe internally)
        lidarService.handleAnchorsUpdated(anchors)
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Forward to LiDAR service (thread-safe internally)
        lidarService.handleAnchorsRemoved(anchors)
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        Task { @MainActor in
            self.trackingState = state
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.isSessionRunning = false
            // Pause LiDAR scanning during interruption to prevent data corruption
            self.lidarService.stopScanning()
        }
        print("[ARSession] Session was interrupted")
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.isSessionRunning = true
            // Don't unconditionally restart LiDAR — the ViewModel controls scanning lifecycle.
            // LiDAR will resume when the user takes the next scanning action.
        }
        print("[ARSession] Interruption ended - session resumed")
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("[ARSession] Session failed with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.isSessionRunning = false
            self.trackingState = .notAvailable
        }
    }
}
