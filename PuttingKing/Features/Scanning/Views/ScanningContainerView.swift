import SwiftUI
import UIKit

struct ScanningContainerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var viewModel: ScanningViewModel
    @StateObject private var arSessionManager = ARSessionManager()
    @State private var showCrosshair = true
    @State private var pulseAnimation = false
    @State private var crosshairScale: CGFloat = 1.0
    @State private var showPositionError = false
    @State private var analysisProgress: Double = 0
    @State private var analysisTimer: Timer?

    init() {
        _viewModel = StateObject(wrappedValue: ScanningViewModel(settings: AppSettings.load()))
    }

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(viewModel: viewModel, arSessionManager: arSessionManager)
                .ignoresSafeArea()
                .onAppear {
                    viewModel.startNewScan()
                    startCrosshairAnimation()
                }
                .onDisappear {
                    // Clean up timer to prevent memory leaks
                    analysisTimer?.invalidate()
                    analysisTimer = nil
                }

            // Crosshair overlay
            if showCrosshair && (viewModel.scanState == .markingHole || viewModel.scanState == .scanningGreen || viewModel.scanState == .markingBall) {
                crosshairView
            }

            // Overlays
            VStack(spacing: 0) {
                // Top bar
                topBar
                    .padding(.top, 8)

                Spacer()

                // State-specific UI
                stateSpecificUI
                    .padding(.bottom, 16)

                // Instruction banner
                instructionBanner
                    .padding(.bottom, 12)

                // Bottom controls
                bottomControls
            }

            // Scanning overlay effect
            if viewModel.scanState == .scanningGreen {
                scanningOverlayEffect
            }

            // Position error toast
            if showPositionError {
                positionErrorToast
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }

            // AR tracking warning
            if arSessionManager.trackingState != .normal && viewModel.scanState != .idle && viewModel.scanState != .displayingResult {
                trackingWarningBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .statusBar(hidden: true)
        .onChange(of: viewModel.scanState) { newState in
            handleStateChange(newState)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                // Resume session if we were previously running
                if viewModel.scanState != .idle && viewModel.scanState != .error(.lidarUnavailable) {
                    arSessionManager.resumeSession()
                }
            case .background, .inactive:
                arSessionManager.pauseSession()
            @unknown default:
                break
            }
        }
    }

    // MARK: - State Change Handling

    private func handleStateChange(_ newState: ScanSession.ScanState) {
        guard appState.settings.hapticFeedbackEnabled else {
            // Still handle non-haptic state changes
            if newState == .analyzing {
                startAnalysisProgress()
            } else if newState == .displayingResult || newState == .error(ScanError.insufficientData) {
                stopAnalysisProgress()
            }
            updateCrosshairState()
            return
        }

        switch newState {
        case .scanningGreen:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        case .markingBall:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        case .analyzing:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            startAnalysisProgress()
        case .displayingResult:
            // Provide confidence-based feedback
            if let line = viewModel.puttingLine {
                if line.confidence >= 0.8 {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                } else if line.confidence >= 0.6 {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                } else {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.warning)
                }
            } else {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
            stopAnalysisProgress()
        case .error:
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            stopAnalysisProgress()
        default:
            break
        }

        updateCrosshairState()
    }

    private func startAnalysisProgress() {
        analysisProgress = 0
        // Invalidate existing timer to prevent multiple timers
        analysisTimer?.invalidate()
        // Timer closure for SwiftUI struct - state binding handles updates
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            withAnimation(.linear(duration: 0.1)) {
                // Simulate progress (asymptotic approach to 95%)
                analysisProgress += (0.95 - analysisProgress) * 0.08
            }
        }
    }

    private func stopAnalysisProgress() {
        analysisTimer?.invalidate()
        analysisTimer = nil
        withAnimation(.easeOut(duration: 0.3)) {
            analysisProgress = 1.0
        }
    }

    // MARK: - Crosshair

    private var crosshairView: some View {
        ZStack {
            // Shadow/outline for contrast on any background
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: 4)
                .frame(width: crosshairSize, height: crosshairSize)

            // Outer ring
            Circle()
                .stroke(crosshairColor, lineWidth: 2)
                .frame(width: crosshairSize, height: crosshairSize)
                .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                .opacity(pulseAnimation ? 0.6 : 1.0)

            // Inner ring with shadow
            Circle()
                .stroke(Color.black.opacity(0.4), lineWidth: 3)
                .frame(width: crosshairSize * 0.5, height: crosshairSize * 0.5)
            Circle()
                .stroke(crosshairColor, lineWidth: 1.5)
                .frame(width: crosshairSize * 0.5, height: crosshairSize * 0.5)

            // Center dot with outline
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 12, height: 12)
            Circle()
                .fill(crosshairColor)
                .frame(width: 8, height: 8)

            // Crosshair lines with shadow
            Group {
                // Vertical lines
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 3, height: crosshairSize * 0.3)
                    .offset(y: -crosshairSize * 0.4)
                Rectangle()
                    .fill(crosshairColor)
                    .frame(width: 1.5, height: crosshairSize * 0.3)
                    .offset(y: -crosshairSize * 0.4)

                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: 3, height: crosshairSize * 0.3)
                    .offset(y: crosshairSize * 0.4)
                Rectangle()
                    .fill(crosshairColor)
                    .frame(width: 1.5, height: crosshairSize * 0.3)
                    .offset(y: crosshairSize * 0.4)

                // Horizontal lines
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: crosshairSize * 0.3, height: 3)
                    .offset(x: -crosshairSize * 0.4)
                Rectangle()
                    .fill(crosshairColor)
                    .frame(width: crosshairSize * 0.3, height: 1.5)
                    .offset(x: -crosshairSize * 0.4)

                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .frame(width: crosshairSize * 0.3, height: 3)
                    .offset(x: crosshairSize * 0.4)
                Rectangle()
                    .fill(crosshairColor)
                    .frame(width: crosshairSize * 0.3, height: 1.5)
                    .offset(x: crosshairSize * 0.4)
            }
        }
        .scaleEffect(crosshairScale)
        .shadow(color: crosshairColor.opacity(0.5), radius: 10)
        .accessibilityLabel("Crosshair for positioning")
        .accessibilityHint(crosshairAccessibilityHint)
    }

    private var crosshairAccessibilityHint: String {
        switch viewModel.scanState {
        case .markingHole: return "Position over the hole and tap Mark Hole"
        case .scanningGreen: return "Scan the green surface between hole and ball"
        case .markingBall: return "Position over the ball and tap Confirm"
        default: return ""
        }
    }

    private var crosshairSize: CGFloat {
        switch viewModel.scanState {
        case .markingHole: return 100
        case .scanningGreen, .markingBall: return 80
        default: return 80
        }
    }

    private var crosshairColor: Color {
        switch viewModel.scanState {
        case .markingHole: return .yellow
        case .scanningGreen: return .green
        case .markingBall: return .cyan
        default: return .white
        }
    }

    private func startCrosshairAnimation() {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            pulseAnimation = true
        }
    }

    private func updateCrosshairState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            crosshairScale = 0.8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                crosshairScale = 1.0
            }
        }
    }

    // MARK: - Warning/Error Banners

    private var positionErrorToast: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Couldn't detect surface. Move closer or to a better lit area.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.85))
            .cornerRadius(12)
            .padding(.top, 60)

            Spacer()
        }
    }

    private var trackingWarningBanner: some View {
        VStack {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: trackingWarningIcon)
                        .foregroundColor(trackingWarningColor)
                    Text(trackingWarningText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                
                // Recovery action button for limited tracking
                if case .limited = arSessionManager.trackingState {
                    Button(action: {
                        // Haptic feedback
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        
                        // Reset AR session to recalibrate
                        arSessionManager.resetSession()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Recalibrate")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(trackingWarningColor.opacity(0.4))
                        .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(trackingWarningColor.opacity(0.2))
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(trackingWarningColor.opacity(0.5), lineWidth: 1)
            )
            .padding(.top, 60)

            Spacer()
        }
    }

    private var trackingWarningIcon: String {
        switch arSessionManager.trackingState {
        case .notAvailable: return "xmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .normal: return "checkmark.circle.fill"
        }
    }

    private var trackingWarningColor: Color {
        switch arSessionManager.trackingState {
        case .notAvailable: return .red
        case .limited: return .orange
        case .normal: return .green
        }
    }

    private var trackingWarningText: String {
        switch arSessionManager.trackingState {
        case .notAvailable: return "AR tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Initializing AR tracking..."
            case .relocalizing: return "Relocating position..."
            case .excessiveMotion: return "Move device slower"
            case .insufficientFeatures: return "Point at more textured surface"
            @unknown default: return "Limited tracking"
            }
        case .normal: return "Tracking good"
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: {
                withAnimation {
                    viewModel.cancel()
                    appState.currentScreen = .home
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial.opacity(0.8))
                    .clipShape(Circle())
            }

            Spacer()

            // Scan quality indicator (during scanning)
            if viewModel.scanState == .scanningGreen {
                scanQualityIndicator
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal)
    }

    private var scanQualityIndicator: some View {
        HStack(spacing: 12) {
            // Quality with label (accessible)
            HStack(spacing: 6) {
                // Quality dots
                HStack(spacing: 3) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(qualityDotColor(index: index))
                            .frame(width: 8, height: 8)
                    }
                }

                // Quality text label
                Text(viewModel.scanQuality.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(qualityTextColor)
            }

            Divider()
                .frame(height: 20)
                .background(Color.white.opacity(0.3))

            // Point count
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formattedVertexCount)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("points")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.8))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scan quality: \(viewModel.scanQuality.rawValue), \(formattedVertexCount) points captured")
    }

    private var qualityTextColor: Color {
        switch viewModel.scanQuality {
        case .unknown, .poor: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .excellent: return .green
        }
    }

    private var formattedVertexCount: String {
        if viewModel.vertexCount >= 1000 {
            return String(format: "%.1fK", Double(viewModel.vertexCount) / 1000.0)
        }
        return "\(viewModel.vertexCount)"
    }

    private func qualityDotColor(index: Int) -> Color {
        let qualityLevel: Int
        switch viewModel.scanQuality {
        case .unknown, .poor: qualityLevel = 1
        case .fair: qualityLevel = 2
        case .good: qualityLevel = 3
        case .excellent: qualityLevel = 4
        }

        if index < qualityLevel {
            switch qualityLevel {
            case 1: return .red
            case 2: return .orange
            case 3: return .yellow
            case 4: return .green
            default: return .gray
            }
        }
        return .gray.opacity(0.4)
    }

    // MARK: - Instruction Banner

    private var instructionBanner: some View {
        HStack(spacing: 12) {
            instructionIcon
                .font(.system(size: 20))
                .foregroundColor(instructionIconColor)

            Text(viewModel.instructionText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.9))
        .cornerRadius(28)
        .shadow(color: .black.opacity(0.2), radius: 10)
    }

    private var instructionIcon: Image {
        switch viewModel.scanState {
        case .markingHole: return Image(systemName: "flag.fill")
        case .scanningGreen: return Image(systemName: "viewfinder")
        case .markingBall: return Image(systemName: "circle.fill")
        case .analyzing: return Image(systemName: "waveform")
        case .displayingResult: return Image(systemName: "checkmark.circle.fill")
        case .error: return Image(systemName: "exclamationmark.triangle.fill")
        default: return Image(systemName: "circle")
        }
    }

    private var instructionIconColor: Color {
        switch viewModel.scanState {
        case .markingHole: return .yellow
        case .scanningGreen: return .green
        case .markingBall: return .cyan
        case .analyzing: return .blue
        case .displayingResult: return .green
        case .error: return .orange
        default: return .white
        }
    }

    // MARK: - Scanning Overlay Effect

    private var scanningOverlayEffect: some View {
        GeometryReader { geometry in
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.green.opacity(0.1),
                    Color.clear,
                    Color.green.opacity(0.1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .offset(y: scanLineOffset(geometry: geometry))
            .animation(
                Animation.linear(duration: 2.0).repeatForever(autoreverses: false),
                value: viewModel.scanProgress
            )
        }
        .allowsHitTesting(false)
    }

    private func scanLineOffset(geometry: GeometryProxy) -> CGFloat {
        let progress = CGFloat(viewModel.scanProgress)
        return geometry.size.height * progress - 50
    }

    // MARK: - State Specific UI

    @ViewBuilder
    private var stateSpecificUI: some View {
        switch viewModel.scanState {
        case .scanningGreen:
            scanProgressView
                .transition(.opacity.combined(with: .move(edge: .bottom)))

        case .displayingResult:
            if let line = viewModel.puttingLine {
                resultOverlay(line: line)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

        case .analyzing:
            analyzingView
                .transition(.opacity.combined(with: .scale))

        case .error(let error):
            errorView(error: error)
                .transition(.opacity.combined(with: .scale))

        default:
            EmptyView()
        }
    }

    private var scanProgressView: some View {
        VStack(spacing: 12) {
            // Circular progress
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    .frame(width: 70, height: 70)

                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.scanProgress))
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [.green, .green.opacity(0.7)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 70, height: 70)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(viewModel.scanProgress * 100))%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Text("Scanning green...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(24)
        .background(.ultraThinMaterial.opacity(0.8))
        .cornerRadius(20)
    }

    private func resultOverlay(line: PuttingLine) -> some View {
        VStack(spacing: 12) {
            // Main stats
            HStack(spacing: 0) {
                // Distance
                statItem(
                    title: "DISTANCE",
                    value: line.formattedDistance(useMetric: appState.settings.useMetricUnits),
                    color: .white
                )

                verticalDivider

                // Break
                statItem(
                    title: "BREAK",
                    value: line.estimatedBreak.breakDescription,
                    color: breakColor(line.estimatedBreak.breakDirection)
                )

                verticalDivider

                // Speed
                statItem(
                    title: "SPEED",
                    value: line.recommendedSpeed.description,
                    color: speedColor(line.recommendedSpeed)
                )
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(.ultraThinMaterial.opacity(0.9))
            .cornerRadius(16)

            // Confidence badge
            HStack(spacing: 6) {
                Image(systemName: confidenceIcon(line.confidence))
                    .font(.system(size: 12))
                Text("\(Int(line.confidence * 100))% confidence")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(confidenceColor(line.confidence))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(confidenceColor(line.confidence).opacity(0.15))
            .cornerRadius(20)

            // Aim instruction - KEY USER GUIDANCE
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .semibold))
                Text("Aim at the target point")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.yellow)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.2))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
            )
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 50)
    }

    private func statItem(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .tracking(1)

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func breakColor(_ direction: PuttingLine.BreakDirection) -> Color {
        switch direction {
        case .left: return .cyan
        case .right: return .orange
        case .straight: return .green
        }
    }

    private func speedColor(_ speed: PuttingLine.PuttSpeed) -> Color {
        switch speed {
        case .gentle: return .cyan
        case .moderate: return .green
        case .firm: return .orange
        }
    }

    private func confidenceIcon(_ confidence: Float) -> String {
        if confidence >= 0.8 { return "checkmark.seal.fill" }
        if confidence >= 0.6 { return "checkmark.circle.fill" }
        return "exclamationmark.circle.fill"
    }

    private func confidenceColor(_ confidence: Float) -> Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.6 { return .yellow }
        return .orange
    }

    private var analyzingView: some View {
        VStack(spacing: 16) {
            // Circular progress indicator
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    .frame(width: 80, height: 80)

                // Progress circle
                Circle()
                    .trim(from: 0, to: analysisProgress)
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

                // Animated rings behind
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            // Progress steps
            VStack(spacing: 6) {
                analysisStepRow(step: 1, text: "Reconstructing surface", done: analysisProgress > 0.2)
                analysisStepRow(step: 2, text: "Analyzing slopes", done: analysisProgress > 0.5)
                analysisStepRow(step: 3, text: "Calculating path", done: analysisProgress > 0.8)
            }
        }
        .padding(28)
        .background(.ultraThinMaterial.opacity(0.9))
        .cornerRadius(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing putting line, \(Int(analysisProgress * 100)) percent complete")
    }

    private func analysisStepRow(step: Int, text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundColor(done ? .green : .white.opacity(0.4))

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(done ? .white : .white.opacity(0.5))

            Spacer()
        }
    }

    private func errorView(error: ScanError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text(error.message)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Button(action: {
                withAnimation {
                    viewModel.startNewScan()
                }
            }) {
                Text("Try Again")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .cornerRadius(24)
            }
        }
        .padding(28)
        .background(.ultraThinMaterial.opacity(0.9))
        .cornerRadius(20)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            switch viewModel.scanState {
            case .markingHole:
                mainActionButton(
                    title: "Mark Hole",
                    icon: "flag.fill",
                    color: .yellow
                ) {
                    markHoleAction()
                }

            case .scanningGreen:
                secondaryButton(title: "Redo", icon: "arrow.uturn.backward") {
                    withAnimation {
                        viewModel.redoHole()
                    }
                }

                VStack(spacing: 6) {
                    mainActionButton(
                        title: "Mark Ball",
                        icon: "circle.fill",
                        color: .cyan,
                        disabled: !viewModel.canMarkBall
                    ) {
                        markBallAction()
                    }

                    // Show why button is disabled
                    if !viewModel.canMarkBall {
                        Text("Scan at least 20% first")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

            case .markingBall:
                secondaryButton(title: "Back", icon: "arrow.left") {
                    withAnimation {
                        viewModel.startNewPutt()
                    }
                }

                mainActionButton(
                    title: "Confirm",
                    icon: "checkmark",
                    color: .green
                ) {
                    withAnimation {
                        viewModel.confirmBallPosition()
                    }
                }

            case .displayingResult:
                secondaryButton(title: "Home", icon: "house.fill") {
                    withAnimation {
                        viewModel.cancel()
                        appState.currentScreen = .home
                    }
                }

                mainActionButton(
                    title: "New Putt",
                    icon: "arrow.clockwise",
                    color: .green
                ) {
                    withAnimation {
                        viewModel.startNewPutt()
                        arSessionManager.clearPuttingLine()
                    }
                }

            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }

    private func markHoleAction() {
        if appState.settings.hapticFeedbackEnabled {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        }

        if let position = arSessionManager.getWorldPosition(
            from: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.markHole(at: position)
                arSessionManager.placeHoleMarker(at: position)
            }
        } else {
            showPositionErrorFeedback()
        }
    }

    private func markBallAction() {
        if appState.settings.hapticFeedbackEnabled {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        }

        if let position = arSessionManager.getWorldPosition(
            from: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.markBall(at: position)
                arSessionManager.placeBallMarker(at: position)
            }
        } else {
            showPositionErrorFeedback()
        }
    }

    private func showPositionErrorFeedback() {
        if appState.settings.hapticFeedbackEnabled {
            let errorGenerator = UINotificationFeedbackGenerator()
            errorGenerator.notificationOccurred(.warning)
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            showPositionError = true
        }

        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showPositionError = false
            }
        }
    }

    private func mainActionButton(
        title: String,
        icon: String,
        color: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: disabled ? [.gray] : [color, color.opacity(0.8)]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(30)
            .shadow(color: disabled ? .clear : color.opacity(0.4), radius: 10, y: 4)
        }
        .disabled(disabled)
        .scaleEffect(disabled ? 0.95 : 1.0)
        .accessibilityLabel(title)
        .accessibilityHint(disabled ? "Button is disabled. Scan more of the green first." : "Double tap to \(title.lowercased())")
    }

    private func secondaryButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial.opacity(0.8))
            .cornerRadius(28)
        }
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to \(title.lowercased())")
    }
}

#Preview {
    ScanningContainerView()
        .environmentObject(AppState())
}
