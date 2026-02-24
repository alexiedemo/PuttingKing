import Foundation
import simd

/// Putting strategy for different risk tolerances
enum PuttingStrategy: String, CaseIterable {
    case conservative = "Conservative" // Die at the hole, less break
    case optimal = "Optimal"           // Best chance to make
    case aggressive = "Aggressive"     // Firm, less break but riskier
}

/// Protocol for break calculation
protocol BreakCalculationServiceProtocol {
    func findOptimalPutt(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters
    ) async -> PuttingLine?

    /// Find multiple putting lines for different strategies
    func findPuttingLines(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters
    ) async -> [PuttingStrategy: PuttingLine]

    func calculateBreak(for path: [PuttingLine.PathPoint], directLine: SIMD3<Float>) -> PuttingLine.BreakInfo
}

/// Service that calculates optimal putting line with break
/// Uses AimPoint-style grid search with multiple trajectory analysis
final class BreakCalculationService: BreakCalculationServiceProtocol {
    private let pathSimulationService: PathSimulationServiceProtocol
    private let slopeAnalysisService: SlopeAnalysisServiceProtocol

    // Search parameters based on professional systems
    private let maxSearchTime: Double = 4.0
    private let refinementTime: Double = 1.0

    init(
        pathSimulationService: PathSimulationServiceProtocol,
        slopeAnalysisService: SlopeAnalysisServiceProtocol
    ) {
        self.pathSimulationService = pathSimulationService
        self.slopeAnalysisService = slopeAnalysisService
    }

    /// Find optimal putting line through iterative simulation
    /// Falls back to conservative or aggressive strategy if optimal times out
    func findOptimalPutt(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters
    ) async -> PuttingLine? {
        let lines = await findPuttingLines(
            from: ball,
            to: hole,
            on: surface,
            with: slopeData,
            parameters: parameters
        )
        
        // Priority: optimal > conservative > aggressive
        if let optimal = lines[.optimal] {
            return optimal
        }
        if let conservative = lines[.conservative] {
            print("[BreakCalc] Using conservative fallback (optimal timed out)")
            return conservative
        }
        if let aggressive = lines[.aggressive] {
            print("[BreakCalc] Using aggressive fallback (optimal/conservative timed out)")
            return aggressive
        }
        return nil
    }

