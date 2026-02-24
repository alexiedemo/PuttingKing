import Foundation
import simd

/// Slope analysis results for the green surface
/// Uses spatial hashing for O(1) slope lookup during physics simulation
struct SlopeData {
    let gradientField: [GradientSample]
    let maxSlope: Float
    let averageSlope: Float
    let dominantDirection: SIMD2<Float>

    // Spatial hash grid for fast lookup (fallback for edge positions)
    private let spatialGrid: SpatialGrid

    // Pre-computed regular grid for O(1) bilinear interpolation (primary lookup path)
    private let regularGrid: RegularSlopeGrid?

    struct GradientSample {
        let position: SIMD3<Float>
        var gradient: SIMD2<Float>
        var slopePercentage: Float
        var slopeAngle: Float

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

    /// Pre-computed regular grid for O(1) bilinear slope interpolation during simulation.
    /// Built once from gradient samples via IDW splatting; eliminates per-step dictionary
    /// lookups and array allocations from the hot simulation loop.
    /// Memory: ~50KB for a typical 3m×3m green at 5cm resolution.
    private struct RegularSlopeGrid {
        let originX: Float
        let originZ: Float
        let invCellSize: Float
        let cols: Int
        let rows: Int
        // Flat interleaved array: [gradX, gradZ, slopeAngle] per cell for cache locality
        let data: [Float]
        let valid: [Bool]

        init(samples: [GradientSample], boundsMin: SIMD2<Float>, boundsMax: SIMD2<Float>) {
            let gridCellSize: Float = 0.05  // 5cm resolution
            let pad: Float = 0.15           // 15cm padding beyond sample bounds
            let buildRadius: Float = 0.15   // IDW interpolation radius for grid construction

            let minX = boundsMin.x - pad
            let minZ = boundsMin.y - pad
            let maxX = boundsMax.x + pad
            let maxZ = boundsMax.y + pad

            self.originX = minX
            self.originZ = minZ
            self.invCellSize = 1.0 / gridCellSize
            self.cols = max(2, Int(ceil((maxX - minX) / gridCellSize)) + 1)
            self.rows = max(2, Int(ceil((maxZ - minZ) / gridCellSize)) + 1)

            let count = rows * cols

            // Temporary accumulators for IDW splatting
            var weights = [Float](repeating: 0, count: count)
            var accGradX = [Float](repeating: 0, count: count)
            var accGradZ = [Float](repeating: 0, count: count)

            let cellRadius = Int(ceil(buildRadius * self.invCellSize))
            let radiusSq = buildRadius * buildRadius

            // Splat each sample's contribution to nearby grid cells.
            // O(samples × small_constant) — avoids per-cell dictionary lookups.
            for sample in samples {
                let scx = Int(floor((sample.position.x - minX) * self.invCellSize))
                let scz = Int(floor((sample.position.z - minZ) * self.invCellSize))

                for dz in -cellRadius...cellRadius {
                    let iz = scz + dz
                    guard iz >= 0 && iz < self.rows else { continue }
                    for dx in -cellRadius...cellRadius {
                        let ix = scx + dx
                        guard ix >= 0 && ix < self.cols else { continue }

                        let gx = minX + Float(ix) * gridCellSize
                        let gz = minZ + Float(iz) * gridCellSize
                        let ddx = sample.position.x - gx
                        let ddz = sample.position.z - gz
                        let distSq = ddx * ddx + ddz * ddz

                        if distSq < radiusSq {
                            let weight = 1.0 / (distSq + 0.0001)
                            let idx = iz * self.cols + ix
                            weights[idx] += weight
                            accGradX[idx] += sample.gradient.x * weight
                            accGradZ[idx] += sample.gradient.y * weight
                        }
                    }
                }
            }

            // Normalize accumulated values and compute derived slopeAngle
            var data = [Float](repeating: 0, count: count * 3)
            var valid = [Bool](repeating: false, count: count)

            for i in 0..<count {
                if weights[i] > 0 {
                    let gx = accGradX[i] / weights[i]
                    let gz = accGradZ[i] / weights[i]
                    data[i * 3] = gx
                    data[i * 3 + 1] = gz
                    data[i * 3 + 2] = atan(sqrt(gx * gx + gz * gz))
                    valid[i] = true
                }
            }

            self.data = data
            self.valid = valid
        }

