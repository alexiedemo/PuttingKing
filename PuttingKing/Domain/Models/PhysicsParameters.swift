import Foundation
import simd

/// Grass type affects friction and grain behavior
enum GrassType: String, CaseIterable, Codable {
    case bentGrass = "Bent Grass"
    case bermudaGrass = "Bermuda"
    case poaAnnua = "Poa Annua"
    case fescue = "Fescue"
    case ryeGrass = "Ryegrass"

    /// How strongly grain affects friction (speed change with/against grain)
    /// 0.0 = no grain effect, 0.20 = 20% friction change
    var grainFactor: Float {
        switch self {
        case .bentGrass: return 0.05  // Minimal grain, grows upright
        case .bermudaGrass: return 0.20 // Strong grain, grows laterally
        case .poaAnnua: return 0.08   // Moderate grain, patchy growth
        case .fescue: return 0.03     // Very little grain
        case .ryeGrass: return 0.04   // Minimal grain
        }
    }

    /// How strongly grain deflects ball laterally (cross-grain break effect)
    /// Expressed as fraction of gravity force equivalent
    var grainDeflectionFactor: Float {
        switch self {
        case .bentGrass: return 0.02  // Minimal lateral push
        case .bermudaGrass: return 0.12 // Strong lateral deflection
        case .poaAnnua: return 0.05   // Moderate deflection, inconsistent
        case .fescue: return 0.01     // Negligible lateral effect
        case .ryeGrass: return 0.02   // Minimal lateral effect
        }
    }

    /// Base friction multiplier relative to bent grass (stimpmeter baseline)
    /// Values > 1.0 mean inherently slower than bent at same mow height
    var frictionMultiplier: Float {
        switch self {
        case .bentGrass: return 1.0   // Baseline (stimpmeter calibrated on bent)
        case .bermudaGrass: return 1.08 // Slightly more resistance from coarser blades
        case .poaAnnua: return 1.05   // Slightly more than bent, bumpy surface
        case .fescue: return 0.95     // Fine blades, slightly less resistance
        case .ryeGrass: return 1.03   // Similar to bent, slightly coarser
        }
    }

    var description: String {
        switch self {
        case .bentGrass: return "Common in cooler climates, minimal grain"
        case .bermudaGrass: return "Common in warm climates, significant grain"
        case .poaAnnua: return "Common on PGA Tour west coast, moderate grain"
        case .fescue: return "Fine-bladed, fast surfaces, minimal grain"
        case .ryeGrass: return "Overseeding grass, similar to bent"
        }
    }
}

/// Configuration for ball physics simulation
/// Based on research from A.R. Penner, Dave Pelz, and USGA Stimpmeter specifications
struct PhysicsParameters {
    // Ball properties (USGA standard golf ball specifications)
    let ballMass: Float = 0.04593 // kg (max 45.93g per USGA rules)
    static let ballRadius: Float = 0.02135 // meters (42.7mm diameter minimum)
    var ballRadius: Float { Self.ballRadius } // Instance accessor for backward compatibility
    let ballMomentOfInertia: Float // I = (2/5) * m * R^2 for solid sphere

    // Hole properties (USGA specification)
    static let holeRadius: Float = 0.054 // meters (4.25 inches diameter)
    static let holeDepth: Float = 0.102 // meters (4 inches minimum)

    // Hole capture physics (from Bristol University research)
    static let maxCaptureSpeed: Float = 1.63 // m/s - maximum speed for any capture method
    static let simpleCaptureSpeed: Float = 1.31 // m/s - free-fall capture threshold
    static let optimalCaptureSpeed: Float = 0.70 // m/s - ideal entry speed (~17" past hole, Penner/Pelz)

    // Surface interaction
    var stimpmeterSpeed: Float
    var frictionCoefficient: Float
    var rollingResistance: Float
    var grassType: GrassType

    // Skid-to-roll transition (from Quintic Ball Roll research)
    // Ball achieves true roll after ~20% of putt distance
    let skidFrictionMultiplier: Float = 1.8 // Higher friction during skid phase
    let skidDistanceRatio: Float = 0.20 // 20% of total distance is skidding

    // Grain direction (radians, 0 = north, clockwise)
    // Grain grows toward the setting sun or water drainage
    var grainDirection: Float = 0.0

    // Pre-computed grain direction unit vector — avoids sin/cos on every simulation step.
    // frictionWithGrain() and grainDeflectionAcceleration() are called ~1280× per sim;
    // caching the trig result saves ~2400 sin/cos evaluations per simulation.
    let grainDirectionVector: SIMD2<Float>

