import Foundation
import simd

/// Ball motion phase during putting
enum BallMotionPhase {
    case skidding // Initial phase after impact - partial slide
    case rolling  // Pure rolling phase
    case stopped  // Ball has come to rest
}

/// Detailed result of a putt simulation
struct SimulationResult {
    let path: [PuttingLine.PathPoint]
    let finalPosition: SIMD3<Float>
    let holesOut: Bool
    let reason: StopReason
    let entrySpeed: Float? // Speed when entering hole (if holed)
    let entryOffset: Float? // Distance from hole center (if holed)
    let closestApproach: Float // Closest distance to hole during simulation
    let lipOutOccurred: Bool // True if ball approached but didn't drop

    enum StopReason {
        case holed
        case stopped
        case outOfBounds
        case timeout
        case lipOut // Ball approached hole but was too fast
    }

    init(path: [PuttingLine.PathPoint],
         finalPosition: SIMD3<Float>,
         holesOut: Bool,
         reason: StopReason,
         entrySpeed: Float? = nil,
         entryOffset: Float? = nil,
         closestApproach: Float = .infinity,
         lipOutOccurred: Bool = false) {
        self.path = path
        self.finalPosition = finalPosition
        self.holesOut = holesOut
        self.reason = reason
        self.entrySpeed = entrySpeed
        self.entryOffset = entryOffset
        self.closestApproach = closestApproach
        self.lipOutOccurred = lipOutOccurred
    }
}

/// Protocol for path simulation
protocol PathSimulationServiceProtocol {
    func simulatePutt(
        from ball: BallPosition,
        toward direction: SIMD3<Float>,
        initialSpeed: Float,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        holePosition: HolePosition,
        parameters: PhysicsParameters
    ) -> SimulationResult
}

/// Pre-binned spatial grid for fast surface height lookups.
/// Replaces O(n) brute-force vertex search with O(~k) where k ≈ vertices-per-cell.
private struct SurfaceHeightCache {
    private let cellSize: Float = 0.15  // ~15cm cells
    private let invCellSize: Float
    private var grid: [UInt64: [Int]] = [:]  // packed cell key → vertex indices
    private let vertices: [SIMD3<Float>]

    init(vertices: [SIMD3<Float>]) {
        self.vertices = vertices
        self.invCellSize = 1.0 / 0.15
        grid.reserveCapacity(vertices.count / 4)
        for (i, v) in vertices.enumerated() {
            let key = Self.cellKey(x: v.x, z: v.z, inv: invCellSize)
            grid[key, default: []].append(i)
        }
    }

    private static func cellKey(x: Float, z: Float, inv: Float) -> UInt64 {
        let cx = Int32(floor(x * inv))
        let cz = Int32(floor(z * inv))
        return UInt64(bitPattern: Int64(cx)) &<< 32 | UInt64(UInt32(bitPattern: cz))
    }

    /// Fast height lookup — searches only nearby grid cells
    func projectHeight(at position: SIMD3<Float>, fallbackY: Float) -> Float {
        let cx = Int32(floor(position.x * invCellSize))
        let cz = Int32(floor(position.z * invCellSize))
        let searchRadius: Float = 0.5
        let searchRadiusSq = searchRadius * searchRadius

        var totalWeight: Float = 0
        var weightedY: Float = 0

        // Search 7×7 cells (±3) to fully cover 0.5m radius with 0.15m cells
        // (±3 cells = ±0.45m from cell center, plus half-cell = 0.525m coverage)
        for dx: Int32 in -3...3 {
            for dz: Int32 in -3...3 {
                let keyCx = cx + dx
                let keyCz = cz + dz
                let key = UInt64(bitPattern: Int64(keyCx)) &<< 32 | UInt64(UInt32(bitPattern: keyCz))
                guard let indices = grid[key] else { continue }
                for i in indices {
                    let vertex = vertices[i]
                    let ddx = position.x - vertex.x
                    let ddz = position.z - vertex.z
                    let distSq = ddx * ddx + ddz * ddz
                    if distSq < searchRadiusSq {
                        let weight = 1.0 / max(sqrt(distSq), 0.01)
                        weightedY += vertex.y * weight
                        totalWeight += weight
                    }
                }
            }
        }

        return totalWeight > 0 ? weightedY / totalWeight : fallbackY
    }
}

