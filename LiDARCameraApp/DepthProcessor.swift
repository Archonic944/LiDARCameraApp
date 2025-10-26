//
//  DepthProcessor.swift
//  LiDARCameraApp
//
//  Handles depth data processing and normalization
//

import Foundation
import AVFoundation
import CoreImage

/// Extends CVPixelBuffer with normalization capabilities
extension CVPixelBuffer {
    /// Normalizes the pixel buffer values to 0-1 range using fixed range. 1 is closer, 9 is farther.
    /// - Parameters:
    ///   - minDisparity: Minimum depth value (meters)
    ///   - maxDisparity: Maximum depth (meters)
    /// - Note: Modifies the buffer in-place. Values outside range are clamped.
    func normalize(minDepth: Float, maxDepth: Float) {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        CVPixelBufferLockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
        guard let floatBuffer = CVPixelBufferGetBaseAddress(self) else {
            CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
            return
        }

        let floatPixels = floatBuffer.assumingMemoryBound(to: Float.self)
        let count = width * height

        // Normalize to 0-1 range using fixed range
        let range = maxDepth - minDepth
        guard range > 0 else {
            CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
            print("Warning: early return, range negative")
            return
        }

        for i in 0..<count {
            let value = floatPixels[i]
            if value.isFinite {
                // Normalize, clamp to 0-1 range, and invert
                let normalized = (value - minDepth) / range
                floatPixels[i] = 1-max(0.0, min(1.0, normalized))
            }
        }

        CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
    }
    
    func square(){
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        
        CVPixelBufferLockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
        guard let floatBuffer = CVPixelBufferGetBaseAddress(self) else{
            CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
            return
        }
        let floatPixels = floatBuffer.assumingMemoryBound(to: Float.self)
        let count = width * height
        
        for i in 0..<count {
            floatPixels[i] *= floatPixels[i]
        }
        
        CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
    }
}

/// Processes depth data from AVCaptureDepthDataOutput
class DepthProcessor {

    // MARK: - Properties

    /// Default minimum disparity value (meters)
    public static var defaultMinDisparity: Float = 1.321

    /// Default maximum disparity value (meters)
    public static var defaultMaxDisparity: Float = 1.639
    
    /// Aperture size; the radius of the region sampled (0-1)
    public static var APERTURE_SIZE = 0.2

    /// Minimum disparity value for normalization (corresponds to ~5m)
    /// Disparity is inverse of distance, so lower values = farther objects
    var minDisparity: Float = DepthProcessor.defaultMinDisparity

    /// Maximum disparity value for normalization (corresponds to ~0.5m)
    /// Higher values = closer objects
    var maxDisparity: Float = DepthProcessor.defaultMaxDisparity

    // MARK: - Public Methods

    /// Converts and normalizes depth data for visualization
    /// - Parameter depthData: Raw depth data from camera
    /// - Returns: Normalized depth map as CVPixelBuffer
    func processDepthData(_ depthData: AVDepthData) -> CVPixelBuffer {
        // Convert to 32-bit floating-point disparity format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap
        //depthMap.square()
        // Normalize to 0-1 range using fixed disparity range
        depthMap.normalize(minDepth: minDisparity, maxDepth: maxDisparity)

        return depthMap
    }

    /// Calibrates the depth range to fit the current frame using statistical analysis
    /// - Parameter depthData: Raw depth data from camera
    /// - Note: Uses 5th and 95th percentiles to eliminate outliers
    func calibrateToCurrentFrame(from depthData: AVDepthData) {
        // Convert to 32-bit floating-point disparity format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let depthMap = convertedDepth.depthDataMap

        guard let (p5, p95) = calculatePercentiles(from: depthMap) else {
            print("⚠️ Could not calculate frame statistics")
            return
        }

        // Set range based on percentiles (auto-fit to scene)
        minDisparity = p5
        maxDisparity = p95

        print("🎯 Calibrated to scene: P5=\(p5), P95=\(p95) (range: \(p95 - p5))")
    }

    /// Resets the depth range to default values
    func resetToDefaultRange() {
        minDisparity = DepthProcessor.defaultMinDisparity
        maxDisparity = DepthProcessor.defaultMaxDisparity
        print("🔄 Reset to defaults: min=\(DepthProcessor.defaultMinDisparity), max=\(DepthProcessor.defaultMaxDisparity)")
    }

    /// Calculates 5th and 95th percentiles from depth buffer
    /// - Parameter depthMap: Depth pixel buffer
    /// - Returns: Tuple of (P5, P95) or nil if calculation fails
    private func calculatePercentiles(from depthMap: CVPixelBuffer) -> (Float, Float)? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        let count = width * height

        // Collect all valid depth values
        var validValues: [Float] = []
        validValues.reserveCapacity(count)

        for i in 0..<count {
            let value = floatBuffer[i]
            if value.isFinite && value > 0 {
                validValues.append(value)
            }
        }

        guard !validValues.isEmpty else {
            return nil
        }

        // Sort to calculate percentiles
        validValues.sort()

        // Calculate 5th and 95th percentile indices
        let p5Index = Int(Float(validValues.count) * 0.05)
        let p95Index = Int(Float(validValues.count) * 0.95)

        let p5 = validValues[p5Index]
        let p95 = validValues[p95Index]

        // Ensure minimum range
        if p95 - p5 < 0.1 {
            let mid = (p5 + p95) / 2
            return (max(0.1, mid - 0.5), mid + 0.5)
        }

        return (max(0.1, p5), p95)
    }

    /// Samples average depth from a center aperture region
    /// - Parameters:
    ///   - depthMap: Normalized depth pixel buffer
    ///   - apertureSize: Size of the center region to sample (0.0 to 1.0, as fraction of image)
    /// - Returns: Average normalized depth value (0.0 = far, 1.0 = close)
    func sampleCenterDepth(from depthMap: CVPixelBuffer, apertureSize: CGFloat = APERTURE_SIZE) -> Float {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return 0.0
        }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)

        // Calculate aperture bounds (center region)
        let centerX = width / 2
        let centerY = height / 2
        let apertureWidth = Int(CGFloat(width) * apertureSize)
        let apertureHeight = Int(CGFloat(height) * apertureSize)

        let startX = max(0, centerX - apertureWidth / 2)
        let endX = min(width, centerX + apertureWidth / 2)
        let startY = max(0, centerY - apertureHeight / 2)
        let endY = min(height, centerY + apertureHeight / 2)

        // Sample depth values in aperture
        var sum: Float = 0.0
        var count: Int = 0

        for y in startY..<endY {
            for x in startX..<endX {
                let index = y * width + x
                let value = floatBuffer[index]
                if value.isFinite {
                    sum += value
                    count += 1
                }
            }
        }

        return count > 0 ? sum / Float(count) : 0.0
    }
}
