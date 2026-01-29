import Foundation
import simd

extension SIMD3 where Scalar == Float {
    /// Returns the XZ components as a 2D vector
    var xz: SIMD2<Float> {
        SIMD2<Float>(x, z)
    }

    /// Creates a 3D vector from XZ with Y = 0
    static func fromXZ(_ xz: SIMD2<Float>, y: Float = 0) -> SIMD3<Float> {
        SIMD3<Float>(xz.x, y, xz.y)
    }

    /// Distance to another point
    func distance(to other: SIMD3<Float>) -> Float {
        simd_distance(self, other)
    }

    /// Horizontal distance (ignoring Y)
    func horizontalDistance(to other: SIMD3<Float>) -> Float {
        simd_distance(self.xz, other.xz)
    }
}

extension SIMD2 where Scalar == Float {
    /// Rotate by angle (radians)
    func rotated(by angle: Float) -> SIMD2<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(
            x * c - y * s,
            x * s + y * c
        )
    }

    /// Perpendicular vector (rotated 90 degrees counter-clockwise)
    var perpendicular: SIMD2<Float> {
        SIMD2<Float>(-y, x)
    }
}

extension simd_float4x4 {
    /// Extract translation component
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Extract 3x3 rotation matrix
    var rotation3x3: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z),
            SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z),
            SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        )
    }

    /// Transform a point
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let homogeneous = SIMD4<Float>(point.x, point.y, point.z, 1.0)
        let transformed = self * homogeneous
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    /// Transform a direction (without translation)
    func transformDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        rotation3x3 * direction
    }
}