        /// O(1) bilinear interpolation — no allocations, no dictionary lookups.
        /// Returns nil if the query point is outside grid bounds or near an invalid cell.
        @inline(__always)
        func lookup(x: Float, z: Float) -> (gradientX: Float, gradientZ: Float, slopeAngle: Float)? {
            let gx = (x - originX) * invCellSize
            let gz = (z - originZ) * invCellSize

            // Fast bounds check
            guard gx >= 0 && gz >= 0 else { return nil }
            let ix = Int(gx)
            let iz = Int(gz)
            guard ix < cols - 1 && iz < rows - 1 else { return nil }

            // All 4 bilinear corners must be valid
            let idx00 = iz * cols + ix
            let idx10 = idx00 + 1
            let idx01 = idx00 + cols
            let idx11 = idx01 + 1

            guard valid[idx00] && valid[idx10] && valid[idx01] && valid[idx11] else { return nil }

            // Bilinear interpolation weights
            let fx = gx - Float(ix)
            let fz = gz - Float(iz)
            let w00 = (1 - fx) * (1 - fz)
            let w10 = fx * (1 - fz)
            let w01 = (1 - fx) * fz
            let w11 = fx * fz

            let d00 = idx00 * 3, d10 = idx10 * 3, d01 = idx01 * 3, d11 = idx11 * 3

            return (
                data[d00]     * w00 + data[d10]     * w10 + data[d01]     * w01 + data[d11]     * w11,
                data[d00 + 1] * w00 + data[d10 + 1] * w10 + data[d01 + 1] * w01 + data[d11 + 1] * w11,
                data[d00 + 2] * w00 + data[d10 + 2] * w10 + data[d01 + 2] * w01 + data[d11 + 2] * w11
            )
        }
    }

    /// Full initializer with spatial grid construction
    init(gradientField: [GradientSample], maxSlope: Float, averageSlope: Float, dominantDirection: SIMD2<Float>) {
        self.gradientField = gradientField
        self.maxSlope = maxSlope
        self.averageSlope = averageSlope
        self.dominantDirection = dominantDirection
        self.spatialGrid = SpatialGrid(samples: gradientField)

        // Build regular grid for fast bilinear lookups during simulation.
        // One-time cost (~1-5ms) that eliminates ~16ms per simulation in the grid search.
        if !gradientField.isEmpty {
            self.regularGrid = RegularSlopeGrid(
                samples: gradientField,
                boundsMin: spatialGrid.minBounds,
                boundsMax: spatialGrid.maxBounds
            )
        } else {
            self.regularGrid = nil
        }
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

    /// Returns the interpolated slope at a given position.
    /// Primary path: O(1) bilinear interpolation from pre-computed regular grid.
    /// Fallback: IDW interpolation via spatial hash for edge positions.
    func slopeAt(position: SIMD3<Float>, searchRadius: Float = 0.10) -> GradientSample? {
        // Fast path: pre-computed regular grid (O(1), no allocations)
        if let grid = regularGrid,
           let (gx, gz, angle) = grid.lookup(x: position.x, z: position.z) {
            let gradient = SIMD2<Float>(gx, gz)
            return GradientSample(
                position: position,
                gradient: gradient,
                slopePercentage: simd_length(gradient) * 100,
                slopeAngle: angle
            )
        }

        // Slow path: spatial hash + IDW interpolation for positions outside regular grid
        let position2D = SIMD2<Float>(position.x, position.z)

        // Use spatial grid for fast neighbor lookup
        let candidateIndices = spatialGrid.samplesNear(position: position2D, radius: searchRadius)

        // L4 fix: if no candidates at initial radius, try progressively wider
        // search before falling back to global dominant direction
        var effectiveCandidates = candidateIndices
        if effectiveCandidates.isEmpty {
            for expandedRadius in [0.25, 0.5, 1.0] as [Float] {
                effectiveCandidates = spatialGrid.samplesNear(position: position2D, radius: expandedRadius)
                if !effectiveCandidates.isEmpty { break }
            }
        }

        guard !effectiveCandidates.isEmpty else {
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

        for index in effectiveCandidates {
            // Safety bounds check
            guard index >= 0 && index < gradientField.count else { continue }

            let sample = gradientField[index]
            let samplePos2D = SIMD2<Float>(sample.position.x, sample.position.z)
            let dist = simd_distance(position2D, samplePos2D)

            if dist < effectiveRadius {
                foundSamples = true
                // Quadratic inverse-distance: 1/(d² + ε) strongly favors nearby samples,
                // reducing gradient smearing from distant vertices
                let weight = 1.0 / (dist * dist + 0.0001)
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
