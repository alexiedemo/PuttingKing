import Foundation
import simd

/// The calculated optimal putting path
struct PuttingLine {
    let id: UUID
    let pathPoints: [PathPoint]
    let aimPoint: SIMD3<Float>
    let estimatedBreak: BreakInfo
    let recommendedSpeed: PuttSpeed
    let confidence: Float
    let distance: Float

    struct PathPoint {
        let position: SIMD3<Float>
        let velocity: SIMD3<Float>
        let timestamp: TimeInterval

        var speed: Float {
            simd_length(velocity)
        }
    }

    struct BreakInfo {
        let totalBreak: Float
        let breakDirection: BreakDirection
        let breakProfile: [Float]

        var breakDescription: String {
            // Less than 2cm is effectively straight
            guard totalBreak > 0.02 else { return "Straight" }

            let breakCm = Int(totalBreak * 100)

            // Use more readable format for larger breaks
            if breakCm >= 100 {
                let breakM = Float(breakCm) / 100.0
                switch breakDirection {
                case .left:
                    return String(format: "%.1fm left", breakM)
                case .right:
                    return String(format: "%.1fm right", breakM)
                case .straight:
                    return "Straight"
                }
            } else {
                switch breakDirection {
                case .left:
                    return "\(breakCm)cm left"
                case .right:
                    return "\(breakCm)cm right"
                case .straight:
                    return "Straight"
                }
            }
        }

        /// Short format for UI
        var shortDescription: String {
            guard totalBreak > 0.02 else { return "Straight" }

            let breakCm = Int(totalBreak * 100)
            switch breakDirection {
            case .left:
                return "\(breakCm)cm L"
            case .right:
                return "\(breakCm)cm R"
            case .straight:
                return "Straight"
            }
        }

        static var straight: BreakInfo {
            BreakInfo(totalBreak: 0, breakDirection: .straight, breakProfile: [])
        }
    }

    enum BreakDirection: String {
        case left
        case right
        case straight
    }

    enum PuttSpeed: String, CaseIterable {
        case gentle
        case moderate
        case firm

        var description: String {
            switch self {
            case .gentle: return "Gentle"
            case .moderate: return "Medium"
            case .firm: return "Firm"
            }
        }

        var multiplier: Float {
            switch self {
            case .gentle: return 0.85
            case .moderate: return 1.0
            case .firm: return 1.15
            }
        }
    }

    /// Distance from ball to hole in meters
    var distanceMeters: Float {
        distance
    }

    /// Distance from ball to hole in feet
    var distanceFeet: Float {
        distance * 3.28084
    }

    /// Formatted distance string
    func formattedDistance(useMetric: Bool) -> String {
        if useMetric {
            return String(format: "%.1fm", distanceMeters)
        } else {
            return String(format: "%.0fft", distanceFeet)
        }
    }

    /// Creates an empty putting line
    static var empty: PuttingLine {
        PuttingLine(
            id: UUID(),
            pathPoints: [],
            aimPoint: .zero,
            estimatedBreak: .straight,
            recommendedSpeed: .moderate,
            confidence: 0,
            distance: 0
        )
    }
}
