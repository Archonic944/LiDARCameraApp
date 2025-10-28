//
//  EdgeAlertManager.swift
//  LiDARCameraApp
//
//  Manages directional edge proximity detection and transient haptic alerts
//  Scans edge map for edges approaching from held screen edges
//

import CoreVideo
import Foundation

/// Manages edge proximity detection and transient haptic feedback
/// When user holds screen edge, alerts them when edges approach from that direction
class EdgeAlertManager {

    // MARK: - Types

    /// Direction from which to detect approaching edges
    enum HoldDirection: String {
        case left, right, top, bottom
    }

    // MARK: - Properties

    private weak var hapticManager: HapticFeedbackManager?
    private var pulseTimer: Timer?
    private var lastEdgeDistance: CGFloat?
    private var activeDirection: HoldDirection?

    // MARK: - Configuration

    /// Size of aperture region (fraction of frame width/height)
    /// Default: 0.20 (20% of frame, matching depth aperture)
    var apertureSize: CGFloat = 0.20

    /// Maximum distance to scan for edges (fraction of frame)
    /// Default: 0.40 (scan up to 40% of frame from aperture edge)
    var maxDetectionDistance: CGFloat = 0.40

    /// Minimum interval between pulses (fastest rate)
    /// Default: 0.05 seconds (20Hz max, for edges at aperture)
    var minPulseInterval: TimeInterval = 0.05

    /// Maximum interval between pulses (slowest rate)
    /// Default: 1.0 seconds (1Hz, for edges at max distance)
    var maxPulseInterval: TimeInterval = 1.0

    /// Edge intensity threshold (0-1 range)
    /// Pixels below this value are not considered edges
    /// Default: 0.3 (30% intensity)
    var edgeIntensityThreshold: Float = 0.3

    /// Haptic intensity (0-1 range)
    /// Default: 1.0 (maximum intensity for sharp "stab" feel)
    var hapticIntensity: Float = 1.0

    /// Haptic sharpness (0-1 range)
    /// Default: 1.0 (maximum sharpness for sharp "stab" feel)
    var hapticSharpness: Float = 1.0

    // MARK: - Initialization

    init(hapticManager: HapticFeedbackManager) {
        self.hapticManager = hapticManager
        print("🎯 EdgeAlertManager initialized")
    }

    deinit {
        stopPulses()
        print("🎯 EdgeAlertManager deinitialized")
    }

    // MARK: - Public API

    /// Update edge alert based on current edge map and hold state
    /// Call this each time a new edge map is available
    ///
    /// - Parameters:
    ///   - edgeMap: Edge intensity map from EdgeDetectorGPU (CVPixelBuffer, Float32)
    ///   - holdingLeft: Whether left screen edge is being held
    ///   - holdingRight: Whether right screen edge is being held
    ///   - holdingTop: Whether top screen edge is being held
    ///   - holdingBottom: Whether bottom screen edge is being held
    func updateEdgeAlert(
        edgeMap: CVPixelBuffer,
        holdingLeft: Bool,
        holdingRight: Bool,
        holdingTop: Bool,
        holdingBottom: Bool
    ) {
        // Determine active direction (prioritize if multiple edges held)
        let newDirection: HoldDirection? = {
            if holdingRight { return .right }
            if holdingLeft { return .left }
            if holdingTop { return .top }
            if holdingBottom { return .bottom }
            return nil
        }()

        // If direction changed, reset state
        if newDirection != activeDirection {
            if let dir = newDirection {
                print("🎯 Edge hold STARTED: \(dir.rawValue)")
            } else if activeDirection != nil {
                print("🎯 Edge hold ENDED")
            }
            activeDirection = newDirection
            lastEdgeDistance = nil
            stopPulses()
        }

        // If no edge is held, stop and return
        guard let direction = activeDirection else {
            return
        }

        // Scan for edge in the active direction
        if let distance = scanForEdge(in: edgeMap, direction: direction) {
            // Edge detected - update stored distance
            // print("🎯 Edge detected in \(direction.rawValue): distance=\(String(format: "%.3f", distance))")
            lastEdgeDistance = distance

            // Only schedule if timer is not already active
            if pulseTimer == nil {
                print("🎯 Edge detected - starting pulse sequence at distance=\(String(format: "%.3f", distance))")
                scheduleNextPulse(distance: distance)
            }
        } else {
            // No edge detected - stop pulses
            if lastEdgeDistance != nil {
                print("🎯 No edge detected (stopped)")
            }
            lastEdgeDistance = nil
            stopPulses()
        }
    }