/// Service that simulates ball physics on the green
/// Implements research-based physics from Penner, Pelz, and Quintic Ball Roll studies
final class PathSimulationService: PathSimulationServiceProtocol {
    private let slopeAnalysisService: SlopeAnalysisServiceProtocol

    init(slopeAnalysisService: SlopeAnalysisServiceProtocol) {
        self.slopeAnalysisService = slopeAnalysisService
    }

    /// Simulate a putt with given initial conditions using research-based physics
    func simulatePutt(
        from ball: BallPosition,
        toward direction: SIMD3<Float>,
        initialSpeed: Float,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        holePosition: HolePosition,
        parameters: PhysicsParameters
    ) -> SimulationResult {
        // Initial state — guard against zero-direction NaN (L3 fix)
        var position = ball.worldPosition
        let dirLen = simd_length(direction)
        let safeDirection = dirLen > 0.001 ? direction / dirLen : SIMD3<Float>(1, 0, 0)
        var velocity = safeDirection * initialSpeed
        var path: [PuttingLine.PathPoint] = []
        var time: Float = 0

        // Calculate estimated putt distance for skid phase
        let estimatedDistance = parameters.distanceForInitialSpeed(initialSpeed)
        let skidDistance = estimatedDistance * parameters.skidDistanceRatio
        var distanceTraveled: Float = 0
        var motionPhase: BallMotionPhase = .skidding
        var stepCount: Int = 0  // Integer counter for path recording — avoids float modulo drift

        // Track closest approach for lip-out detection
        var closestApproach: Float = .infinity
        var wasInHoleZone = false

        let dt = parameters.timeStep
        let g = parameters.gravity

        // Build spatial cache once — O(n) construction, then O(1) lookups per timestep
        let heightCache = SurfaceHeightCache(vertices: surface.vertices)

        // Record starting point
        path.append(PuttingLine.PathPoint(
            position: position,
            velocity: velocity,
            timestamp: TimeInterval(time)
        ))

        var previousPosition = position

        // Simulation loop
        while time < parameters.maxSimulationTime {
            // Get slope at current position
            guard let slopeSample = slopeAnalysisService.getSlopeAt(position: position, in: slopeData) else {
                return SimulationResult(
                    path: path,
                    finalPosition: position,
                    holesOut: false,
                    reason: .outOfBounds,
                    closestApproach: closestApproach
                )
            }

            let speed = simd_length(velocity)

            // Check if ball stopped
            if speed < parameters.stoppedThreshold {
                // Check if stopped near hole (could be lip-out)
                let finalHoleDistance = position.horizontalDistance(to: holePosition.worldPosition)
                let lipOut = wasInHoleZone && finalHoleDistance > PhysicsParameters.holeRadius

                return SimulationResult(
                    path: path,
                    finalPosition: position,
                    holesOut: false,
                    reason: lipOut ? .lipOut : .stopped,
                    closestApproach: closestApproach,
                    lipOutOccurred: lipOut
                )
            }

            // Check hole approach with sub-timestep interpolation
            let holeDistance = position.horizontalDistance(to: holePosition.worldPosition)
            closestApproach = min(closestApproach, holeDistance)

            // Track if ball entered hole zone
            let effectiveHoleRadius = PhysicsParameters.holeRadius - parameters.ballRadius
            if holeDistance < effectiveHoleRadius {
                wasInHoleZone = true

                // Check capture conditions using research-based physics
                if parameters.canCaptureAtSpeed(speed, entryOffset: holeDistance) {
                    // Sub-timestep interpolation to find exact entry point
                    let entryResult = findExactHoleEntry(
                        from: previousPosition,
                        to: position,
                        velocity: velocity,
                        holePosition: holePosition.worldPosition,
                        parameters: parameters,
                        dt: dt
                    )

                    // Ball is captured - ensure the path ends at the hole
                    // Add the exact hole position as the final point
                    path.append(PuttingLine.PathPoint(
                        position: holePosition.worldPosition,
                        velocity: .zero,
                        timestamp: TimeInterval(time)
                    ))

                    return SimulationResult(
                        path: path,
                        finalPosition: holePosition.worldPosition,
                        holesOut: true,
                        reason: .holed,
                        entrySpeed: speed,
                        entryOffset: entryResult.offset,
                        closestApproach: closestApproach
                    )
                }
                // Ball passed through but was too fast - potential lip-out
            }

            // Update motion phase based on distance traveled
            if motionPhase == .skidding && distanceTraveled > skidDistance {
                motionPhase = .rolling
            }

            // Calculate forces based on motion phase
            let gradient = slopeSample.gradient
            let slopeAngle = slopeSample.slopeAngle

            // Gravity component along slope (in XZ plane)
            // During pure rolling, translational acceleration = (5/7)*g*sin(θ)
            // because friction must provide torque for rolling constraint.
            // During skidding, full g*sin(θ) applies (ball slides freely).
            var gravityForce = SIMD3<Float>.zero
            let gradientLength = simd_length(gradient)
            if gradientLength > 0.001 {
                let gradientDir = gradient / gradientLength
                let slopeAccel: Float
                switch motionPhase {
                case .skidding:
                    slopeAccel = g * sin(slopeAngle)
                case .rolling:
                    slopeAccel = PhysicsParameters.rollingDecelerationFactor * g * sin(slopeAngle)
                case .stopped:
                    slopeAccel = 0
                }
                gravityForce = SIMD3<Float>(
                    slopeAccel * gradientDir.x,
                    0,
                    slopeAccel * gradientDir.y
                )
            }

            // Friction force based on motion phase, adjusted for grain direction
            // Ball travel direction in XZ plane for grain calculation (needed outside if-block)
            let ballDir2D = SIMD2<Float>(velocity.x, velocity.z)
            var frictionForce = SIMD3<Float>.zero
            if speed > 0.001 {
                let velocityDir = simd_normalize(velocity)
                let frictionMagnitude: Float
                let grainAdjustedFriction = parameters.frictionWithGrain(ballDirection: ballDir2D)

                switch motionPhase {
                case .skidding:
                    // Higher friction during skid phase, grain-adjusted
                    frictionMagnitude = grainAdjustedFriction * parameters.skidFrictionMultiplier * g * cos(slopeAngle)
                case .rolling:
                    // Pure rolling friction with (5/7) factor, grain-adjusted
                    frictionMagnitude = PhysicsParameters.rollingDecelerationFactor * grainAdjustedFriction * g * cos(slopeAngle)
                case .stopped:
                    frictionMagnitude = 0
                }

                frictionForce = -velocityDir * frictionMagnitude
            }

            // Grain lateral deflection force (cross-grain push)
            var grainForce = SIMD3<Float>.zero
            let grainAccel = parameters.grainDeflectionAcceleration(ballSpeed: speed, ballDirection: ballDir2D)
            if simd_length(grainAccel) > 0.0001 {
                grainForce = SIMD3<Float>(grainAccel.x, 0, grainAccel.y)
            }

            // Total acceleration = gravity + friction + grain deflection
            let acceleration = gravityForce + frictionForce + grainForce

            // RK4 Integration — reuse slopeSample for all sub-steps (slope is constant
            // over the ~2mm step distance; only velocity-dependent forces are re-evaluated)
            let (newPosition, newVelocity) = rk4Integrate(
                position: position,
                velocity: velocity,
                acceleration: acceleration,
                slopeSample: slopeSample,
                dt: dt,
                parameters: parameters,
                motionPhase: motionPhase,
                heightCache: heightCache
            )

            // Track distance traveled
            distanceTraveled += simd_distance(position, newPosition)

            previousPosition = position
            position = newPosition
            velocity = newVelocity
            time += dt
            stepCount += 1

            // Early termination: if ball has traveled > 2× the hole distance
            // and is now moving away from the hole, it won't come back (flat/mild greens)
            let holeDir = holePosition.worldPosition - position
            let movingAway = simd_dot(velocity, holeDir) < 0
            if distanceTraveled > estimatedDistance * 1.5 && movingAway && !wasInHoleZone {
                return SimulationResult(
                    path: path,
                    finalPosition: position,
                    holesOut: false,
                    reason: .stopped,
                    closestApproach: closestApproach
                )
            }

            // Record path point every 5 steps for smoother visualization near hole (L2 fix)
            if stepCount % 5 == 0 {
                path.append(PuttingLine.PathPoint(
                    position: position,
                    velocity: velocity,
                    timestamp: TimeInterval(time)
                ))
            }
        }

        return SimulationResult(
            path: path,
            finalPosition: position,
            holesOut: false,
            reason: .timeout,
            closestApproach: closestApproach,
            lipOutOccurred: wasInHoleZone
        )
    }

