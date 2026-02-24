import UIKit
import CoreHaptics

/// Centralized haptic feedback manager for consistent feedback throughout the app
/// Based on Apple's Human Interface Guidelines for haptic feedback
/// M16 fix: Thread-safe engine restart via DispatchQueue serialization
/// M17 fix: Pre-prepared generators for lower latency haptic response
final class HapticManager {
    static let shared = HapticManager()

    private var hapticEngine: CHHapticEngine?
    private var isEnabled: Bool = true

    // M16 fix: serialized access to hapticEngine for thread-safe restarts
    private let engineQueue = DispatchQueue(label: "com.puttingking.haptics", qos: .userInteractive)

    // M17 fix: pre-prepared generators for lower-latency feedback
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let rigidImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        // Prepare all generators so first haptic fires immediately
        lightImpactGenerator.prepare()
        mediumImpactGenerator.prepare()
        heavyImpactGenerator.prepare()
        softImpactGenerator.prepare()
        rigidImpactGenerator.prepare()
        selectionGenerator.prepare()
        notificationGenerator.prepare()

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
        lightImpactGenerator.impactOccurred()
        lightImpactGenerator.prepare()
    }

    /// Medium impact feedback - for mode changes and confirmations
    func mediumImpact() {
        guard isEnabled else { return }
        mediumImpactGenerator.impactOccurred()
        mediumImpactGenerator.prepare()
    }

    /// Heavy impact feedback - for major events like session complete
    func heavyImpact() {
        guard isEnabled else { return }
        heavyImpactGenerator.impactOccurred()
        heavyImpactGenerator.prepare()
    }

    /// Soft impact - gentle feedback for continuous interactions
    func softImpact() {
        guard isEnabled else { return }
        softImpactGenerator.impactOccurred()
        softImpactGenerator.prepare()
    }

    /// Rigid impact - sharp feedback for precise actions
    func rigidImpact() {
        guard isEnabled else { return }
        rigidImpactGenerator.impactOccurred()
        rigidImpactGenerator.prepare()
    }

    /// Selection changed feedback - for picker scrolling and option selection
    func selectionChanged() {
        guard isEnabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    // MARK: - Notification Feedback

    /// Success feedback - prediction locked, calibration complete
    func success() {
        guard isEnabled else { return }
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    /// Warning feedback - low confidence, tracking issues
    func warning() {
        guard isEnabled else { return }
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    /// Error feedback - failed operations
    func error() {
        guard isEnabled else { return }
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
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

        engineQueue.async { [weak self] in
            do {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                try engine.start()

                // Handle engine stopping — M16 fix: restart on serialized queue
                engine.stoppedHandler = { [weak self] reason in
                    print("[HapticManager] Engine stopped: \(reason.rawValue)")
                    self?.restartHapticEngine()
                }

                // Handle engine reset
                engine.resetHandler = { [weak self] in
                    print("[HapticManager] Engine reset")
                    self?.engineQueue.async {
                        try? self?.hapticEngine?.start()
                    }
                }

                self?.hapticEngine = engine
            } catch {
                print("[HapticManager] Failed to create haptic engine: \(error)")
            }
        }
    }

    private func restartHapticEngine() {
        engineQueue.async { [weak self] in
            try? self?.hapticEngine?.start()
        }
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

        engineQueue.async { [weak self] in
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
                let player = try self?.hapticEngine?.makePlayer(with: pattern)
                try player?.start(atTime: CHHapticTimeImmediate)
            } catch {
                print("[HapticManager] Failed to play custom haptic: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.success() // Fallback
                }
            }
        }
    }

    /// Play a scanning heartbeat pattern
    func scanningHeartbeat() {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            softImpact()
            return
        }

        engineQueue.async { [weak self] in
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
                let player = try self?.hapticEngine?.makePlayer(with: pattern)
                try player?.start(atTime: CHHapticTimeImmediate)
            } catch {
                print("[HapticManager] Failed to play heartbeat: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.softImpact()
                }
            }
        }
    }

    /// Play a subtle texture haptic simulating surface scanning
    func playScanTexture() {
        guard isEnabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        engineQueue.async { [weak self] in
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
                let player = try self?.hapticEngine?.makePlayer(with: pattern)
                try player?.start(atTime: CHHapticTimeImmediate)
            } catch {
                print("[HapticManager] Failed to play scan texture: \(error)")
            }
        }
    }
}