    // MARK: - Edge Scanning

    /// Scan edge map for nearest edge in specified direction
    /// Returns normalized distance (0.0 = at aperture, 1.0 = at max range), or nil if no edge
    private func scanForEdge(in edgeMap: CVPixelBuffer, direction: HoldDirection) -> CGFloat? {
        CVPixelBufferLockBaseAddress(edgeMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(edgeMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(edgeMap) else {
            print("🎯 ERROR: Could not get edge map base address")
            return nil
        }

        let width = CVPixelBufferGetWidth(edgeMap)
        let height = CVPixelBufferGetHeight(edgeMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(edgeMap)
        let buffer = baseAddress.assumingMemoryBound(to: Float.self)

        // Define aperture region (center rectangle)
        let apertureWidth = Int(CGFloat(width) * apertureSize)
        let apertureHeight = Int(CGFloat(height) * apertureSize)
        let apertureX = (width - apertureWidth) / 2
        let apertureY = (height - apertureHeight) / 2

        // Calculate scan range (how far to look beyond aperture)
        let maxScanPixels = Int(CGFloat(direction == .left || direction == .right ? width : height) * maxDetectionDistance)

        print("🎯 Scanning \(direction.rawValue): edgeMap=\(width)x\(height), aperture=(\(apertureX),\(apertureY) \(apertureWidth)x\(apertureHeight)), maxScan=\(maxScanPixels)px")

        var nearestEdgePixels: Int?

        switch direction {
        case .right:
            // Scan rightward from aperture right edge
            let apertureRightEdge = apertureX + apertureWidth
            let scanEnd = min(apertureRightEdge + maxScanPixels, width)

            // For each column to the right of aperture
            for x in apertureRightEdge..<scanEnd {
                // Check pixels in the aperture height range
                for y in apertureY..<(apertureY + apertureHeight) {
                    let index = y * (bytesPerRow / MemoryLayout<Float>.size) + x
                    if buffer[index] >= edgeIntensityThreshold {
                        // Found edge - calculate distance from aperture edge
                        let distancePixels = x - apertureRightEdge
                        if nearestEdgePixels == nil || distancePixels < nearestEdgePixels! {
                            nearestEdgePixels = distancePixels
                        }
                        break // Found edge in this column, move to next
                    }
                }
                // Early exit if we found an edge at aperture (distance = 0)
                if nearestEdgePixels == 0 {
                    break
                }
            }

        case .left:
            // Scan leftward from aperture left edge
            let apertureLeftEdge = apertureX
            let scanStart = max(apertureLeftEdge - maxScanPixels, 0)

            // For each column to the left of aperture
            for x in stride(from: apertureLeftEdge - 1, through: scanStart, by: -1) {
                // Check pixels in the aperture height range
                for y in apertureY..<(apertureY + apertureHeight) {
                    let index = y * (bytesPerRow / MemoryLayout<Float>.size) + x
                    if buffer[index] >= edgeIntensityThreshold {
                        let distancePixels = apertureLeftEdge - x
                        if nearestEdgePixels == nil || distancePixels < nearestEdgePixels! {
                            nearestEdgePixels = distancePixels
                        }
                        break
                    }
                }
                if nearestEdgePixels == 0 {
                    break
                }
            }

        case .bottom:
            // Scan downward from aperture bottom edge
            let apertureBottomEdge = apertureY + apertureHeight
            let scanEnd = min(apertureBottomEdge + maxScanPixels, height)

            // For each row below aperture
            for y in apertureBottomEdge..<scanEnd {
                // Check pixels in the aperture width range
                for x in apertureX..<(apertureX + apertureWidth) {
                    let index = y * (bytesPerRow / MemoryLayout<Float>.size) + x
                    if buffer[index] >= edgeIntensityThreshold {
                        let distancePixels = y - apertureBottomEdge
                        if nearestEdgePixels == nil || distancePixels < nearestEdgePixels! {
                            nearestEdgePixels = distancePixels
                        }
                        break
                    }
                }
                if nearestEdgePixels == 0 {
                    break
                }
            }

        case .top:
            // Scan upward from aperture top edge
            let apertureTopEdge = apertureY
            let scanStart = max(apertureTopEdge - maxScanPixels, 0)

            // For each row above aperture
            for y in stride(from: apertureTopEdge - 1, through: scanStart, by: -1) {
                // Check pixels in the aperture width range
                for x in apertureX..<(apertureX + apertureWidth) {
                    let index = y * (bytesPerRow / MemoryLayout<Float>.size) + x
                    if buffer[index] >= edgeIntensityThreshold {
                        let distancePixels = apertureTopEdge - y
                        if nearestEdgePixels == nil || distancePixels < nearestEdgePixels! {
                            nearestEdgePixels = distancePixels
                        }
                        break
                    }
                }
                if nearestEdgePixels == 0 {
                    break
                }
            }
        }

        // Convert pixel distance to normalized distance (0.0 to 1.0)
        guard let edgePixels = nearestEdgePixels else {
            return nil // No edge found
        }

        let normalizedDistance = CGFloat(edgePixels) / CGFloat(maxScanPixels)
        print("🎯 Found edge at \(edgePixels)px -> normalized=\(String(format: "%.3f", normalizedDistance))")
        return max(0.0, min(1.0, normalizedDistance)) // Clamp to [0, 1]
    }

    // MARK: - Haptic Pulse Control

    /// Schedule next haptic pulse based on edge distance
    /// Closer edges = faster pulses
    private func scheduleNextPulse(distance: CGFloat) {
        // Calculate interval based on distance
        // distance = 0.0 (at aperture) -> minPulseInterval (fast)
        // distance = 1.0 (far) -> maxPulseInterval (slow)
        let interval = minPulseInterval + (maxPulseInterval - minPulseInterval) * distance

        print("🎯 Scheduling pulse: distance=\(String(format: "%.3f", distance)) -> interval=\(String(format: "%.3f", interval))s")

        // Fire pulse immediately
        firePulse()

        // Schedule next pulse on MAIN THREAD (timers need a RunLoop!)
        DispatchQueue.main.async { [weak self] in
            self?.pulseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.pulseTimer = nil  // Clear timer reference

                print("🎯 Timer fired! Scheduling next pulse...")

                // Use current stored distance for next pulse
                if let currentDistance = self?.lastEdgeDistance, self?.activeDirection != nil {
                    self?.scheduleNextPulse(distance: currentDistance)
                } else {
                    print("🎯 Timer fired but no active direction - stopping")
                }
            }
        }
    }

    /// Stop all haptic pulses
    private func stopPulses() {
        // Must invalidate on main thread where timer was created
        DispatchQueue.main.async { [weak self] in
            self?.pulseTimer?.invalidate()
            self?.pulseTimer = nil
        }
    }

    /// Fire a single transient haptic pulse
    private func firePulse() {
        guard let manager = hapticManager else {
            print("🎯 ERROR: HapticFeedbackManager not available")
            return
        }

        print("🎯 FIRING PULSE (intensity=\(hapticIntensity), sharpness=\(hapticSharpness))")
        manager.fireTransientPulse(intensity: hapticIntensity, sharpness: hapticSharpness)
    }
}
