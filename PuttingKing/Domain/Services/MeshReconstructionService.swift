import Foundation
import ARKit
import simd

/// Protocol for mesh reconstruction
protocol MeshReconstructionServiceProtocol {
    func reconstructSurface(from anchors: [ARMeshAnchor]) async throws -> GreenSurface
    func filterGreenMesh(from surface: GreenSurface, around center: SIMD3<Float>, radius: Float) -> GreenSurface
}

/// Service that reconstructs a unified green surface from LiDAR mesh data
final class MeshReconstructionService: MeshReconstructionServiceProtocol {

    /// Reconstruct a unified surface from mesh anchors
    func reconstructSurface(from anchors: [ARMeshAnchor]) async throws -> GreenSurface {
        guard !anchors.isEmpty else {
            throw ScanError.insufficientData
        }

        // Step 1: Extract and transform all vertices to world space with deduplication
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allTriangles: [UInt32] = []
        
        // Map unique vertices to their index to prevent duplicates.
        // Uses quantized keys (rounded to 1mm grid) for cross-anchor stitching (fixes M1).
        var vertexMap: [QuantizedVertex: UInt32] = [:]

        for anchor in anchors {
            // L6 fix: check for Task cancellation between anchor processing
            try Task.checkCancellation()

            let worldVertices = anchor.worldVertices()
            let worldNormals = anchor.worldNormals()
            let triangles = anchor.geometry.extractTriangleIndices()
            let classifications = anchor.geometry.extractClassifications()

            // Filter for horizontal surfaces (ground/green)
            for i in stride(from: 0, to: triangles.count, by: 3) {
                // Bounds check to prevent crashes
                guard i + 2 < triangles.count else { continue }

                let idx0 = Int(triangles[i])
                let idx1 = Int(triangles[i + 1])
                let idx2 = Int(triangles[i + 2])

                // Validate indices are within bounds
                guard idx0 < worldVertices.count && idx1 < worldVertices.count && idx2 < worldVertices.count,
                      idx0 < worldNormals.count && idx1 < worldNormals.count && idx2 < worldNormals.count else {
                    continue
                }

                // Check if this face is roughly horizontal
                let normal0 = worldNormals[idx0]
                let normal1 = worldNormals[idx1]
                let normal2 = worldNormals[idx2]
                let sumNormal = normal0 + normal1 + normal2
                let sumLength = simd_length(sumNormal)
                guard sumLength > 0.001 else { continue }
                let avgNormal = sumNormal / sumLength

                // Check if face is classified as floor/ground or is horizontal
                let isHorizontal = avgNormal.y > 0.7 // cos(45 degrees)

                var isGround = isHorizontal
                if let classifications = classifications {
                    let faceIndex = i / 3
                    if faceIndex < classifications.count {
                        let classification = classifications[faceIndex]
                        isGround = isHorizontal && (classification == .floor || classification == .none)
                    }
                }

                if isGround {
                    // Add vertices with deduplication
                    let v0 = worldVertices[idx0]
                    let v1 = worldVertices[idx1]
                    let v2 = worldVertices[idx2]
                    
                    let n0 = worldNormals[idx0]
                    let n1 = worldNormals[idx1]
                    let n2 = worldNormals[idx2]

                    let newIdx0 = getOrAddVertex(v0, normal: n0, map: &vertexMap, vertices: &allVertices, normals: &allNormals)
                    let newIdx1 = getOrAddVertex(v1, normal: n1, map: &vertexMap, vertices: &allVertices, normals: &allNormals)
                    let newIdx2 = getOrAddVertex(v2, normal: n2, map: &vertexMap, vertices: &allVertices, normals: &allNormals)

                    allTriangles.append(newIdx0)
                    allTriangles.append(newIdx1)
                    allTriangles.append(newIdx2)
                }
            }
        }

        guard allVertices.count >= 3 else {
            throw ScanError.meshReconstructionFailed
        }

        // Step 2: Apply smoothing — 3 iterations with increased Y-axis smoothing.
        // LiDAR depth noise (1-2cm) is comparable to real slope signals (1-3cm/m).
        // Real slopes are spatially correlated across many vertices; noise is random,
        // so additional smoothing averages out noise while preserving true contours.
        let smoothedVertices = laplacianSmooth(
            vertices: allVertices,
            triangles: allTriangles,
            iterations: 3,
            lambda: 0.3,
            yFactor: 0.5
        )

        // Step 3: Recalculate normals after smoothing
        let recalculatedNormals = calculateNormals(vertices: smoothedVertices, triangles: allTriangles)

        // Step 4: Calculate bounding box
        let boundingBox = calculateBoundingBox(smoothedVertices)

        // Step 5: Calculate quality score
        let qualityScore = calculateQualityScore(
            vertexCount: smoothedVertices.count,
            area: boundingBox.area
        )

        return GreenSurface(
            id: UUID(),
            vertices: smoothedVertices,
            triangles: allTriangles,
            normals: recalculatedNormals,
            boundingBox: boundingBox,
            captureDate: Date(),
            qualityScore: qualityScore
        )
    }