    /// Find multiple putting lines for different strategies
    func findPuttingLines(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters
    ) async -> [PuttingStrategy: PuttingLine] {
        let startTime = CFAbsoluteTimeGetCurrent()
        let distance = ball.worldPosition.horizontalDistance(to: hole.worldPosition)

        // Guard against zero-distance putts (ball at same position as hole)
        guard distance > 0.001 else {
            print("[BreakCalc] Ball and hole at same position, skipping calculation")
            return [:]
        }

        print("[BreakCalc] Starting multi-strategy calculation, distance: \(String(format: "%.2f", distance))m")

        let directDirection = simd_normalize(hole.worldPosition - ball.worldPosition)

        // Calculate base speeds for each strategy
        // Conservative: die at hole (0" past), Optimal: 9" past (AimPoint), Aggressive: 17" past (Pelz)
        let conservativeSpeed = parameters.initialSpeedForDistance(distance) * 1.02
        let optimalSpeed = parameters.optimalSpeedForDistance(distance, pastHoleDistance: 0.23) // 9 inches
        let aggressiveSpeed = parameters.optimalSpeedForDistance(distance, pastHoleDistance: 0.43) // 17 inches

        // Store results for each strategy
        var results: [PuttingStrategy: (result: SimulationResult, speed: Float, angle: Float, confidence: Float)] = [:]

        // Enhanced search parameters (M7 fix: finer angular resolution)
        // Wider angle search for longer putts with more break
        let baseMaxAngle: Float = .pi / 12 // +/- 15 degrees
        let distanceAngleMultiplier = min(1.5, 1.0 + distance / 10.0) // Wider for longer putts
        let maxAngleOffset = baseMaxAngle * distanceAngleMultiplier
        let angleSteps = 25 // Finer resolution for breaking putts (was 15)

        // Speed variations around each strategy's base speed
        let speedVariations: [Float] = [0.95, 0.98, 1.0, 1.02, 1.05, 1.08]

        var simulationCount = 0
        var allSuccessfulPutts: [(result: SimulationResult, speed: Float, angle: Float, confidence: Float)] = []

        // Grid search for all strategies
        let strategySpeeds: [(PuttingStrategy, Float)] = [
            (.conservative, conservativeSpeed),
            (.optimal, optimalSpeed),
            (.aggressive, aggressiveSpeed)
        ]

        for (strategy, baseSpeed) in strategySpeeds {
            var bestForStrategy: (result: SimulationResult, speed: Float, angle: Float, confidence: Float)?

            speedLoop: for speedMult in speedVariations {
                let speed = baseSpeed * speedMult

                for angleStep in 0..<angleSteps {
                    // Check cancellation
                    if Task.isCancelled {
                        print("[BreakCalc] Task cancelled, exiting grid search early")
                        return [:]
                    }

                    // Check timeout
                    if CFAbsoluteTimeGetCurrent() - startTime > maxSearchTime {
                        print("[BreakCalc] Timeout after \(simulationCount) simulations")
                        break speedLoop
                    }

                    let angleOffset = -maxAngleOffset + (Float(angleStep) / Float(angleSteps - 1)) * 2 * maxAngleOffset
                    let rotatedDirection = rotateDirectionHorizontal(directDirection, by: angleOffset)

                    let result = pathSimulationService.simulatePutt(
                        from: ball,
                        toward: rotatedDirection,
                        initialSpeed: speed,
                        on: surface,
                        with: slopeData,
                        holePosition: hole,
                        parameters: parameters
                    )

                    simulationCount += 1

                    // Yield to allow UI updates periodically
                    if simulationCount % 10 == 0 {
                        await Task.yield()
                    }

                    if result.holesOut {
                        let confidence = calculateEnhancedConfidence(
                            result: result,
                            hole: hole,
                            speed: speed,
                            baseSpeed: baseSpeed,
                            strategy: strategy,
                            parameters: parameters
                        )

                        let candidate = (result, speed, angleOffset, confidence)
                        allSuccessfulPutts.append(candidate)

                        if let current = bestForStrategy {
                            if confidence > current.confidence {
                                bestForStrategy = candidate
                            }
                        } else {
                            bestForStrategy = candidate
                        }

                        // M8 fix: removed early exit at 0.85 — keep searching for
                        // better solutions. Timeout protects against excessive runtime.
                        if confidence > 0.90 {
                            break speedLoop
                        }
                    }
                }
            }

            if let best = bestForStrategy {
                results[strategy] = best
            }
        }

        print("[BreakCalc] Grid search: \(simulationCount) sims, found \(allSuccessfulPutts.count) successful putts in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - startTime))s")

        // If no results found, find closest approach as fallback
        if results.isEmpty {
            print("[BreakCalc] No holing putts found, using closest approach")
            if let fallback = findClosestApproachEnhanced(
                from: ball,
                to: hole,
                on: surface,
                with: slopeData,
                parameters: parameters,
                baseSpeed: optimalSpeed,
                directDirection: directDirection
            ) {
                results[.optimal] = fallback
            }
        }

        // Refine best results if time permits
        var refinedResults = results
        if CFAbsoluteTimeGetCurrent() - startTime < maxSearchTime - refinementTime {
            for (strategy, result) in results {
                if Task.isCancelled { break }
                if result.result.holesOut {
                    let refined = refineResult(
                        initial: result,
                        ball: ball,
                        hole: hole,
                        surface: surface,
                        slopeData: slopeData,
                        parameters: parameters,
                        directDirection: directDirection,
                        strategy: strategy
                    )
                    refinedResults[strategy] = refined
                }
            }
        }

        // Build putting lines
        var puttingLines: [PuttingStrategy: PuttingLine] = [:]

        for (strategy, result) in refinedResults {
            let aimDirection = rotateDirectionHorizontal(directDirection, by: result.angle)
            let aimPoint = ball.worldPosition + aimDirection * distance

            let breakInfo = calculateBreak(for: result.result.path, directLine: directDirection)
            let recommendedSpeed = categorizeSpeed(result.speed, baseSpeed: strategySpeeds.first { $0.0 == strategy }?.1 ?? optimalSpeed)

            print("[BreakCalc] \(strategy.rawValue): confidence \(String(format: "%.0f", result.confidence * 100))%, break \(breakInfo.breakDescription)")

            puttingLines[strategy] = PuttingLine(
                id: UUID(),
                pathPoints: result.result.path,
                aimPoint: aimPoint,
                estimatedBreak: breakInfo,
                recommendedSpeed: recommendedSpeed,
                confidence: result.confidence,
                distance: distance
            )
        }

        print("[BreakCalc] Complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - startTime))s")

        return puttingLines
    }

