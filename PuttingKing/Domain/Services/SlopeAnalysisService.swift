import Foundation
import simd

/// Protocol for slope analysis
protocol SlopeAnalysisServiceProtocol {
    func analyzeSurface(_ surface: GreenSurface) -> SlopeData
    func getSlopeAt(position: SIMD3<Float>, in slopeData: SlopeData) -> SlopeData.GradientSample?
}

/// Service that analyzes green surface slope and gradient
final class SlopeAnalysisService: SlopeAnalysisServiceProtocol {

    /// Analyze surface and compute gradient field
    func analyzeSurface(_ surface: GreenSurface) -> SlopeData {
        guard !surface.vertices.isEmpty else {
            return .empty
        }

        var gradientSamples: [SlopeData.GradientSample] = []
        gradientSamples.reserveCapacity(surface.vertices.count)

        // Calculate gradient at each vertex from surface normal
        for i in 0..<surface.vertices.count {
            let position = surface.vertices[i]
            var normal = surface.normals[i]

            // Normalize the normal vector first
            let normalLength = simd_length(normal)
            guard normalLength > 0.001 else { continue }
            normal = normal / normalLength

            // Ensure normal points up
            if normal.y < 0 {
                normal = -normal
            }

            // Skip if normal is too horizontal (not a ground surface)
            // A normal.y of 0.7 corresponds to about 45 degrees - typical max for putting surfaces
            guard normal.y > 0.7 else { continue }

            // Calculate gradient (direction of steepest descent)
            // For a normal N = (nx, ny, nz), the gradient in the XZ plane is:
            // gradient = (-nx/ny, -nz/ny)
            let gradientX = -normal.x / normal.y
            let gradientZ = -normal.z / normal.y
            let gradient = SIMD2<Float>(gradientX, gradientZ)

            // Calculate slope - clamp to reasonable putting green values (0-15%)
            let slopeMagnitude = simd_length(gradient)

            // Reasonable putting green slopes are 0-15% (championship greens rarely exceed 5%)
            // Skip outliers that indicate measurement noise or non-green surfaces
            // Relaxed to 0.35 (35%) to allow for steep tiers/false fronts (Phase 3 Audit)
            guard slopeMagnitude < 0.35 else { continue } // Skip if > 35% slope

            let slopePercentage = slopeMagnitude * 100
            let slopeAngle = atan(slopeMagnitude)

            gradientSamples.append(SlopeData.GradientSample(
                position: position,
                gradient: gradient,
                slopePercentage: slopePercentage,
                slopeAngle: slopeAngle
            ))
        }

        guard !gradientSamples.isEmpty else {
            // If no valid samples, return near-flat surface data
            return SlopeData(
                gradientField: [],
                maxSlope: 0,
                averageSlope: 1.0, // Assume 1% average slope for flat surface
                dominantDirection: .zero
            )
        }

        // Calculate statistics
        let maxSlope = gradientSamples.map(\.slopePercentage).max() ?? 0
        let avgSlope = gradientSamples.map(\.slopePercentage).reduce(0, +) / Float(gradientSamples.count)

        // Calculate dominant direction (weighted average of gradients)
        let totalGradient = gradientSamples.reduce(SIMD2<Float>.zero) { $0 + $1.gradient }
        let dominantDirection = simd_length(totalGradient) > 0.001
            ? simd_normalize(totalGradient)
            : .zero

        print("[SlopeAnalysis] Analyzed \(gradientSamples.count) valid samples, avg slope: \(String(format: "%.1f", avgSlope))%, max: \(String(format: "%.1f", maxSlope))%")

        return SlopeData(
            gradientField: gradientSamples,
            maxSlope: min(maxSlope, 15.0), // Cap at 15% for realistic putting greens
            averageSlope: min(avgSlope, 10.0), // Cap average at 10%
            dominantDirection: dominantDirection
        )
    }

    /// Get interpolated slope at a specific position
    func getSlopeAt(position: SIMD3<Float>, in slopeData: SlopeData) -> SlopeData.GradientSample? {
        return slopeData.slopeAt(position: position)
    }

    /// Get slope along a path between two points
    func getSlopeAlongPath(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        steps: Int,
        in slopeData: SlopeData
    ) -> [SlopeData.GradientSample] {
        var samples: [SlopeData.GradientSample] = []

        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let position = start + t * (end - start)

            if let sample = getSlopeAt(position: position, in: slopeData) {
                samples.append(sample)
            }
        }

        return samples
    }

    /// Calculate average slope along a direct line
    func averageSlopeAlongLine(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        in slopeData: SlopeData
    ) -> Float {
        let samples = getSlopeAlongPath(from: start, to: end, steps: 20, in: slopeData)
        guard !samples.isEmpty else { return 0 }

        let totalSlope = samples.map(\.slopePercentage).reduce(0, +)
        return totalSlope / Float(samples.count)
    }

    /// Estimate break direction from ball to hole
    func estimateBreakDirection(
        from ball: SIMD3<Float>,
        to hole: SIMD3<Float>,
        in slopeData: SlopeData
    ) -> PuttingLine.BreakDirection {
        let samples = getSlopeAlongPath(from: ball, to: hole, steps: 10, in: slopeData)
        guard !samples.isEmpty else { return .straight }

        // Average gradient along path
        let avgGradient = samples.reduce(SIMD2<Float>.zero) { $0 + $1.gradient } / Float(samples.count)

        // Direction from ball to hole
        let puttDirection = SIMD2<Float>(hole.x - ball.x, hole.z - ball.z)
        let puttDirectionNorm = simd_length(puttDirection) > 0.001
            ? simd_normalize(puttDirection)
            : SIMD2<Float>(1, 0)

        // Cross product to determine left/right
        // In 2D: cross(a, b) = ax*bz - az*bx
        let cross = puttDirectionNorm.x * avgGradient.y - puttDirectionNorm.y * avgGradient.x

        // Gradient perpendicular component relative to putt direction
        let perpComponent = abs(cross)

        if perpComponent < 0.01 {
            return .straight
        } else if cross > 0 {
            return .left
        } else {
            return .right
        }
    }
}
