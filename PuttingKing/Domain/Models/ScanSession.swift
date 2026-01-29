import Foundation
import ARKit
import simd

/// Active scanning session state
struct ScanSession {
    let id: UUID
    var state: ScanState
    var holePosition: HolePosition?
    var ballPosition: BallPosition?
    var meshAnchors: [ARMeshAnchor]
    var scanProgress: Float
    var scannedArea: Float

    enum ScanState: Equatable {
        case idle
        case markingHole
        case scanningGreen
        case markingBall
        case analyzing
        case displayingResult
        case error(ScanError)

        var instruction: String {
            switch self {
            case .idle:
                return "Tap Start to begin"
            case .markingHole:
                return "Walk to the hole and tap to mark it"
            case .scanningGreen:
                return "Walk slowly back to your ball while scanning"
            case .markingBall:
                return "Point at your ball and tap to confirm"
            case .analyzing:
                return "Analyzing green and calculating break..."
            case .displayingResult:
                return "Aim at the target point"
            case .error(let error):
                return error.message
            }
        }

        var canMarkHole: Bool {
            self == .markingHole
        }

        var canMarkBall: Bool {
            self == .scanningGreen || self == .markingBall
        }

        var isScanning: Bool {
            self == .scanningGreen
        }
    }

    init(
        id: UUID = UUID(),
        state: ScanState = .idle,
        holePosition: HolePosition? = nil,
        ballPosition: BallPosition? = nil,
        meshAnchors: [ARMeshAnchor] = [],
        scanProgress: Float = 0,
        scannedArea: Float = 0
    ) {
        self.id = id
        self.state = state
        self.holePosition = holePosition
        self.ballPosition = ballPosition
        self.meshAnchors = meshAnchors
        self.scanProgress = scanProgress
        self.scannedArea = scannedArea
    }

    var vertexCount: Int {
        meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
    }

    var hasMinimumData: Bool {
        scanProgress >= 0.3 && vertexCount > 1000
    }
}

enum ScanError: Error, Equatable {
    case lidarUnavailable
    case cameraPermissionDenied
    case meshReconstructionFailed
    case analysisFailedNoPath
    case insufficientData
    case unknown(String)

    var message: String {
        switch self {
        case .lidarUnavailable:
            return "LiDAR is not available on this device"
        case .cameraPermissionDenied:
            return "Camera permission is required"
        case .meshReconstructionFailed:
            return "Failed to reconstruct green surface"
        case .analysisFailedNoPath:
            return "Could not calculate putting path"
        case .insufficientData:
            return "Not enough scan data. Keep scanning."
        case .unknown(let msg):
            return msg
        }
    }
}