    // MARK: - Hole Entry Detection

    /// Find exact hole entry point using binary search interpolation
    private func findExactHoleEntry(
        from startPos: SIMD3<Float>,
        to endPos: SIMD3<Float>,
        velocity: SIMD3<Float>,
        holePosition: SIMD3<Float>,
        parameters: PhysicsParameters,
        dt: Float
    ) -> (time: Float, offset: Float) {
        let effectiveHoleRadius = PhysicsParameters.holeRadius - parameters.ballRadius

        // Binary search for exact crossing time
        var tLow: Float = 0
        var tHigh = dt
        let precision: Float = 0.0001 // 0.1ms precision

        while (tHigh - tLow) > precision {
            let tMid = (tLow + tHigh) / 2
            let midPos = startPos + (endPos - startPos) * (tMid / dt)
            let dist = midPos.horizontalDistance(to: holePosition)

            if dist < effectiveHoleRadius {
                tHigh = tMid
            } else {
                tLow = tMid
            }
        }

        let entryPos = startPos + (endPos - startPos) * (tLow / dt)
        let entryOffset = entryPos.horizontalDistance(to: holePosition)

        return (tLow, entryOffset)
    }

    // MARK: - Private Methods

    /// RK4 integration step — reuses the same slope sample for all sub-steps
    /// (slope is constant over ~2mm step distances; only velocity-dependent forces change)
    /// This eliminates 3 spatial hash lookups per step, giving ~3x speedup.
    private func rk4Integrate(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        acceleration: SIMD3<Float>,
        slopeSample: SlopeData.GradientSample,
        dt: Float,
        parameters: PhysicsParameters,
        motionPhase: BallMotionPhase,
        heightCache: SurfaceHeightCache
    ) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        // k1: derivatives at current state
        let k1v = acceleration * dt
        let k1p = velocity * dt