    // Environmental
    var gravity: Float = 9.81
    var moistureLevel: Float = 0.0 // 0.0 = dry, 1.0 = very wet
    var temperatureCelsius: Float = 20.0 // Ambient temperature
    // Simulation settings
    // 5ms timestep (200Hz) — ball moves 2.5-7.5mm per step at typical putt speeds.
    // RK4 integration handles this accurately; professional simulators use 5-10ms.
    // Previous 2ms timestep caused 60-140ms per simulation (too slow for grid search).
    let timeStep: Float = 0.005
    let maxSimulationTime: Float = 8.0 // Max putt duration — even 30m putts stop within 8s
    let stoppedThreshold: Float = 0.01 // Ball considered stopped below 1cm/s

    // Rolling deceleration factor (5/7 from moment of inertia for pure rolling)
    static let rollingDecelerationFactor: Float = 5.0 / 7.0

    init(stimpmeterSpeed: Float = 10.0, grassType: GrassType = .bentGrass, moistureLevel: Float = 0.0,
         grainDirection: Float = 0.0, temperatureCelsius: Float = 20.0) {
        self.stimpmeterSpeed = stimpmeterSpeed
        self.grassType = grassType
        self.moistureLevel = moistureLevel
        self.temperatureCelsius = temperatureCelsius

        // Validate grain direction — NaN would propagate to all grain calculations
        let safeGrainDirection = grainDirection.isFinite ? grainDirection : 0.0
        self.grainDirection = safeGrainDirection
        self.grainDirectionVector = SIMD2<Float>(sin(safeGrainDirection), cos(safeGrainDirection))

        self.ballMomentOfInertia = (2.0 / 5.0) * ballMass * pow(Self.ballRadius, 2)

        // Calculate base friction with environmental adjustments
        var baseFriction = Self.calculateFriction(from: stimpmeterSpeed, moisture: moistureLevel)

        // Apply grass type friction multiplier (bermuda inherently slower than bent, etc.)
        baseFriction *= grassType.frictionMultiplier

        // Apply temperature adjustment: warmer greens are faster (grass blades more pliable)
        // Research: ~2% speed change per 5°C from baseline 20°C. Clamped to ±15%.
        let tempDelta = temperatureCelsius - 20.0
        let tempFactor = max(0.85, min(1.15, 1.0 - (tempDelta / 5.0) * 0.02))
        baseFriction *= tempFactor

        self.frictionCoefficient = baseFriction
        self.rollingResistance = baseFriction * 0.8
    }

    /// Calculate friction coefficient from stimpmeter reading
    /// Based on physics: v0^2 = 2 * mu * g * d, where v0 = 1.83 m/s (stimpmeter initial velocity)
    /// Research data from USGA and professional studies
    ///
    /// IMPORTANT: This derivation accounts for both the skid and roll phases
    /// that the simulation uses. The ball undergoes:
    ///   1. Skid phase (20% of distance): deceleration = skidMult * μ * g
    ///   2. Roll phase (80% of distance): deceleration = (5/7) * μ * g
    /// Energy balance: v₀² = 2 * μ * g * d * (skidMult * skidRatio + (5/7) * rollRatio)
    static func calculateFriction(from stimpmeter: Float, moisture: Float = 0.0) -> Float {
        // Stimpmeter releases ball at 1.83 m/s (from 20° ramp, 30" release point)
        let v0: Float = 1.83

        // Safety clamp: stimpmeter must be positive to avoid divide-by-zero
        let clampedStimpmeter = max(stimpmeter, 1.0)

        // Convert stimpmeter feet to meters
        let stimpmeterMeters = clampedStimpmeter * 0.3048

        // Derive friction coefficient mu accounting for both simulation phases.
        // The ball skids for 20% of distance at 1.8× friction, then rolls for 80%
        // at (5/7)× friction. This must match the simulation model exactly so that
        // a flat putt at v₀ = 1.83 m/s reproduces the stimpmeter distance.
        //
        // Energy balance: v₀² = 2 * μ * g * d * combinedFactor
        // where combinedFactor = skidMult * skidRatio + (5/7) * rollRatio
        //                      = 1.8 * 0.20 + (5/7) * 0.80
        //                      = 0.36 + 0.5714 = 0.9314
        let skidMult: Float = 1.8       // matches skidFrictionMultiplier
        let skidRatio: Float = 0.20     // matches skidDistanceRatio
        let rollRatio: Float = 0.80     // 1.0 - skidRatio
        let combinedFactor = skidMult * skidRatio + rollingDecelerationFactor * rollRatio

        let baseFriction = (v0 * v0) / (2.0 * 9.81 * stimpmeterMeters * combinedFactor)

        // Apply moisture adjustment (wet greens are slower)
        // Research shows moisture can increase friction by 20-50%. Clamp to [0,1].
        let clampedMoisture = min(max(moisture, 0), 1.0)
        let moistureAdjustment = 1.0 + clampedMoisture * 0.4

        return baseFriction * moistureAdjustment
    }