    /// Calculate break info from path - validates physically possible values
    func calculateBreak(for path: [PuttingLine.PathPoint], directLine: SIMD3<Float>) -> PuttingLine.BreakInfo {
        guard path.count >= 2 else {
            return .straight
        }

        let startPos = path.first!.position
        let endPos = path.last!.position

        // Calculate total putt distance for validation
        let totalDistance = simd_distance(
            SIMD2<Float>(startPos.x, startPos.z),
            SIMD2<Float>(endPos.x, endPos.z)
        )

        var maxDeviation: Float = 0
        var deviationDirection: PuttingLine.BreakDirection = .straight
        var breakProfile: [Float] = []

        // Normalize direct line in XZ plane only
        let directLineXZ = simd_normalize(SIMD3<Float>(directLine.x, 0, directLine.z))

        for point in path {
            // Calculate deviation in XZ plane only (horizontal)
            let toPoint = SIMD3<Float>(
                point.position.x - startPos.x,
                0,
                point.position.z - startPos.z
            )

            let alongLine = simd_dot(toPoint, directLineXZ)
            let projection = directLineXZ * alongLine
            let perpendicular = toPoint - projection
            let deviation = simd_length(perpendicular)

            breakProfile.append(deviation)

            if deviation > maxDeviation && simd_length(perpendicular) > 0.001 {
                maxDeviation = deviation
                // Use cross product Y component to determine left/right
                let cross = simd_cross(directLineXZ, simd_normalize(perpendicular))
                deviationDirection = cross.y > 0 ? .left : .right
            }
        }

        // Sanity check: break cannot exceed distance (physically impossible)
        // Maximum realistic break is about 50% of distance on extreme slopes
        let maxPossibleBreak = totalDistance * 0.5
        if maxDeviation > maxPossibleBreak {
            // Likely a data error - clamp to reasonable value
            maxDeviation = min(maxDeviation, maxPossibleBreak)
        }

        // Very small deviations are effectively straight
        if maxDeviation < 0.02 { // Less than 2cm
            return .straight
        }

        return PuttingLine.BreakInfo(
            totalBreak: maxDeviation,
            breakDirection: deviationDirection,
            breakProfile: breakProfile
        )
    }

    // MARK: - Private Methods

    private func rotateDirectionHorizontal(_ direction: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD3<Float>(
            direction.x * c - direction.z * s,
            direction.y,
            direction.x * s + direction.z * c
        )
    }

