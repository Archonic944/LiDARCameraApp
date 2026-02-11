//
//  SurfaceAnalyzer.swift
//  LiDARCameraApp
//
//  Computes surface normals within the center aperture of a depth buffer
//  and detects significant changes for haptic click feedback.
//

import Foundation
import CoreVideo
import simd

private func clamp(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(value, lo), hi)
}

class SurfaceAnalyzer {

    // MARK: - Configuration

    /// Cosine similarity threshold for normal change detection (~32 degrees)
    var normalChangeThreshold: Float = 0.85

    /// Depth change threshold in meters (8cm)
    var depthDropThreshold: Float = 0.08

    /// Minimum time between clicks (seconds)
    var cooldownInterval: TimeInterval = 0.15

    // MARK: - State

    private var prevNormal: simd_float3?
    private var prevDepth: Float?
    private var lastClickTime: TimeInterval = 0

    // MARK: - Result

    struct Result {
        let shouldClick: Bool
        let normalDot: Float
        let depthDelta: Float
        let angleDegrees: Float
    }

    // MARK: - Analysis

    /// Analyzes the center aperture of a depth map for surface normal changes and depth drops.
    /// - Parameters:
    ///   - depthMap: Oriented Float32 depth buffer in meters
    ///   - apertureSize: Size of the aperture region (0-1)
    ///   - rangeMin: Active depth range minimum (meters)
    ///   - rangeMax: Active depth range maximum (meters)
    /// - Returns: Analysis result indicating whether a haptic click should fire
    func analyze(depthMap: CVPixelBuffer, apertureSize: Double = 0.15,
                 rangeMin: Float = 0.5, rangeMax: Float = 2.0) -> Result {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return Result(shouldClick: false, normalDot: 1.0, depthDelta: 0, angleDegrees: 0)
        }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)

        // Calculate aperture bounds
        let centerX = width / 2
        let centerY = height / 2
        let apertureW = Int(apertureSize * Double(width))
        let apertureH = Int(apertureSize * Double(height))

        // -1 on end bounds because we sample x+1 and y+1 for derivatives
        let startX = max(0, centerX - apertureW / 2)
        let endX = min(width - 1, centerX + apertureW / 2)
        let startY = max(0, centerY - apertureH / 2)
        let endY = min(height - 1, centerY + apertureH / 2)

        var normalSum = simd_float3(0, 0, 0)
        var depthSum: Float = 0
        var validCount: Int = 0

        for y in startY..<endY {
            for x in startX..<endX {
                let idx = y * width + x
                let dC = floatBuffer[idx]

                guard dC > 0.001 && dC.isFinite else { continue }

                // Skip pixels outside the active depth range (with some margin)
                let margin = (rangeMax - rangeMin) * 0.25
                guard dC >= (rangeMin - margin) && dC <= (rangeMax + margin) else { continue }

                let dR = floatBuffer[idx + 1]                   // depth[x+1, y]
                let dU = floatBuffer[(y + 1) * width + x]       // depth[x, y+1]

                guard dR > 0.001 && dR.isFinite && dU > 0.001 && dU.isFinite else { continue }

                // Depth-dependent pixel metric size (same as Metal shader)
                let pixelMetricSize = dC * 0.0015

                let vX = simd_float3(pixelMetricSize, 0, dR - dC)
                let vY = simd_float3(0, pixelMetricSize, dU - dC)

                let normal = simd_normalize(simd_cross(vX, vY))

                guard normal.x.isFinite && normal.y.isFinite && normal.z.isFinite else { continue }

                normalSum += normal
                depthSum += dC
                validCount += 1
            }
        }

        guard validCount > 0 else {
            return Result(shouldClick: false, normalDot: 1.0, depthDelta: 0, angleDegrees: 0)
        }

        let currentNormal = simd_normalize(normalSum / Float(validCount))
        let currentDepth = depthSum / Float(validCount)
        let angle = acos(min(Float(1.0), max(Float(-1.0), currentNormal.z))) * 180.0 / Float.pi

        // Compare to previous frame
        var normalDot: Float = 1.0
        var depthDelta: Float = 0
        var shouldClick = false

        if let prev = prevNormal, let prevD = prevDepth {
            normalDot = simd_dot(prev, currentNormal)
            depthDelta = abs(currentDepth - prevD)

            let now = ProcessInfo.processInfo.systemUptime
            let cooldownOK = (now - lastClickTime) >= cooldownInterval

            // Range-aware sensitivity: scale thresholds relative to where the current
            // depth sits within the active range, not absolute distance.
            let rangeWidth = max(rangeMax - rangeMin, 0.05)
            // 0 = at rangeMin (close end), 1 = at rangeMax (far end)
            let rangePosition = clamp((currentDepth - rangeMin) / rangeWidth, 0, 1)
            // Mild linear scaling: close end of range is 1.5x more sensitive,
            // far end is 0.75x. Avoids the extreme swings of 1/d².
            let proximityScale: Float = 1.5 - 0.75 * rangePosition

            // Scale depth threshold proportionally to range width so narrow ranges
            // (like short: 0.25m wide) use proportionally smaller thresholds.
            let baseDepthThreshold = depthDropThreshold * (rangeWidth / 0.3)

            // Normal threshold: closer to 1.0 = more sensitive
            let effectiveNormalThreshold = 1.0 - (1.0 - normalChangeThreshold) / proximityScale

            // Depth threshold: smaller = more sensitive
            let effectiveDepthThreshold = baseDepthThreshold / proximityScale

            if cooldownOK && (normalDot < effectiveNormalThreshold || depthDelta > effectiveDepthThreshold) {
                shouldClick = true
                lastClickTime = now
            }
        }

        prevNormal = currentNormal
        prevDepth = currentDepth

        return Result(
            shouldClick: shouldClick,
            normalDot: normalDot,
            depthDelta: depthDelta,
            angleDegrees: angle
        )
    }
}