    /// Filter mesh to only include area around a center point
    func filterGreenMesh(from surface: GreenSurface, around center: SIMD3<Float>, radius: Float) -> GreenSurface {
        var filteredVertices: [SIMD3<Float>] = []
        var filteredNormals: [SIMD3<Float>] = []
        var filteredTriangles: [UInt32] = []
        var indexMap: [Int: UInt32] = [:]

        // Filter triangles within radius
        for i in stride(from: 0, to: surface.triangles.count, by: 3) {
            guard i + 2 < surface.triangles.count else { continue }

            let idx0 = Int(surface.triangles[i])
            let idx1 = Int(surface.triangles[i + 1])
            let idx2 = Int(surface.triangles[i + 2])

            // Validate indices are within bounds
            guard idx0 < surface.vertices.count && idx1 < surface.vertices.count && idx2 < surface.vertices.count,
                  idx0 < surface.normals.count && idx1 < surface.normals.count && idx2 < surface.normals.count else {
                continue
            }

            let v0 = surface.vertices[idx0]
            let v1 = surface.vertices[idx1]
            let v2 = surface.vertices[idx2]

            // Check if triangle center is within radius
            let triangleCenter = (v0 + v1 + v2) / 3.0
            let distance = triangleCenter.horizontalDistance(to: center)

            if distance <= radius {
                // Map old indices to new indices
                for oldIdx in [idx0, idx1, idx2] {
                    if indexMap[oldIdx] == nil {
                        let newIdx = UInt32(filteredVertices.count)
                        indexMap[oldIdx] = newIdx
                        filteredVertices.append(surface.vertices[oldIdx])
                        filteredNormals.append(surface.normals[oldIdx])
                    }
                    filteredTriangles.append(indexMap[oldIdx]!)
                }
            }
        }

        // M11 fix: guard against empty filtered surface — if no triangles survived
        // the radius filter, return the original surface rather than an empty one
        // that would cause downstream failures in slope analysis and simulation.
        guard filteredVertices.count >= 3 else {
            print("[MeshReconstruction] filterGreenMesh: no vertices within radius \(radius)m of center, returning original surface")
            return surface
        }

        let boundingBox = calculateBoundingBox(filteredVertices)

        return GreenSurface(
            id: surface.id,
            vertices: filteredVertices,
            triangles: filteredTriangles,
            normals: filteredNormals,
            boundingBox: boundingBox,
            captureDate: surface.captureDate,
            qualityScore: surface.qualityScore
        )
    }

    // MARK: - Helper Methods

    /// Quantized vertex key for deduplication — rounds to 1mm grid for cross-anchor stitching (M1 fix)
    private struct QuantizedVertex: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32