    /// Enhanced confidence scoring based on research
    /// Factors: entry speed, entry offset, hole probability, path quality, data quality
    private func calculateEnhancedConfidence(
        result: SimulationResult,
        hole: HolePosition,
        speed: Float,
        baseSpeed: Float,
        strategy: PuttingStrategy,
        parameters: PhysicsParameters
    ) -> Float {
        guard result.holesOut else { return 0 }

        // Factor 1: Entry conditions (30% weight)
        // Use physics-based hole probability
        let entrySpeed = result.entrySpeed ?? 1.0
        let entryOffset = result.entryOffset ?? 0.0
        // M9 fix: compute actual entry angle instead of passing 0
        let entryAngle: Float
        if let lastPathPoint = result.path.dropLast().last {
            let entryDir = simd_normalize(SIMD3<Float>(
                result.path.last!.position.x - lastPathPoint.position.x,
                0,
                result.path.last!.position.z - lastPathPoint.position.z
            ))
            let toHole = simd_normalize(SIMD3<Float>(
                hole.worldPosition.x - lastPathPoint.position.x,
                0,
                hole.worldPosition.z - lastPathPoint.position.z
            ))
            entryAngle = acos(min(1.0, max(-1.0, simd_dot(entryDir, toHole))))
        } else {
            entryAngle = 0
        }
        let holeProbability = parameters.holeProbability(speed: entrySpeed, offset: entryOffset, angle: entryAngle)
        let entryScore = holeProbability * 0.7 + (1.0 - min(entrySpeed / PhysicsParameters.maxCaptureSpeed, 1.0)) * 0.3

        // Factor 2: Speed alignment with strategy (25% weight)
        let speedDeviation = abs(speed - baseSpeed) / baseSpeed
        var speedScore: Float

        switch strategy {
        case .conservative:
            // Penalize speeds that are too fast
            speedScore = speed <= baseSpeed * 1.05 ? 1.0 - speedDeviation : 0.5
        case .optimal:
            // Reward speeds close to optimal
            speedScore = max(0, 1.0 - speedDeviation * 2)
        case .aggressive:
            // Accept slightly faster speeds
            speedScore = speed >= baseSpeed * 0.95 ? 1.0 - speedDeviation * 0.5 : 0.5
        }

        // Factor 3: Path quality (25% weight)
        // Straighter paths are more reliable and easier to execute
        guard let firstPoint = result.path.first else { return 0 }
        let directDistance = firstPoint.position.horizontalDistance(to: hole.worldPosition)
        let pathLength = calculatePathLength(result.path)
        let straightnessRatio = pathLength > 0.001 ? directDistance / pathLength : 1.0
        let straightnessScore = min(1.0, straightnessRatio * 1.1) // Slight bonus for very straight

        // Factor 4: Data quality based on distance (20% weight)
        // M6 fix: short putts are easier to execute, don't penalize them
        var dataQualityScore: Float = 1.0
        if directDistance < 0.5 {
            // Very short putts: easier to execute despite less slope data
            dataQualityScore = 0.95 // Minimal penalty — short putts are reliable
        } else if directDistance > 5.0 {
            // Longer putts: more error accumulation — gentler penalty curve
            let penalty = (directDistance - 5.0) * 0.03
            dataQualityScore = max(0.6, 1.0 - penalty)
        }

        // Check for lip-out risk
        var lipOutPenalty: Float = 0
        if result.lipOutOccurred || entrySpeed > PhysicsParameters.simpleCaptureSpeed {
            lipOutPenalty = 0.1
        }

        // Weighted combination
        let rawConfidence = entryScore * 0.30 +
                           speedScore * 0.25 +
                           straightnessScore * 0.25 +
                           dataQualityScore * 0.20 -
                           lipOutPenalty

        // Cap at realistic maximum (never 100% confident in golf!)
        // Professional systems typically cap at 90-95%
        return min(max(rawConfidence, 0), 0.92)
    }

    /// Legacy confidence calculation for backward compatibility
    private func calculateConfidence(
        result: SimulationResult,
        hole: HolePosition,
        speed: Float,
        baseSpeed: Float
    ) -> Float {
        return calculateEnhancedConfidence(
            result: result,
            hole: hole,
            speed: speed,
            baseSpeed: baseSpeed,
            strategy: .optimal,
            parameters: PhysicsParameters(stimpmeterSpeed: 10.0)
        )
    }

    private func calculatePathLength(_ path: [PuttingLine.PathPoint]) -> Float {
        var length: Float = 0
        for i in 1..<path.count {
            // Use horizontal distance (XZ plane) to match the horizontal directDistance
            // used in the straightness ratio. 3D distance unfairly penalizes sloped putts.
            length += path[i].position.horizontalDistance(to: path[i - 1].position)
        }
        return length
    }

    /// Enhanced closest approach search with wider angle exploration
    /// Respects cancellation and a 3-second hard timeout to stay within overall budget.
    private func findClosestApproachEnhanced(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters,
        baseSpeed: Float,
        directDirection: SIMD3<Float>
    ) -> (result: SimulationResult, speed: Float, angle: Float, confidence: Float)? {
        let fallbackStart = CFAbsoluteTimeGetCurrent()
        let fallbackTimeout: Double = 3.0  // Hard cap for the fallback phase
        var best: (result: SimulationResult, speed: Float, angle: Float, distance: Float)?

        // Try multiple speeds and angles to find closest approach
        let speeds: [Float] = [baseSpeed * 0.9, baseSpeed * 0.95, baseSpeed, baseSpeed * 1.05, baseSpeed * 1.1]
        let angles: [Float] = [-.pi/36, -.pi/72, 0, .pi/72, .pi/36] // +/- 5 degrees

        for speed in speeds {
            for angle in angles {
                if Task.isCancelled { break }
                if CFAbsoluteTimeGetCurrent() - fallbackStart > fallbackTimeout {
                    print("[BreakCalc] Fallback timeout after \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - fallbackStart))s")
                    break
                }

                let rotatedDirection = rotateDirectionHorizontal(directDirection, by: angle)

                let result = pathSimulationService.simulatePutt(
                    from: ball,
                    toward: rotatedDirection,
                    initialSpeed: speed,
                    on: surface,
                    with: slopeData,
                    holePosition: hole,
                    parameters: parameters
                )

                let closestDistance = result.closestApproach

                if best == nil || closestDistance < best!.distance {
                    best = (result, speed, angle, closestDistance)
                }
            }
            if Task.isCancelled { break }
            if CFAbsoluteTimeGetCurrent() - fallbackStart > fallbackTimeout { break }
        }

        guard let result = best else { return nil }

        // Confidence based on how close we got
        // If within 10cm, reasonable confidence; if over 50cm, low confidence
        let distancePenalty = min(result.distance / 0.5, 1.0)
        let confidence = max(0.2, 0.7 * (1.0 - distancePenalty))

        return (result.result, result.speed, result.angle, confidence)
    }