        // k2: derivatives at midpoint using k1, re-evaluate velocity-dependent forces
        let midVel1 = velocity + k1v / 2
        let a2 = calculateAccelerationFromSample(slopeSample: slopeSample, velocity: midVel1, parameters: parameters, motionPhase: motionPhase)
        let k2v = a2 * dt
        let k2p = midVel1 * dt

        // k3: derivatives at midpoint using k2
        let midVel2 = velocity + k2v / 2
        let a3 = calculateAccelerationFromSample(slopeSample: slopeSample, velocity: midVel2, parameters: parameters, motionPhase: motionPhase)
        let k3v = a3 * dt
        let k3p = midVel2 * dt

        // k4: derivatives at endpoint using k3
        let endVel = velocity + k3v
        let a4 = calculateAccelerationFromSample(slopeSample: slopeSample, velocity: endVel, parameters: parameters, motionPhase: motionPhase)
        let k4v = a4 * dt
        let k4p = endVel * dt

        // Weighted average (RK4 formula)
        let velSum = k1v + k2v * 2 + k3v * 2 + k4v
        var newVelocity = velocity + velSum / 6

        let posSum = k1p + k2p * 2 + k3p * 2 + k4p
        var newPosition = position + posSum / 6

        // Keep ball on surface (project Y coordinate via spatial cache)
        newPosition.y = heightCache.projectHeight(at: newPosition, fallbackY: newPosition.y)

