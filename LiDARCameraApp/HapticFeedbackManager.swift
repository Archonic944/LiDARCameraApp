//
//  HapticFeedbackManager.swift
//  LiDARCameraApp
//
//  Provides continuous haptic feedback based on depth data
//  Functions like a "walking stick for the blind" using haptic echolocation
//

import Foundation
import CoreHaptics

/// Manages continuous haptic feedback that varies with object proximity
class HapticFeedbackManager {

    // MARK: - Properties

    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isRunning = false

    /// Intensity range for haptic feedback (0.0 to 1.0)
    var minimumIntensity: Float = 0.1
    var maximumIntensity: Float = 1.0

    // MARK: - Initialization

    init() {
        setupHapticEngine()
    }

    deinit {
        stop()
    }

    // MARK: - Setup

    private func setupHapticEngine() {
        // Check if device supports haptics
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("⚠️ Device does not support haptics")
            return
        }

        do {
            hapticEngine = try CHHapticEngine()

            // Handle engine reset (e.g., app backgrounded)
            hapticEngine?.resetHandler = { [weak self] in
                print("🔄 Haptic engine reset")
                self?.restartEngine()
            }

            // Handle engine stopped unexpectedly
            hapticEngine?.stoppedHandler = { [weak self] reason in
                print("⚠️ Haptic engine stopped: \(reason)")
                self?.restartEngine()
            }

            try hapticEngine?.start()
            print("✅ Haptic engine started")

        } catch {
            print("❌ Failed to create haptic engine: \(error)")
        }
    }

    private func restartEngine() {
        do {
            try hapticEngine?.start()
            if isRunning {
                try startContinuousHaptics()
            }
        } catch {
            print("❌ Failed to restart haptic engine: \(error)")
        }
    }

    // MARK: - Public Methods

    /// Starts continuous haptic feedback
    func start() {
        guard !isRunning else { return }

        do {
            try startContinuousHaptics()
            isRunning = true
            print("✅ Continuous haptics started")
        } catch {
            print("❌ Failed to start continuous haptics: \(error)")
        }
    }

    /// Stops continuous haptic feedback
    func stop() {
        guard isRunning else { return }

        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
            continuousPlayer = nil
            isRunning = false
            print("🛑 Continuous haptics stopped")
        } catch {
            print("❌ Failed to stop continuous haptics: \(error)")
        }
    }

    /// Updates haptic intensity based on depth value (0.0 = far, 1.0 = close)
    /// - Parameter depth: Normalized depth value where higher = closer
    func updateIntensity(forDepth depth: Float) {
        guard isRunning, let player = continuousPlayer else { return }

        // Map depth to intensity range
        let intensity = minimumIntensity + (depth * (maximumIntensity - minimumIntensity))
        let clampedIntensity = max(minimumIntensity, min(maximumIntensity, intensity))

        // Create dynamic parameter for intensity
        let intensityParameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: clampedIntensity,
            relativeTime: 0
        )

        // Also modulate sharpness for more pronounced feedback when close
        let sharpness = clampedIntensity * 0.8  // Scale sharpness with intensity
        let sharpnessParameter = CHHapticDynamicParameter(
            parameterID: .hapticSharpnessControl,
            value: sharpness,
            relativeTime: 0
        )

        do {
            try player.sendParameters([intensityParameter, sharpnessParameter], atTime: 0)
        } catch {
            print("❌ Failed to update haptic intensity: \(error)")
        }
    }

    // MARK: - Private Methods

    private func startContinuousHaptics() throws {
        guard let engine = hapticEngine else {
            throw HapticError.engineNotAvailable
        }

        // Create a continuous haptic event
        let intensity = CHHapticEventParameter(
            parameterID: .hapticIntensity,
            value: minimumIntensity
        )

        let sharpness = CHHapticEventParameter(
            parameterID: .hapticSharpness,
            value: 0.5
        )

        // Create continuous event (indefinite duration)
        let continuousEvent = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensity, sharpness],
            relativeTime: 0,
            duration: 100  // Long duration, will be controlled dynamically
        )

        // Create pattern
        let pattern = try CHHapticPattern(
            events: [continuousEvent],
            parameters: []
        )

        // Create player
        continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)

        // Start playback immediately and loop
        try continuousPlayer?.start(atTime: CHHapticTimeImmediate)

        // Enable looping
        continuousPlayer?.loopEnabled = true
    }

    // MARK: - Error

    enum HapticError: Error {
        case engineNotAvailable
    }
}
