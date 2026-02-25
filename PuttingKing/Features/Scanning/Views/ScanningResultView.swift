import SwiftUI

/// Displays the putting result stats after analysis
struct ScanningResultView: View {
    let line: PuttingLine
    let useMetricUnits: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Main stats row
            HStack(spacing: 0) {
                statItem(
                    title: "DISTANCE",
                    value: line.formattedDistance(useMetric: useMetricUnits),
                    color: .white
                )
                
                verticalDivider
                
                statItem(
                    title: "BREAK",
                    value: line.estimatedBreak.breakDescription,
                    color: breakColor(line.estimatedBreak.breakDirection)
                )
                
                verticalDivider
                
                statItem(
                    title: "SPEED",
                    value: line.recommendedSpeed.description,
                    color: speedColor(line.recommendedSpeed)
                )
            }
            .padding(.vertical, DesignSystem.Spacing.md)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .glassCard()
            
            // Confidence badge
            HStack(spacing: 6) {
                Image(systemName: confidenceIcon)
                    .font(.system(size: 12))
                Text("\(Int(min(max(line.confidence, 0), 1.0) * 100))% confidence")
                    .font(DesignSystem.Typography.caption)
            }
            .foregroundColor(confidenceColor)
            .pillBadge(backgroundColor: confidenceColor)
            
            // Aim instruction
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .semibold))
                Text("Aim at the target point")
                    .font(DesignSystem.Typography.body)
            }
            .foregroundColor(.yellow)
            .pillBadge(backgroundColor: .yellow)
        }
    }
    
    // MARK: - Subviews
    
    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 50)
    }
    
    private func statItem(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundColor(.white.opacity(0.6))
                .tracking(1)
            
            Text(value)
                .font(DesignSystem.Typography.title)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Computed Properties
    
    private var confidenceIcon: String {
        if line.confidence >= 0.8 { return "checkmark.seal.fill" }
        if line.confidence >= 0.6 { return "checkmark.circle.fill" }
        return "exclamationmark.circle.fill"
    }
    
    private var confidenceColor: Color {
        DesignSystem.Colors.confidence(line.confidence)
    }
    
    private func breakColor(_ direction: PuttingLine.BreakDirection) -> Color {
        switch direction {
        case .left: return DesignSystem.Colors.breakLeft
        case .right: return DesignSystem.Colors.breakRight
        case .straight: return DesignSystem.Colors.breakStraight
        }
    }
    
    private func speedColor(_ speed: PuttingLine.PuttSpeed) -> Color {
        switch speed {
        case .gentle: return DesignSystem.Colors.speedGentle
        case .moderate: return DesignSystem.Colors.speedModerate
        case .firm: return DesignSystem.Colors.speedFirm
        }
    }
}
