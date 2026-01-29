import UIKit
import CoreHaptics

/// Centralized haptic feedback manager for consistent feedback throughout the app
/// Based on Apple's Human Interface Guidelines for haptic feedback
final class HapticManager {
    static let shared = HapticManager()

    private var hapticEngine: CHHapticEngine?
    private var isEnabled: Bool = true

    private init() {
        prepareHapticEngine()
    }

    // MARK: - Configuration

    /// Enable or disable haptic feedback globally
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    // MARK: - Simple Haptic Feedback

    /// Light impact feedback - for UI button taps and slider adjustments
    func lightImpact() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Medium impact feedback - for mode changes and confirmations
    func mediumImpact() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// Heavy impact feedback - for major events like session complete
    func heavyImpact() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
    }

    /// Soft impact - gentle feedback for continuous interactions
    func softImpact() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()
    }

    /// Rigid impact - sharp feedback for precise actions
    func rigidImpact() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.impactOccurred()
    }

    /// Selection changed feedback - for picker scrolling and option selection
    func selectionChanged() {
        guard isEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    // MARK: - Notification Feedback

    /// Success feedback - prediction locked, calibration complete
    func success() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// Warning feedback - low confidence, tracking issues
    func warning() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    /// Error feedback - failed operations
    func error() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    // MARK: - Golf-Specific Patterns

    /// Hole marked feedback - satisfying confirmation
    func holeMarked() {
        guard isEnabled else { return }
        mediumImpact()
    }

    /// Ball marked feedback
    func ballMarked() {
        guard isEnabled else { return }
        mediumImpact()
    }

    /// Scanning started feedback
    func scanningStarted() {
        guard isEnabled else { return }
        success()
    }

    /// Scanning progress pulse - called periodically during scan
    func scanningPulse() {
        guard isEnabled else { return }
        softImpact()
    }

    /// Analysis started feedback
    func analysisStarted() {
        guard isEnabled else { return }
        lightImpact()
    }

    /// Prediction ready feedback - putting line calculated
    func predictionReady() {
        guard isEnabled else { return }
        success()
    }

    /// Low confidence warning
    func lowConfidenceWarning() {
        guard isEnabled else { return }
        warning()
    }

    /// Tracking lost feedback
    func trackingLost() {
        guard isEnabled else { return }
        warning()
    }

    /// Session complete feedback
    func sessionComplete() {
        guard isEnabled else { return }
        heavyImpact()
    }

    // MARK: - Core Haptics (Advanced Patterns)

    private func prepareHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.playsHapticsOnly = true
            try hapticEngine?.start()

            // Handle engine stopping
            hapticEngine?.stoppedHandler = { [weak self] reason in
                print("[HapticManager] Engine stopped: \(reason.rawValue)")
                self?.restartHapticEngine()
            }

            // Handle engine reset
            hapticEngine?.resetHandler = { [weak self] in
                print("[HapticManager] Engine reset")
                try? self?.hapticEngine?.start()
            }
        } catch {
            print("[HapticManager] Failed to create haptic engine: \(error)")
        }
    }

    private func restartHapticEngine() {
        try? hapticEngine?.start()
    }

    /// Play custom confidence feedback - intensity based on confidence level
    func confidenceFeedback(confidence: Float) {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Fallback to standard feedback
            if confidence >= 0.8 {
                success()
            } else if confidence >= 0.6 {
                lightImpact()
            } else {
                warning()
            }
            return
        }

        do {
            let intensity = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: min(Float(confidence), 1.0)
            )
            let sharpness = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: confidence >= 0.7 ? 0.8 : 0.3
            )

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensity, sharpness],
                relativeTime: 0
            )

            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Failed to play custom haptic: \(error)")
            success() // Fallback
        }
    }

    /// Play a scanning heartbeat pattern
    func scanningHeartbeat() {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            softImpact()
            return
        }

        do {
            // Create a heartbeat-like pattern
            let beat1 = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0
            )

            let beat2 = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
                ],
                relativeTime: 0.15
            )

            let pattern = try CHHapticPattern(events: [beat1, beat2], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Failed to play heartbeat: \(error)")
            softImpact()
        }
    }

    /// Play a subtle texture haptic simulating surface scanning
    func playScanTexture() {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            // Create a low-rumble continuous texture
            let rumble = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                ],
                relativeTime: 0,
                duration: 0.15
            )
            
            // Overlay random transient ticks for "digital" feel
            var events = [rumble]
            
            for i in 0..<3 {
                let tick = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: 0.04 * Double(i + 1)
                )
                events.append(tick)
            }
            
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[HapticManager] Failed to play scan texture: \(error)")
        }
    }
}
