import SwiftUI

/// Animated crosshair overlay for marking positions
struct ScanningCrosshairView: View {
    let scanState: ScanSession.ScanState
    @Binding var scale: CGFloat
    
    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(stateColor.opacity(0.3), lineWidth: 2)
                .frame(width: 80, height: 80)
                .scaleEffect(scale)
            
            // Inner ring
            Circle()
                .stroke(stateColor, lineWidth: 2)
                .frame(width: 40, height: 40)
            
            // Center dot
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            
            // Crosshair lines
            Group {
                Rectangle()
                    .fill(stateColor)
                    .frame(width: 1, height: 60)
                Rectangle()
                    .fill(stateColor)
                    .frame(width: 60, height: 1)
            }
        }
        .accessibilityLabel("Crosshair for marking position")
        .accessibilityHint(stateHint)
    }
    
    private var stateColor: Color {
        switch scanState {
        case .markingHole: return .cyan
        case .scanningGreen: return .green
        case .markingBall: return .yellow
        default: return .white
        }
    }
    
    private var stateHint: String {
        switch scanState {
        case .markingHole: return "Point at the hole to mark it"
        case .markingBall: return "Point at your ball to mark it"
        default: return "Position indicator"
        }
    }
}
