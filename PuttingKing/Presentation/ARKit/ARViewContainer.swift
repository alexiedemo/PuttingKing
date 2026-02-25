import SwiftUI
import RealityKit
import ARKit

/// SwiftUI wrapper for ARView
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ScanningViewModel
    let arSessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Configure AR session manager (stores reference, sets delegate — no @Published changes)
        arSessionManager.configure(arView: arView)

        // Defer session start to next run loop iteration to avoid
        // "Publishing changes from within view updates" — startSession()
        // sets @Published isSessionRunning during makeUIView(), which is
        // part of SwiftUI's view evaluation phase.
        let manager = arSessionManager
        DispatchQueue.main.async {
            do {
                try manager.startSession()
            } catch {
                print("[ARViewContainer] ERROR: Failed to start AR session: \(error.localizedDescription)")
            }
        }

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        // Only update AR content when state actually changes
        // Use coordinator to track state changes and prevent repeated updates
        let currentState = viewModel.scanState
        let previousState = context.coordinator.previousState

        if !statesAreEqual(currentState, previousState) {
            context.coordinator.previousState = currentState
            // Schedule the update asynchronously to avoid "publishing changes during view update"
            DispatchQueue.main.async {
                self.updateARContent(for: currentState, previousState: previousState, coordinator: context.coordinator)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.arSessionManager = arSessionManager
        return coordinator
    }

    private func statesAreEqual(_ lhs: ScanSession.ScanState, _ rhs: ScanSession.ScanState?) -> Bool {
        guard let rhs = rhs else { return false }

        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.markingHole, .markingHole): return true
        case (.scanningGreen, .scanningGreen): return true
        case (.markingBall, .markingBall): return true
        case (.analyzing, .analyzing): return true
        case (.displayingResult, .displayingResult): return true
        // Compare error by enum case identity (ScanError: Equatable) — message-based
        // comparison falsely matched different error types with identical messages
        case (.error(let e1), .error(let e2)): return e1 == e2
        default: return false
        }
    }

    private func updateARContent(for state: ScanSession.ScanState, previousState: ScanSession.ScanState?, coordinator: Coordinator) {
        switch state {
        case .markingHole:
            arSessionManager.showCrosshair(mode: .hole)
            arSessionManager.setMeshVisualizationEnabled(false) // Only show mesh AFTER marking hole
            // Reset hole flag so re-marking places a new marker (Redo Hole flow)
            coordinator.hasPlacedHoleMarker = false

        case .scanningGreen:
            arSessionManager.hideCrosshair()
            arSessionManager.setMeshVisualizationEnabled(true)
            // Reset ball and line flags for new putt cycle (New Putt flow)
            coordinator.hasPlacedBallMarker = false
            coordinator.hasDisplayedLine = false
            arSessionManager.clearPuttingLine()

            // Only place hole marker once when transitioning to this state
            if !coordinator.hasPlacedHoleMarker,
               let holePos = viewModel.holePosition {
                arSessionManager.placeHoleMarker(at: holePos.worldPosition)
                coordinator.hasPlacedHoleMarker = true
            }

        case .markingBall:
            arSessionManager.showCrosshair(mode: .ball)

            // Place ball marker once when transitioning to this state
            if !coordinator.hasPlacedBallMarker,
               let ballPos = viewModel.ballPosition {
                arSessionManager.placeBallMarker(at: ballPos.worldPosition)
                coordinator.hasPlacedBallMarker = true
            }

        case .analyzing:
            arSessionManager.hideCrosshair()
            arSessionManager.setMeshVisualizationEnabled(false)

        case .displayingResult:
            arSessionManager.hideCrosshair()
            arSessionManager.setMeshVisualizationEnabled(false)

            // Only display putting line once
            if !coordinator.hasDisplayedLine,
               let line = viewModel.puttingLine {
                arSessionManager.displayPuttingLine(line, color: viewModel.settings.lineColor)
                coordinator.hasDisplayedLine = true
            }

        case .idle, .error:
            arSessionManager.hideCrosshair()
            arSessionManager.clearPuttingLine()
            coordinator.hasDisplayedLine = false
            coordinator.hasPlacedHoleMarker = false
            coordinator.hasPlacedBallMarker = false
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // Stop AR session manager to clean up LiDAR scanning
        coordinator.arSessionManager?.stopSession()
        uiView.session.pause()
    }

    class Coordinator {
        var previousState: ScanSession.ScanState?
        var hasDisplayedLine = false
        var hasPlacedHoleMarker = false
        var hasPlacedBallMarker = false
        weak var arSessionManager: ARSessionManager?
    }
}

/// Preview provider for ARViewContainer
struct ARViewContainer_Previews: PreviewProvider {
    static var previews: some View {
        ARViewContainer(
            viewModel: ScanningViewModel(settings: AppSettings()),
            arSessionManager: ARSessionManager()
        )
        .edgesIgnoringSafeArea(.all)
    }
}
