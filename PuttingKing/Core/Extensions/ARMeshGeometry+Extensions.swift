import ARKit
import simd
import os

private let logger = Logger(subsystem: "com.puttingking", category: "ARMeshGeometry")

extension ARMeshGeometry {
    /// Extract vertices as SIMD3<Float> array
    /// Uses safe memory access with stride checking
    func extractVertices() -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        let count = vertices.count
        guard count > 0 else { return result }

        result.reserveCapacity(count)

        let stride = vertices.stride
        let buffer = vertices.buffer.contents()

        // Safe extraction using stride
        for i in 0..<count {
            let offset = i * stride
            let x = buffer.load(fromByteOffset: offset, as: Float.self)
            let y = buffer.load(fromByteOffset: offset + MemoryLayout<Float>.size, as: Float.self)
            let z = buffer.load(fromByteOffset: offset + MemoryLayout<Float>.size * 2, as: Float.self)
            result.append(SIMD3<Float>(x, y, z))
        }

        return result
    }

    /// Extract normals as SIMD3<Float> array
    /// Uses safe memory access with stride checking
    func extractNormals() -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        let count = normals.count
        guard count > 0 else { return result }

        result.reserveCapacity(count)

        let stride = normals.stride
        let buffer = normals.buffer.contents()

        // Safe extraction using stride
        for i in 0..<count {
            let offset = i * stride
            let x = buffer.load(fromByteOffset: offset, as: Float.self)
            let y = buffer.load(fromByteOffset: offset + MemoryLayout<Float>.size, as: Float.self)
            let z = buffer.load(fromByteOffset: offset + MemoryLayout<Float>.size * 2, as: Float.self)
            result.append(SIMD3<Float>(x, y, z))
        }

        return result
    }

    /// Extract triangle indices with bounds validation
    func extractTriangleIndices() -> [UInt32] {
        var result: [UInt32] = []
        let faceCount = faces.count

        guard faceCount > 0 else { return result }

        // Each face has 3 indices
        result.reserveCapacity(faceCount * 3)

        let indexPointer = faces.buffer.contents()
        let bytesPerIndex = faces.bytesPerIndex
        let indicesPerFace = faces.indexCountPerPrimitive

        // Validate expected primitive type (triangles have 3 indices)
        guard indicesPerFace == 3 else {
            logger.error("Unexpected indices per face: \(indicesPerFace)")
            return result
        }

        for faceIndex in 0..<faceCount {
            let indices = extractIndices(for: faceIndex, from: indexPointer, bytesPerIndex: bytesPerIndex)
            result.append(contentsOf: indices)
        }

        return result
    }

    private func extractIndices(for faceIndex: Int, from pointer: UnsafeRawPointer, bytesPerIndex: Int) -> [UInt32] {
        let baseOffset = faceIndex * faces.indexCountPerPrimitive * bytesPerIndex

        var indices: [UInt32] = []
        indices.reserveCapacity(3)

        for i in 0..<3 {
            let offset = baseOffset + i * bytesPerIndex
            if bytesPerIndex == 4 {
                let value = pointer.load(fromByteOffset: offset, as: UInt32.self)
                indices.append(value)
            } else if bytesPerIndex == 2 {
                let value = pointer.load(fromByteOffset: offset, as: UInt16.self)
                indices.append(UInt32(value))
            } else {
                // Fallback for unexpected byte sizes
                let value = pointer.load(fromByteOffset: offset, as: UInt8.self)
                indices.append(UInt32(value))
            }
        }

        return indices
    }

    /// Extract face classifications if available
    func extractClassifications() -> [ARMeshClassification]? {
        guard let classificationBuffer = classification else { return nil }

        var result: [ARMeshClassification] = []
        let count = faces.count
        guard count > 0 else { return result }

        result.reserveCapacity(count)

        let pointer = classificationBuffer.buffer.contents()
        let bytesPerElement = classificationBuffer.stride

        // L8 fix: handle different classification buffer element sizes
        for i in 0..<count {
            let offset = i * bytesPerElement
            let rawValue: Int
            if bytesPerElement >= 4 {
                rawValue = Int(pointer.load(fromByteOffset: offset, as: UInt32.self))
            } else if bytesPerElement >= 2 {
                rawValue = Int(pointer.load(fromByteOffset: offset, as: UInt16.self))
            } else {
                rawValue = Int(pointer.load(fromByteOffset: offset, as: UInt8.self))
            }
            result.append(ARMeshClassification(rawValue: rawValue) ?? .none)
        }

        return result
    }
}

extension ARMeshAnchor {
    /// Get all vertices in world coordinates
    func worldVertices() -> [SIMD3<Float>] {
        let localVertices = geometry.extractVertices()
        return localVertices.map { transform.transformPoint($0) }
    }

    /// Get all normals in world coordinates
    func worldNormals() -> [SIMD3<Float>] {
        let localNormals = geometry.extractNormals()
        return localNormals.map { simd_normalize(transform.transformDirection($0)) }
    }
}
