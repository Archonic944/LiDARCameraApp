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

    // MARK: - Alert Mode Properties
    private var alertFrameCounter: Int = 0
    private var isAlertMode: Bool = false
    private var alertOscillationHigh: Bool = false
    
    // Alert intensities - oscillation for noticeable pulses (Core Haptics range: 0.0–1.0)
    private let alertHighIntensity: Float = 1.0
    private let alertLowIntensity: Float = 0.3

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
            return
        }

        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.isAutoShutdownEnabled = false

            // Let resumeAfterBackground handle foreground restarts;
            // these handlers only cover unexpected mid-session resets.
            hapticEngine?.resetHandler = { [weak self] in
                guard let self = self, !self.isManagedRestart else { return }
                self.restartEngine()
            }

            hapticEngine?.stoppedHandler = { [weak self] _ in
                guard let self = self, !self.isManagedRestart else { return }
                self.restartEngine()
            }

            try hapticEngine?.start()

        } catch {
            // Haptic engine unavailable on this device
        }
    }

    /// Flag to suppress handler-driven restarts during a managed resume cycle
    private var isManagedRestart = false

    private func restartEngine() {
        do {
            try hapticEngine?.start()
            if isRunning {
                try startContinuousHaptics()
            }
        } catch {
            // Engine restart failed; will retry on next reset
        }
    }

    /// Cleanly rebuilds the haptic engine after returning from background.
    /// Tears down the old engine to avoid duplicate players from stale handlers.
    func resumeAfterBackground() {
        isManagedRestart = true

        // Tear down existing state
        renewalTimer?.invalidate()
        renewalTimer = nil
        continuousPlayer = nil
        hapticEngine?.stop()
        hapticEngine = nil

        // Reset alert state so we don't carry stale alert mode
        isAlertMode = false
        alertFrameCounter = 0

        // Rebuild from scratch
        setupHapticEngine()
        let wasRunning = isRunning
        isRunning = false
        isManagedRestart = false

        if wasRunning {
            start()
        }
    }

    // MARK: - Public Methods

    /// Starts continuous haptic feedback
    func start() {
        guard !isRunning else { return }

        do {
            try startContinuousHaptics()
            isRunning = true
        } catch {
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

    }

    /// Stops continuous haptic feedback
    func stop() {
        guard isRunning else { return }

        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
            continuousPlayer = nil
        } catch {
            // Best-effort stop
        }

        // Stop fallback
        updateTimer?.invalidate()
        updateTimer = nil
        impactGenerator = nil

        // Stop renewal timer
        renewalTimer?.invalidate()
        renewalTimer = nil

        isRunning = false
    }
    
    /// Updates the proximity alert state
    /// - Parameter isClose: True if any part of the depth buffer is closer than the threshold
    func updateProximityAlert(isClose: Bool) {
        if isClose {
            alertFrameCounter += 1
        } else {
            alertFrameCounter = 0
            isAlertMode = false
        }

        if alertFrameCounter >= 3 {
            isAlertMode = true
        }
    }

    /// Updates haptic intensity based on proximity value (1.0 = close, 0.0 = far)
    /// - Parameter depth: Normalized depth value where higher = closer
    func updateIntensity(forDepth depth: Float) {
        guard isRunning else { return }

        var clampedIntensity: Float = 0.0
        
        if isAlertMode {
            // Rapidly oscillate between 90% and 100% of original max (1.35 - 1.5)
            alertOscillationHigh.toggle()
            clampedIntensity = alertOscillationHigh ? alertHighIntensity : alertLowIntensity
        } else {
            // Normal operation: Map depth to intensity range
            let intensity = minimumIntensity + (depth * (maximumIntensity - minimumIntensity))
            clampedIntensity = max(minimumIntensity, min(maximumIntensity, intensity))
        }

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
                // Parameter update failed; will retry next frame
            }
        }
        // Fallback generator updates happen automatically via timer
    }

    /// Fires a single transient haptic pulse (for edge alerts)
    /// - Parameters:
    ///   - intensity: Haptic intensity (0.0-1.0)
    ///   - sharpness: Haptic sharpness (0.0-1.0)
    func fireTransientPulse(intensity: Float = 1.0, sharpness: Float = 1.0) {
        guard let engine = hapticEngine else { return }

        do {
            // Create sharp transient event
            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0
            )

            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)

            try player.start(atTime: CHHapticTimeImmediate)

        } catch {
            // Transient pulse failed; non-critical
        }
    }

    // MARK: - Private Methods

    private func startContinuousHaptics() throws {
        guard let engine = hapticEngine else {
            throw HapticError.engineNotAvailable
        }

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

        let pattern = try CHHapticPattern(
            events: [continuousEvent],
            parameters: []
        )

        continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
        try continuousPlayer?.start(atTime: CHHapticTimeImmediate)

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

            do {
                try self.continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
                try self.startContinuousHaptics()
            } catch {
                // Renewal failed; haptics may stop after 30s
            }
        }
    }

    // MARK: - Error

    enum HapticError: Error {
        case engineNotAvailable
    }
}
