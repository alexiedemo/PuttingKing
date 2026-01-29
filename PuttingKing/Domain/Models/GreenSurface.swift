import Foundation
import simd

/// Represents the reconstructed green surface from LiDAR data
struct GreenSurface {
    let id: UUID
    let vertices: [SIMD3<Float>]
    let triangles: [UInt32]
    let normals: [SIMD3<Float>]
    let boundingBox: BoundingBox
    let captureDate: Date
    let qualityScore: Float

    struct BoundingBox {
        let min: SIMD3<Float>
        let max: SIMD3<Float>

        var center: SIMD3<Float> {
            (min + max) / 2
        }

        var extent: SIMD3<Float> {
            max - min
        }

        var area: Float {
            extent.x * extent.z
        }
    }

    var vertexCount: Int {
        vertices.count
    }

    var triangleCount: Int {
        triangles.count / 3
    }

    /// Creates an empty green surface
    static var empty: GreenSurface {
        GreenSurface(
            id: UUID(),
            vertices: [],
            triangles: [],
            normals: [],
            boundingBox: BoundingBox(min: .zero, max: .zero),
            captureDate: Date(),
            qualityScore: 0
        )
    }
}

/// Position markers for hole and ball
struct HolePosition: Equatable {
    let worldPosition: SIMD3<Float>
    let timestamp: Date

    init(worldPosition: SIMD3<Float>, timestamp: Date = Date()) {
        self.worldPosition = worldPosition
        self.timestamp = timestamp
    }

    static let holeRadius: Float = 0.054 // 108mm diameter
}

struct BallPosition: Equatable {
    let worldPosition: SIMD3<Float>
    let timestamp: Date

    init(worldPosition: SIMD3<Float>, timestamp: Date = Date()) {
        self.worldPosition = worldPosition
        self.timestamp = timestamp
    }

    static let ballRadius: Float = 0.02135 // 42.7mm diameter
}