    /// Calculate rolling resistance from stimpmeter (used for rolling-only scenarios)
    static func calculateRollingResistance(from stimpmeter: Float) -> Float {
        let baseFriction = calculateFriction(from: stimpmeter)
        return baseFriction * 0.8 // Rolling resistance is ~80% of sliding friction
    }

    /// Calculate deceleration during pure rolling phase
    /// a = (5/7) * mu * g for a solid sphere
    func rollingDeceleration(slopeAngle: Float = 0) -> Float {
        return Self.rollingDecelerationFactor * frictionCoefficient * gravity * cos(slopeAngle)
    }

    /// Calculate deceleration during skid phase (initial impact)
    func skidDeceleration() -> Float {
        return frictionCoefficient * skidFrictionMultiplier * gravity
    }

    /// Calculate initial ball speed needed to roll a given distance on flat green
    /// Accounts for both skid and roll phases to match the simulation model exactly.
    func initialSpeedForDistance(_ distance: Float) -> Float {
        // The ball undergoes two phases on flat ground:
        //   Skid (20% of distance):  a_skid = skidFrictionMultiplier * μ * g
        //   Roll (80% of distance):  a_roll = (5/7) * μ * g
        // Energy balance: v₀² = 2 * (a_skid * d_skid + a_roll * d_roll)
        let skidDecel = frictionCoefficient * skidFrictionMultiplier * gravity
        let rollDecel = Self.rollingDecelerationFactor * frictionCoefficient * gravity
        let d_skid = distance * skidDistanceRatio
        let d_roll = distance * (1.0 - skidDistanceRatio)
        return sqrt(2.0 * (skidDecel * d_skid + rollDecel * d_roll))
    }

    /// Calculate initial speed to reach hole with optimal capture speed
    /// Uses Dave Pelz's recommendation of ~12 inches (0.3m) past hole
    func optimalSpeedForDistance(_ distance: Float, pastHoleDistance: Float = 0.23) -> Float {
        // We want the ball to have enough speed to roll pastHoleDistance beyond the hole
        let totalDistance = distance + pastHoleDistance
        return initialSpeedForDistance(totalDistance)
    }

    /// Estimate distance ball will roll from given initial speed on flat green
    /// Accounts for both skid and roll phases to match the simulation model exactly.
    func distanceForInitialSpeed(_ speed: Float) -> Float {
        // Weighted average deceleration matching the two simulation phases:
        //   Skid (20% of distance):  a_skid = skidFrictionMultiplier * μ * g
        //   Roll (80% of distance):  a_roll = (5/7) * μ * g
        // Combined: a_avg = a_skid * skidRatio + a_roll * rollRatio
        let skidDecel = frictionCoefficient * skidFrictionMultiplier * gravity
        let rollDecel = Self.rollingDecelerationFactor * frictionCoefficient * gravity
        let combinedDecel = skidDecel * skidDistanceRatio + rollDecel * (1.0 - skidDistanceRatio)
        guard combinedDecel > 0 else { return 0 }
        return (speed * speed) / (2.0 * combinedDecel)
    }

    /// Apply grain effect to friction based on ball travel direction vs grain direction
    /// With grain = lower friction (faster), against grain = higher friction (slower)
    func frictionWithGrain(ballDirection: SIMD2<Float>) -> Float {
        guard grassType.grainFactor > 0.001 else { return frictionCoefficient }

        let grainDir = grainDirectionVector  // Pre-computed in init — no trig per call
        let ballDirLen = simd_length(ballDirection)
        guard ballDirLen > 0.001 else { return frictionCoefficient }
        let ballDirNorm = ballDirection / ballDirLen

        // dot product: +1 = with grain, -1 = against grain
        let alignment = simd_dot(ballDirNorm, grainDir)
        // With grain (alignment=+1) reduces friction, against grain (alignment=-1) increases
        let grainEffect = 1.0 - grassType.grainFactor * alignment
        return frictionCoefficient * grainEffect
    }

