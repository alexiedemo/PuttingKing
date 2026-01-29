import Foundation
import simd

/// Slope analysis results for the green surface
/// Uses spatial hashing for O(1) slope lookup during physics simulation
struct SlopeData {
    let gradientField: [GradientSample]
    let maxSlope: Float
    let averageSlope: Float
    let dominantDirection: SIMD2<Float>

    // Spatial hash grid for fast lookup
    private let spatialGrid: SpatialGrid

    struct GradientSample {
        let position: SIMD3<Float>
        let gradient: SIMD2<Float>
        let slopePercentage: Float
        let slopeAngle: Float

        /// Returns the slope direction as a unit vector in the XZ plane
        var slopeDirection: SIMD2<Float> {
            let len = simd_length(gradient)
            guard len > 0.0001 else { return .zero }
            return gradient / len
        }
    }

    /// Spatial grid for O(1) lookup of nearby samples
    private struct SpatialGrid {
        let cellSize: Float
        let cells: [GridKey: [Int]] // Maps cell to indices in gradientField
        let minBounds: SIMD2<Float>
        let maxBounds: SIMD2<Float>

        struct GridKey: Hashable {
            let x: Int
            let z: Int
        }

        init(samples: [GradientSample], cellSize: Float = 0.25) {
            self.cellSize = cellSize

            guard !samples.isEmpty else {
                self.cells = [:]
                self.minBounds = .zero
                self.maxBounds = .zero
                return
            }

            // Calculate bounds
            var minX: Float = .infinity
            var minZ: Float = .infinity
            var maxX: Float = -.infinity
            var maxZ: Float = -.infinity

            for sample in samples {
                minX = min(minX, sample.position.x)
                minZ = min(minZ, sample.position.z)
                maxX = max(maxX, sample.position.x)
                maxZ = max(maxZ, sample.position.z)
            }

            self.minBounds = SIMD2<Float>(minX, minZ)
            self.maxBounds = SIMD2<Float>(maxX, maxZ)

            // Build spatial hash
            var grid: [GridKey: [Int]] = [:]
            for (index, sample) in samples.enumerated() {
                let key = GridKey(
                    x: Int(floor((sample.position.x - minX) / cellSize)),
                    z: Int(floor((sample.position.z - minZ) / cellSize))
                )
                grid[key, default: []].append(index)
            }
            self.cells = grid
        }

        /// Get all sample indices within a given radius of position
        func samplesNear(position: SIMD2<Float>, radius: Float) -> [Int] {
            let cellRadius = Int(ceil(radius / cellSize))
            let centerX = Int(floor((position.x - minBounds.x) / cellSize))
            let centerZ = Int(floor((position.y - minBounds.y) / cellSize))

            var indices: [Int] = []

            for dx in -cellRadius...cellRadius {
                for dz in -cellRadius...cellRadius {
                    let key = GridKey(x: centerX + dx, z: centerZ + dz)
                    if let cellIndices = cells[key] {
                        indices.append(contentsOf: cellIndices)
                    }
                }
            }

            return indices
        }
    }

    /// Full initializer with spatial grid construction
    init(gradientField: [GradientSample], maxSlope: Float, averageSlope: Float, dominantDirection: SIMD2<Float>) {
        self.gradientField = gradientField
        self.maxSlope = maxSlope
        self.averageSlope = averageSlope
        self.dominantDirection = dominantDirection
        self.spatialGrid = SpatialGrid(samples: gradientField)
    }

    /// Creates empty slope data
    static var empty: SlopeData {
        SlopeData(
            gradientField: [],
            maxSlope: 0,
            averageSlope: 0,
            dominantDirection: .zero
        )
    }

    /// Returns the interpolated slope at a given position - O(1) average via spatial hashing
    /// Decreased default radius to 0.1m (10cm) for higher fidelity contours (Phase 3 Audit)
    func slopeAt(position: SIMD3<Float>, searchRadius: Float = 0.10) -> GradientSample? {
        let position2D = SIMD2<Float>(position.x, position.z)

        // Use spatial grid for fast neighbor lookup
        let candidateIndices = spatialGrid.samplesNear(position: position2D, radius: searchRadius) // Grid handles larger queries intrinsically if needed

        guard !candidateIndices.isEmpty else {
            // Fallback: return average slope for the entire surface
            if !gradientField.isEmpty {
                return GradientSample(
                    position: position,
                    gradient: dominantDirection * (averageSlope / 100.0),
                    slopePercentage: averageSlope,
                    slopeAngle: atan(averageSlope / 100.0)
                )
            }
            return nil
        }

        // Filter to actual radius and compute weighted interpolation
        var totalWeight: Float = 0
        var weightedGradient = SIMD2<Float>.zero
        var foundSamples = false
        
        let effectiveRadius = max(searchRadius, 0.1) // Ensure minimum query radius

        for index in candidateIndices {
            let sample = gradientField[index]
            let samplePos2D = SIMD2<Float>(sample.position.x, sample.position.z)
            let dist = simd_distance(position2D, samplePos2D)

            if dist < effectiveRadius {
                foundSamples = true
                let weight = 1.0 / max(dist, 0.001)
                totalWeight += weight
                weightedGradient += sample.gradient * weight
            }
        }

        guard foundSamples else {
            // No samples in radius, use fallback
            return GradientSample(
                position: position,
                gradient: dominantDirection * (averageSlope / 100.0),
                slopePercentage: averageSlope,
                slopeAngle: atan(averageSlope / 100.0)
            )
        }

        let interpolatedGradient = weightedGradient / totalWeight
        let slopeMagnitude = simd_length(interpolatedGradient)

        return GradientSample(
            position: position,
            gradient: interpolatedGradient,
            slopePercentage: slopeMagnitude * 100,
            slopeAngle: atan(slopeMagnitude)
        )
    }
}