        init(_ v: SIMD3<Float>) {
            // Round to 1mm (0.001m) grid
            x = Int32((v.x * 1000).rounded())
            y = Int32((v.y * 1000).rounded())
            z = Int32((v.z * 1000).rounded())
        }
    }

    /// Get index of existing vertex or add new one (uses quantized keys for fuzzy dedup)
    private func getOrAddVertex(
        _ position: SIMD3<Float>,
        normal: SIMD3<Float>,
        map: inout [QuantizedVertex: UInt32],
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>]
    ) -> UInt32 {
        let key = QuantizedVertex(position)
        if let existingIdx = map[key] {
            // Average the normal for shared vertices (better interpolation)
            normals[Int(existingIdx)] = simd_normalize(normals[Int(existingIdx)] + normal)
            return existingIdx
        }

        let newIdx = UInt32(vertices.count)
        vertices.append(position)
        normals.append(normal)
        map[key] = newIdx
        return newIdx
    }

    // MARK: - Private Methods

    /// Apply Laplacian smoothing to reduce noise
    private func laplacianSmooth(
        vertices: [SIMD3<Float>],
        triangles: [UInt32],
        iterations: Int,
        lambda: Float,
        yFactor: Float = 0.5
    ) -> [SIMD3<Float>] {
        guard vertices.count > 0 else { return vertices }

        // Build adjacency list using Sets for O(N log N) deduplication
        // (Old approach used Array.contains() — O(N^2) total, causing freezes on large meshes)
        var neighborSets: [Set<Int>] = Array(repeating: Set<Int>(), count: vertices.count)

        for i in stride(from: 0, to: triangles.count, by: 3) {
            guard i + 2 < triangles.count else { continue }
            let i0 = Int(triangles[i])
            let i1 = Int(triangles[i + 1])
            let i2 = Int(triangles[i + 2])
            guard i0 < vertices.count && i1 < vertices.count && i2 < vertices.count else { continue }

            // Sets handle duplication automatically in O(1) amortized
            neighborSets[i0].insert(i1); neighborSets[i0].insert(i2)
            neighborSets[i1].insert(i0); neighborSets[i1].insert(i2)
            neighborSets[i2].insert(i0); neighborSets[i2].insert(i1)
        }

        // Convert to arrays for indexed access during the smooth passes
        let neighbors: [[Int]] = neighborSets.map { Array($0) }

        var current = vertices

        for _ in 0..<iterations {
            var smoothed = current

            for i in 0..<current.count {
                guard !neighbors[i].isEmpty else { continue }

                // Calculate centroid of neighbors
                let neighborSum = neighbors[i].reduce(SIMD3<Float>.zero) { sum, idx in
                    sum + current[idx]
                }
                let centroid = neighborSum / Float(neighbors[i].count)

                // Move vertex toward centroid — reduced Y-axis lambda to preserve
                // subtle green contours needed for break calculation (M2 fix)
                let delta = centroid - current[i]
                smoothed[i] = current[i] + SIMD3<Float>(
                    lambda * delta.x,
                    lambda * yFactor * delta.y,  // Parameterized Y smoothing (0.5 = 50%)
                    lambda * delta.z
                )
            }

            current = smoothed
        }

        return current
    }

    /// Calculate normals from vertices and triangles
    /// Uses area-weighted accumulation: large stable triangles contribute more than tiny slivers,
    /// reducing noise bias from degenerate mesh artifacts. Degenerate triangles are skipped entirely.
    private func calculateNormals(vertices: [SIMD3<Float>], triangles: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        // Accumulate area-weighted face normals at each vertex.
        // The un-normalized cross product magnitude = 2× triangle area,
        // so larger faces naturally contribute more weight.
        for i in stride(from: 0, to: triangles.count, by: 3) {
            guard i + 2 < triangles.count else { continue }
            let i0 = Int(triangles[i])
            let i1 = Int(triangles[i + 1])
            let i2 = Int(triangles[i + 2])
            guard i0 < vertices.count && i1 < vertices.count && i2 < vertices.count else { continue }

            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let faceNormal = simd_cross(edge1, edge2)

            // Skip degenerate triangles (near-zero area) instead of defaulting to (0,1,0)
            guard simd_length(faceNormal) > 0.0001 else { continue }

            // Ensure normal points up — use UN-normalized vector to preserve area weighting
            let upwardNormal = faceNormal.y >= 0 ? faceNormal : -faceNormal

            normals[i0] += upwardNormal
            normals[i1] += upwardNormal
            normals[i2] += upwardNormal
        }

        // Normalize accumulated area-weighted normals
        for i in 0..<normals.count {
            let len = simd_length(normals[i])
            if len > 0.0001 {
                normals[i] = normals[i] / len
            } else {
                normals[i] = SIMD3<Float>(0, 1, 0) // Default up for isolated vertices
            }
        }

        return normals
    }

    /// Calculate bounding box
    private func calculateBoundingBox(_ vertices: [SIMD3<Float>]) -> GreenSurface.BoundingBox {
        guard !vertices.isEmpty else {
            return GreenSurface.BoundingBox(min: .zero, max: .zero)
        }

        var minPoint = vertices[0]
        var maxPoint = vertices[0]

        for vertex in vertices {
            minPoint = simd_min(minPoint, vertex)
            maxPoint = simd_max(maxPoint, vertex)
        }

        return GreenSurface.BoundingBox(min: minPoint, max: maxPoint)
    }

    /// Calculate quality score
    private func calculateQualityScore(vertexCount: Int, area: Float) -> Float {
        // Target density: ~1000 vertices per square meter
        let density = Float(vertexCount) / max(area, 0.1)
        let densityScore = min(density / 1000.0, 1.0)

        // Target area: at least 10 square meters
        let areaScore = min(area / 10.0, 1.0)

        return densityScore * 0.6 + areaScore * 0.4
    }
}
