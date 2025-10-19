//
//  HapticFeedbackManager.swift
//  LiDARCameraApp
//
//  Provides continuous haptic feedback based on depth data
//  Functions like a "walking stick for the blind" using haptic echolocation
//

import Foundation
import CoreHaptics
import UIKit

/// Manages continuous haptic feedback that varies with object proximity
class HapticFeedbackManager {

    // MARK: - Properties

    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isRunning = false

    // Fallback to UIImpactFeedbackGenerator if Core Haptics doesn't work
    private var impactGenerator: UIImpactFeedbackGenerator?
    private var updateTimer: Timer?
    private var currentDepth: Float = 0.0

    // Timer to restart continuous haptic before it expires (30s max duration)
    private var renewalTimer: Timer?

    /// Intensity range for haptic feedback (0.0 to 1.0)
    /// Note: Values below ~0.4 may not produce perceptible vibration on some devices
    var minimumIntensity: Float = 0.2
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
        guard !isRunning else {
            print("⚠️ Haptics already running")
            return
        }

        print("🚀 Starting haptics...")

        do {
            try startContinuousHaptics()
            isRunning = true
            print("✅ Continuous haptics started successfully")
        } catch {
            print("❌ Core Haptics failed: \(error)")
            print("⚡ Falling back to UIImpactFeedbackGenerator")
            startFallbackHaptics()
        }
    }

    private func startFallbackHaptics() {
        impactGenerator = UIImpactFeedbackGenerator(style: .medium)
        impactGenerator?.prepare()
        isRunning = true

        // Create repeating timer for continuous feedback
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let intensity = CGFloat(self.currentDepth)
            if intensity > 0.1 {
                self.impactGenerator?.impactOccurred(intensity: intensity)
                self.impactGenerator?.prepare()
            }
        }

        print("✅ Fallback haptics started with timer")
    }

    /// Stops continuous haptic feedback
    func stop() {
        guard isRunning else { return }

        // Stop Core Haptics
        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
            continuousPlayer = nil
        } catch {
            print("❌ Failed to stop continuous haptics: \(error)")
        }

        // Stop fallback
        updateTimer?.invalidate()
        updateTimer = nil
        impactGenerator = nil

        // Stop renewal timer
        renewalTimer?.invalidate()
        renewalTimer = nil

        isRunning = false
        print("🛑 Continuous haptics stopped")
    }

    /// Updates haptic intensity based on depth value (0.0 = far, 1.0 = close)
    /// - Parameter depth: Normalized depth value where higher = closer
    func updateIntensity(forDepth depth: Float) {
        guard isRunning else {
            print("⚠️ Cannot update intensity - haptics not running")
            return
        }

        // Map depth to intensity range
        let intensity = minimumIntensity + (depth * (maximumIntensity - minimumIntensity))
        let clampedIntensity = max(minimumIntensity, min(maximumIntensity, intensity))

        // DEBUG: Log intensity values
        print("🔊 Haptic intensity: \(clampedIntensity) (from depth: \(depth))")

        // Store for fallback generator
        currentDepth = clampedIntensity

        // Try Core Haptics first
        if let player = continuousPlayer {
            // Create dynamic parameter for intensity
            let intensityParameter = CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl,
                value: clampedIntensity,
                relativeTime: 0
            )

            do {
                try player.sendParameters([intensityParameter], atTime: 0)
            } catch {
                print("❌ Failed to update haptic intensity: \(error)")
            }
        }
        // Fallback generator updates happen automatically via timer
    }

    // MARK: - Private Methods

    private func startContinuousHaptics() throws {
        guard let engine = hapticEngine else {
            throw HapticError.engineNotAvailable
        }

        print("🔧 Creating continuous haptic pattern...")

        // Create a continuous haptic event with a very long duration
        let intensity = CHHapticEventParameter(
            parameterID: .hapticIntensity,
            value: 0.5  // Start at medium intensity
        )

        let sharpness = CHHapticEventParameter(
            parameterID: .hapticSharpness,
            value: 0.4
        )

        // Create continuous event with 30s duration (Core Haptics max for continuous events)
        let continuousEvent = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensity, sharpness],
            relativeTime: 0,
            duration: 30.0  // 30 seconds - maximum for continuous haptic events
        )

        // Create pattern
        let pattern = try CHHapticPattern(
            events: [continuousEvent],
            parameters: []
        )

        print("🔧 Creating advanced player...")

        // Create player
        continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)

        print("🔧 Starting player...")

        // Start playback immediately
        try continuousPlayer?.start(atTime: CHHapticTimeImmediate)

        print("✅ Continuous haptic player started!")

        // Set up auto-renewal timer to restart before the 30s limit
        // Restart at 28s to give time for transition
        scheduleRenewal()
    }

    /// Schedules automatic renewal of the continuous haptic pattern
    private func scheduleRenewal() {
        // Cancel existing timer if any
        renewalTimer?.invalidate()

        // Restart pattern every 28 seconds (before the 30s limit)
        renewalTimer = Timer.scheduledTimer(withTimeInterval: 28.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }

            print("🔄 Renewing continuous haptic pattern...")

            do {
                // Stop current player
                try self.continuousPlayer?.stop(atTime: CHHapticTimeImmediate)

                // Restart with new pattern
                try self.startContinuousHaptics()

                print("✅ Haptic pattern renewed successfully")
            } catch {
                print("❌ Failed to renew haptic pattern: \(error)")
            }
        }
    }

    // MARK: - Error

    enum HapticError: Error {
        case engineNotAvailable
    }
}
