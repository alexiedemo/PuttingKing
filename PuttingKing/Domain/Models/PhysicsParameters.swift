import Foundation

/// Grass type affects friction and grain behavior
enum GrassType: String, CaseIterable, Codable {
    case bentGrass = "Bent Grass"
    case bermudaGrass = "Bermuda"

    var grainFactor: Float {
        switch self {
        case .bentGrass: return 0.0 // Minimal grain effect
        case .bermudaGrass: return 0.20 // Significant grain effect
        }
    }

    var description: String {
        switch self {
        case .bentGrass: return "Common in cooler climates, minimal grain"
        case .bermudaGrass: return "Common in warm climates, significant grain"
        }
    }
}

/// Configuration for ball physics simulation
/// Based on research from A.R. Penner, Dave Pelz, and USGA Stimpmeter specifications
struct PhysicsParameters {
    // Ball properties (USGA standard golf ball specifications)
    let ballMass: Float = 0.04593 // kg (max 45.93g per USGA rules)
    let ballRadius: Float = 0.02135 // meters (42.7mm diameter minimum)
    let ballMomentOfInertia: Float // I = (2/5) * m * R^2 for solid sphere

    // Hole properties (USGA specification)
    static let holeRadius: Float = 0.054 // meters (4.25 inches diameter)
    static let holeDepth: Float = 0.102 // meters (4 inches minimum)

    // Hole capture physics (from Bristol University research)
    static let maxCaptureSpeed: Float = 1.63 // m/s - maximum speed for any capture method
    static let simpleCaptureSpeed: Float = 1.31 // m/s - free-fall capture threshold
    static let optimalCaptureSpeed: Float = 0.8 // m/s - ideal entry speed (12" past hole speed)

    // Surface interaction
    var stimpmeterSpeed: Float
    var frictionCoefficient: Float
    var rollingResistance: Float
    var grassType: GrassType

    // Skid-to-roll transition (from Quintic Ball Roll research)
    // Ball achieves true roll after ~20% of putt distance
    let skidFrictionMultiplier: Float = 1.8 // Higher friction during skid phase
    let skidDistanceRatio: Float = 0.20 // 20% of total distance is skidding

    // Environmental
    var gravity: Float = 9.81
    var moistureLevel: Float = 0.0 // 0.0 = dry, 1.0 = very wet

    // Simulation settings
    let timeStep: Float = 0.002 // 2ms (500Hz) - optimized for mobile performance while maintaining accuracy
    let maxSimulationTime: Float = 30.0 // Max putt duration in seconds
    let stoppedThreshold: Float = 0.01 // Ball considered stopped below 1cm/s

    // Rolling deceleration factor (5/7 from moment of inertia for pure rolling)
    static let rollingDecelerationFactor: Float = 5.0 / 7.0

    init(stimpmeterSpeed: Float = 10.0, grassType: GrassType = .bentGrass, moistureLevel: Float = 0.0) {
        self.stimpmeterSpeed = stimpmeterSpeed
        self.grassType = grassType
        self.moistureLevel = moistureLevel
        self.ballMomentOfInertia = (2.0 / 5.0) * ballMass * pow(ballRadius, 2)
        self.frictionCoefficient = Self.calculateFriction(from: stimpmeterSpeed, moisture: moistureLevel)
        self.rollingResistance = Self.calculateRollingResistance(from: stimpmeterSpeed)
    }

    /// Calculate friction coefficient from stimpmeter reading
    /// Based on physics: v0^2 = 2 * mu * g * d, where v0 = 1.83 m/s (stimpmeter initial velocity)
    /// Research data from USGA and professional studies
    static func calculateFriction(from stimpmeter: Float, moisture: Float = 0.0) -> Float {
        // Stimpmeter releases ball at 1.83 m/s (from 20° ramp, 29.4" release point)
        let stimpmeterInitialVelocity: Float = 1.83

        // Convert stimpmeter feet to meters
        let stimpmeterMeters = stimpmeter * 0.3048

        // Derive friction: mu = v0^2 / (2 * g * d)
        // Apply rolling deceleration factor for pure rolling
        var baseFriction = pow(stimpmeterInitialVelocity, 2) / (2 * 9.81 * stimpmeterMeters)
        baseFriction *= rollingDecelerationFactor

        // Apply moisture adjustment (wet greens are slower)
        // Research shows moisture can increase friction by 20-50%
        let moistureAdjustment = 1.0 + moisture * 0.4

        return baseFriction * moistureAdjustment
    }

    /// Calculate rolling resistance from stimpmeter
    static func calculateRollingResistance(from stimpmeter: Float) -> Float {
        let baseFriction = calculateFriction(from: stimpmeter)
        return baseFriction * 0.8
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
    /// Accounts for both skid and roll phases
    func initialSpeedForDistance(_ distance: Float) -> Float {
        // Simplified model: use average deceleration
        // More accurate would be to integrate both phases
        let avgDeceleration = rollingDeceleration()
        return sqrt(2.0 * avgDeceleration * distance)
    }

    /// Calculate initial speed to reach hole with optimal capture speed
    /// Uses Dave Pelz's recommendation of ~12 inches (0.3m) past hole
    func optimalSpeedForDistance(_ distance: Float, pastHoleDistance: Float = 0.23) -> Float {
        // We want the ball to have enough speed to roll pastHoleDistance beyond the hole
        let totalDistance = distance + pastHoleDistance
        return initialSpeedForDistance(totalDistance)
    }

    /// Estimate distance ball will roll from given initial speed on flat green
    func distanceForInitialSpeed(_ speed: Float) -> Float {
        let deceleration = rollingDeceleration()
        guard deceleration > 0 else { return 0 }
        return (speed * speed) / (2.0 * deceleration)
    }

    /// Apply grain effect to friction based on ball direction vs grain direction
    /// grainAngle: 0 = with grain (faster), pi = against grain (slower)
    func frictionWithGrain(ballDirection: Float, grainDirection: Float) -> Float {
        let relativeAngle = ballDirection - grainDirection
        // cos(0) = 1 (with grain, reduce friction), cos(pi) = -1 (against grain, increase friction)
        let grainEffect = 1.0 - grassType.grainFactor * cos(relativeAngle)
        return frictionCoefficient * grainEffect
    }

    /// Check if ball can be captured at given entry speed and offset
    /// Based on Bristol University lip-out research
    func canCaptureAtSpeed(_ speed: Float, entryOffset: Float = 0) -> Bool {
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