    /// Legacy method for compatibility
    private func findClosestApproachFast(
        from ball: BallPosition,
        to hole: HolePosition,
        on surface: GreenSurface,
        with slopeData: SlopeData,
        parameters: PhysicsParameters,
        baseSpeed: Float,
        directDirection: SIMD3<Float>
    ) -> (result: SimulationResult, speed: Float, angle: Float, confidence: Float)? {
        return findClosestApproachEnhanced(
            from: ball,
            to: hole,
            on: surface,
            with: slopeData,
            parameters: parameters,
            baseSpeed: baseSpeed,
            directDirection: directDirection
        )
    }

    /// Enhanced refinement with gradient descent-style optimization
    private func refineResult(
        initial: (result: SimulationResult, speed: Float, angle: Float, confidence: Float),
        ball: BallPosition,
        hole: HolePosition,
        surface: GreenSurface,
        slopeData: SlopeData,
        parameters: PhysicsParameters,
        directDirection: SIMD3<Float>,
        strategy: PuttingStrategy
    ) -> (result: SimulationResult, speed: Float, angle: Float, confidence: Float) {
        var best = initial

        // Fine-grained search around best result
        let fineAngleSteps: [Float] = [-.pi/180, -.pi/360, 0, .pi/360, .pi/180] // +/- 1 degree, 0.5 degree
        let fineSpeedSteps: [Float] = [-0.03, -0.015, 0, 0.015, 0.03]

        for angleOffset in fineAngleSteps {
            if Task.isCancelled { break }
            for speedOffset in fineSpeedSteps {
                let angle = initial.angle + angleOffset
                let speed = initial.speed * (1 + speedOffset)

                let rotatedDirection = rotateDirectionHorizontal(directDirection, by: angle)

                let result = pathSimulationService.simulatePutt(
                    from: ball,
                    toward: rotatedDirection,
                    initialSpeed: speed,
                    on: surface,
                    with: slopeData,
                    holePosition: hole,
                    parameters: parameters
                )

                if result.holesOut {
                    let confidence = calculateEnhancedConfidence(
                        result: result,
                        hole: hole,
                        speed: speed,
                        baseSpeed: initial.speed,
                        strategy: strategy,
                        parameters: parameters
                    )

                    if confidence > best.confidence {
                        best = (result, speed, angle, confidence)
                    }
                }
            }
        }

        return best
    }

    /// Legacy method for compatibility
    private func refineResultFast(
        initial: (result: SimulationResult, speed: Float, angle: Float, confidence: Float),
        ball: BallPosition,
        hole: HolePosition,
        surface: GreenSurface,
        slopeData: SlopeData,
        parameters: PhysicsParameters,
        directDirection: SIMD3<Float>
    ) -> (result: SimulationResult, speed: Float, angle: Float, confidence: Float) {
        return refineResult(
            initial: initial,
            ball: ball,
            hole: hole,
            surface: surface,
            slopeData: slopeData,
            parameters: parameters,
            directDirection: directDirection,
            strategy: .optimal
        )
    }

    private func categorizeSpeed(_ speed: Float, baseSpeed: Float) -> PuttingLine.PuttSpeed {
        let ratio = speed / baseSpeed
        if ratio < 0.95 {
            return .gentle
        } else if ratio > 1.1 {
            return .firm
        } else {
            return .moderate
        }
    }
}
