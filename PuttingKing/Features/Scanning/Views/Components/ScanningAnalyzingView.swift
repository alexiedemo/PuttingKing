import SwiftUI

/// Analysis progress indicator with step checklist
struct ScanningAnalyzingView: View {
    let progress: Double
    @Binding var pulseAnimation: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            // Circular progress indicator
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)
                
                // Progress circle
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [.green, .green.opacity(0.7)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                
                // Animated rings
                ForEach(0..<3) { index in
                    Circle()
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        .frame(width: CGFloat(90 + index * 15), height: CGFloat(90 + index * 15))
                        .scaleEffect(pulseAnimation ? 1.1 : 0.9)
                        .opacity(pulseAnimation ? 0 : 0.6)
                        .animation(
                            Animation.easeInOut(duration: 1.5)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.3),
                            value: pulseAnimation
                        )
                }
                
                // Center icon
                Image(systemName: "waveform")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
            }
            
            Text("Analyzing green topology...")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(.white)
            
            // Progress steps
            VStack(spacing: 6) {
                stepRow(step: 1, text: "Reconstructing surface", done: progress > 0.2)
                stepRow(step: 2, text: "Analyzing slopes", done: progress > 0.5)
                stepRow(step: 3, text: "Calculating path", done: progress > 0.8)
            }
        }
        .padding(28)
        .glassCard(cornerRadius: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing putting line, \(Int(progress * 100)) percent complete")
        .onAppear {
            pulseAnimation = true
        }
    }
    
    private func stepRow(step: Int, text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundColor(done ? .green : .white.opacity(0.4))
            
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(done ? .white : .white.opacity(0.5))
            
            Spacer()
        }
    }
}
