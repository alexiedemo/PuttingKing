import Foundation
import os
import simd

private let logger = Logger(subsystem: "com.puttingking", category: "BreakCalc")

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
            logger.info("Using conservative fallback (optimal timed out)")
            return conservative
        }
        if let aggressive = lines[.aggressive] {
            logger.info("Using aggressive fallback (optimal/conservative timed out)")
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
            logger.warning("Ball and hole at same position, skipping calculation")
            return [:]
        }

        let distStr = String(format: "%.2f", distance)
        logger.info("Starting multi-strategy calculation, distance: \(distStr)m")

        // Project to XZ plane before normalizing — preserving Y would cause
        // rotateDirectionHorizontal to produce an aim point that's short in XZ by cos(slope)
        let diff = hole.worldPosition - ball.worldPosition
        let directDirection = simd_normalize(SIMD3<Float>(diff.x, 0, diff.z))

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
        // Try base speed first, then nearby variations (most promising first)
        let speedVariations: [Float] = [1.0, 1.02, 0.98, 1.05, 0.95, 1.08]

        var simulationCount = 0
        var allSuccessfulPutts: [(result: SimulationResult, speed: Float, angle: Float, confidence: Float)] = []

        // Pre-compute angle offsets in center-outward spiral order.
        // This ensures the most promising angles (near direct line) are tested first,
        // so short putts on flat greens find solutions before the timeout.
        let angleOffsets: [Float] = {
            let step = 2 * maxAngleOffset / Float(angleSteps - 1)
            var offsets: [Float] = [0] // Start at center (direct line)
            for i in 1...(angleSteps / 2) {
                let offset = step * Float(i)
                offsets.append(offset)    // right
                offsets.append(-offset)   // left
            }
            return offsets
        }()

        // Grid search for all strategies — try optimal first for best chance of early success
        let strategySpeeds: [(PuttingStrategy, Float)] = [
            (.optimal, optimalSpeed),
            (.conservative, conservativeSpeed),
            (.aggressive, aggressiveSpeed)
        ]

        for (strategy, baseSpeed) in strategySpeeds {
            var bestForStrategy: (result: SimulationResult, speed: Float, angle: Float, confidence: Float)?

            speedLoop: for speedMult in speedVariations {
                let speed = baseSpeed * speedMult

                for angleOffset in angleOffsets {
                    // Check cancellation
                    if Task.isCancelled {
                        logger.info("Task cancelled, exiting grid search early")
                        return [:]
                    }

                    // Check timeout
                    if CFAbsoluteTimeGetCurrent() - startTime > maxSearchTime {
                        logger.warning("Timeout after \(simulationCount) simulations")
                        break speedLoop
                    }

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
                        // Lower threshold for fallback strategies (conservative/aggressive)
                        // since finding any good result quickly frees time for refinement.
                        let earlyExitThreshold: Float = strategy == .optimal ? 0.90 : 0.85
                        if confidence > earlyExitThreshold {
                            break speedLoop
                        }
                    }
                }
            }

            if let best = bestForStrategy {
                results[strategy] = best
            }
        }

        let gridTimeStr = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - startTime)
        logger.info("Grid search: \(simulationCount) sims, found \(allSuccessfulPutts.count) successful putts in \(gridTimeStr)s")

        // If no results found, find closest approach as fallback
        if results.isEmpty {
            logger.warning("No holing putts found, using closest approach")
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
                if CFAbsoluteTimeGetCurrent() - startTime > maxSearchTime { break }
                if result.result.holesOut {
                    let refined = refineResult(
                        initial: result,
                        ball: ball,
                        hole: hole,
                        surface: surface,
                        slopeData: slopeData,
                        parameters: parameters,
                        directDirection: directDirection,
                        strategy: strategy,
                        deadline: startTime + maxSearchTime
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

            let confStr = String(format: "%.0f", result.confidence * 100)
            logger.info("\(strategy.rawValue): confidence \(confStr)%, break \(breakInfo.breakDescription)")

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

        let totalTimeStr = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - startTime)
        logger.info("Complete in \(totalTimeStr)s")

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

        // Very small deviations are effectively straight.
        // Scale threshold with putt distance: 0.5% of distance, minimum 1.5cm.
        // Examples: 1m→1.5cm, 5m→2.5cm, 10m→5cm, 15m→7.5cm.
        let straightThreshold = max(Float(0.015), totalDistance * 0.005)
        if maxDeviation < straightThreshold {
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
        // Guard against zero-length vectors (identical consecutive path points → NaN normalize)
        let entryAngle: Float
        if let lastPathPoint = result.path.dropLast().last {
            let rawEntryDir = SIMD3<Float>(
                result.path.last!.position.x - lastPathPoint.position.x,
                0,
                result.path.last!.position.z - lastPathPoint.position.z
            )
            let rawToHole = SIMD3<Float>(
                hole.worldPosition.x - lastPathPoint.position.x,
                0,
                hole.worldPosition.z - lastPathPoint.position.z
            )
            if simd_length(rawEntryDir) > 0.001 && simd_length(rawToHole) > 0.001 {
                let entryDir = simd_normalize(rawEntryDir)
                let toHole = simd_normalize(rawToHole)
                entryAngle = acos(min(1.0, max(-1.0, simd_dot(entryDir, toHole))))
            } else {
                entryAngle = 0
            }
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
        // Penalize lateral deviation from the direct line, not total path length.
        // Path-length ratio penalizes natural uphill putts; lateral deviation targets actual break.
        guard let firstPoint = result.path.first else { return 0 }
        let directDistance = firstPoint.position.horizontalDistance(to: hole.worldPosition)
        let directLineXZ = simd_normalize(SIMD3<Float>(
            hole.worldPosition.x - firstPoint.position.x, 0,
            hole.worldPosition.z - firstPoint.position.z
        ))
        var maxLateralDev: Float = 0
        for point in result.path {
            let toPoint = SIMD3<Float>(
                point.position.x - firstPoint.position.x, 0,
                point.position.z - firstPoint.position.z
            )
            let along = simd_dot(toPoint, directLineXZ)
            let perp = toPoint - directLineXZ * along
            maxLateralDev = max(maxLateralDev, simd_length(perp))
        }
        let deviationRatio = directDistance > 0.001 ? maxLateralDev / directDistance : 0
        let straightnessScore = max(Float(0), min(1.0, 1.0 - deviationRatio * 2.0))

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

        // Clamp individual factors to [0, 1] before combining — prevents any single
        // over-valued component from inflating the weighted sum beyond bounds.
        let clampedEntry = min(max(entryScore, 0), 1.0)
        let clampedSpeed = min(max(speedScore, 0), 1.0)
        let clampedStraightness = min(max(straightnessScore, 0), 1.0)
        let clampedDataQuality = min(max(dataQualityScore, 0), 1.0)

        // Weighted combination
        let rawConfidence = clampedEntry * 0.30 +
                           clampedSpeed * 0.25 +
                           clampedStraightness * 0.25 +
                           clampedDataQuality * 0.20 -
                           lipOutPenalty

        // Cap at realistic maximum (never 100% confident in golf!)
        // Professional systems typically cap at 90-95%
        return min(max(rawConfidence, 0), 0.92)
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
                    let fallbackTimeStr = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - fallbackStart)
                    logger.warning("Fallback timeout after \(fallbackTimeStr)s")
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

    /// Enhanced refinement with gradient descent-style optimization
    private func refineResult(
        initial: (result: SimulationResult, speed: Float, angle: Float, confidence: Float),
        ball: BallPosition,
        hole: HolePosition,
        surface: GreenSurface,
        slopeData: SlopeData,
        parameters: PhysicsParameters,
        directDirection: SIMD3<Float>,
        strategy: PuttingStrategy,
        deadline: CFAbsoluteTime = .infinity
    ) -> (result: SimulationResult, speed: Float, angle: Float, confidence: Float) {
        var best = initial

        // Fine-grained search around best result
        let fineAngleSteps: [Float] = [-.pi/180, -.pi/360, 0, .pi/360, .pi/180] // +/- 1 degree, 0.5 degree
        let fineSpeedSteps: [Float] = [-0.03, -0.015, 0, 0.015, 0.03]

        for angleOffset in fineAngleSteps {
            if Task.isCancelled { break }
            // Timeout guard: bail out if approaching the search deadline
            if CFAbsoluteTimeGetCurrent() > deadline { break }
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

    /// Release cached simulation data to free memory after analysis completes
    func clearSimulationCache() {
        (pathSimulationService as? PathSimulationService)?.clearHeightCache()
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