    /// Calculate lateral deflection force from grain (cross-grain push)
    /// Returns a force direction in the XZ plane perpendicular to ball travel.
    /// Deflection is strongest when ball rolls perpendicular to grain, zero when parallel.
    /// The force pushes the ball sideways in the direction the grain "wants" it to go —
    /// i.e., the component of the grain vector perpendicular to the ball's travel direction.
    /// The slower the ball moves, the more grain affects its direction.
    func grainDeflectionAcceleration(ballSpeed: Float, ballDirection: SIMD2<Float>) -> SIMD2<Float> {
        guard grassType.grainDeflectionFactor > 0.001 else { return .zero }
        guard ballSpeed > stoppedThreshold else { return .zero }

        let ballDirLen = simd_length(ballDirection)
        guard ballDirLen > 0.001 else { return .zero }
        let ballDirNorm = ballDirection / ballDirLen

        // Pre-computed grain direction vector — no trig per call
        let grainDir = grainDirectionVector

        // Cross-grain factor: deflection is max when perpendicular, zero when parallel
        // |sin(angle)| = magnitude of cross product in 2D
        let crossGrainFactor = abs(ballDirNorm.x * grainDir.y - ballDirNorm.y * grainDir.x)
        guard crossGrainFactor > 0.001 else { return .zero }

        // Grain deflection is stronger at lower speeds (ball has less momentum)
        let speedFactor = min(1.0, 0.5 / max(ballSpeed, 0.1))

        // Project grain direction perpendicular to ball travel direction.
        // This gives the lateral push direction the grain applies to the ball.
        let alongBall = simd_dot(grainDir, ballDirNorm)
        let perpComponent = grainDir - ballDirNorm * alongBall
        let perpLen = simd_length(perpComponent)
        guard perpLen > 0.001 else { return .zero }
        let perpDir = perpComponent / perpLen

        let magnitude = grassType.grainDeflectionFactor * gravity * speedFactor * crossGrainFactor

        return perpDir * magnitude
    }

    /// Check if ball can be captured at given entry speed and offset
    /// Based on Bristol University lip-out research
    func canCaptureAtSpeed(_ speed: Float, entryOffset: Float = 0) -> Bool {
        // Guard against NaN — NaN comparisons silently return false
        guard speed.isFinite && entryOffset.isFinite else { return false }
        // Speed must be below maximum capture speed
        guard speed < Self.maxCaptureSpeed else { return false }

        // Entry offset must allow ball to enter hole
        let effectiveHoleRadius = Self.holeRadius - ballRadius
        guard entryOffset < effectiveHoleRadius else { return false }

        // Calculate effective capture radius based on speed
        // Higher speed = smaller effective capture zone
        let speedRatio = speed / Self.maxCaptureSpeed
        let effectiveCaptureRadius = effectiveHoleRadius * (1.0 - pow(speedRatio, 2) * 0.5)

        return entryOffset < effectiveCaptureRadius
    }

    /// Calculate probability of holing based on entry conditions
    /// Returns 0 for invalid inputs (NaN, Infinity, negative values)
    func holeProbability(speed: Float, offset: Float, angle: Float) -> Float {
        // Validate inputs are finite and non-negative where appropriate
        guard speed.isFinite && speed >= 0,
              offset.isFinite && offset >= 0,
              angle.isFinite else {
            return 0
        }

        guard canCaptureAtSpeed(speed, entryOffset: offset) else { return 0 }

        // Base probability from entry offset
        let effectiveHoleRadius = Self.holeRadius - ballRadius
        guard effectiveHoleRadius > 0 else { return 0 }
        let offsetScore = max(0, 1.0 - offset / effectiveHoleRadius)

        // Speed penalty (optimal is around 0.8 m/s)
        guard Self.optimalCaptureSpeed > 0 else { return 0 }
        let speedDeviation = abs(speed - Self.optimalCaptureSpeed) / Self.optimalCaptureSpeed
        let speedScore = max(0, 1.0 - speedDeviation * 0.5)

        // Entry angle tolerance (more forgiving at lower speeds)
        let maxAngleTolerance = max(0.01, 0.03 * (1.0 - speed / Self.maxCaptureSpeed))
        let angleScore = max(0, 1.0 - abs(angle) / maxAngleTolerance)

        let result = offsetScore * speedScore * angleScore
        return result.isFinite ? result : 0
    }
}