        // Ensure velocity stays in XZ plane (ball rolls, doesn't bounce)
        newVelocity.y = 0

        // Prevent friction-only reversal (friction never reverses a ball)
        // But allow gravity on slopes to legitimately reverse ball direction (uphill rollback)
        let speed = simd_length(newVelocity)
        if speed > 0 && simd_dot(newVelocity, velocity) < 0 {
            // H5 fix: recompute acceleration at current slope with new velocity
            let newAcceleration = calculateAccelerationFromSample(slopeSample: slopeSample, velocity: newVelocity, parameters: parameters, motionPhase: motionPhase)
            let gravityComponent = simd_dot(newAcceleration, simd_normalize(newVelocity))
            if gravityComponent <= 0 {
                // No slope force in the reversal direction — pure friction reversal, stop ball
                newVelocity = .zero
            }
            // Otherwise: slope is pulling ball back downhill, allow the reversal
        }

        return (newPosition, newVelocity)
    }

    /// Calculate acceleration using a pre-fetched slope sample (avoids spatial hash lookup)
    /// Re-evaluates velocity-dependent forces (friction direction, grain) at each RK4 sub-step.
    private func calculateAccelerationFromSample(
        slopeSample: SlopeData.GradientSample,
        velocity: SIMD3<Float>,
        parameters: PhysicsParameters,
        motionPhase: BallMotionPhase
    ) -> SIMD3<Float> {
        let speed = simd_length(velocity)
        let gradient = slopeSample.gradient
        let slopeAngle = slopeSample.slopeAngle
        let g = parameters.gravity

        // Gravity component along slope
        var gravityForce = SIMD3<Float>.zero
        let gradientLength = simd_length(gradient)
        if gradientLength > 0.001 {
            let gradientDir = gradient / gradientLength
            let slopeAccel: Float
            switch motionPhase {
            case .skidding:
                slopeAccel = g * sin(slopeAngle)
            case .rolling:
                slopeAccel = PhysicsParameters.rollingDecelerationFactor * g * sin(slopeAngle)
            case .stopped:
                slopeAccel = 0
            }
            gravityForce = SIMD3<Float>(
                slopeAccel * gradientDir.x,
                0,
                slopeAccel * gradientDir.y
            )
        }

        // Ball travel direction in XZ plane for grain calculations
        let ballDir2D = SIMD2<Float>(velocity.x, velocity.z)

        // Friction force with grain direction adjustment
        var frictionForce = SIMD3<Float>.zero
        if speed > 0.001 {
            let velocityDir = simd_normalize(velocity)
            let grainAdjustedFriction = parameters.frictionWithGrain(ballDirection: ballDir2D)
            let frictionMagnitude: Float

            switch motionPhase {
            case .skidding:
                frictionMagnitude = grainAdjustedFriction * parameters.skidFrictionMultiplier * g * cos(slopeAngle)
            case .rolling:
                frictionMagnitude = PhysicsParameters.rollingDecelerationFactor * grainAdjustedFriction * g * cos(slopeAngle)
            case .stopped:
                frictionMagnitude = 0
            }

            frictionForce = -velocityDir * frictionMagnitude
        }

        // Grain lateral deflection (cross-grain push)
        var grainForce = SIMD3<Float>.zero
        let grainAccel = parameters.grainDeflectionAcceleration(ballSpeed: speed, ballDirection: ballDir2D)
        if simd_length(grainAccel) > 0.0001 {
            grainForce = SIMD3<Float>(grainAccel.x, 0, grainAccel.y)
        }

        return gravityForce + frictionForce + grainForce
    }
}
