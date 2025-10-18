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
    /// Normalizes the pixel buffer values to 0-1 range using fixed range
    /// - Parameters:
    ///   - minDisparity: Minimum disparity value (far objects)
    ///   - maxDisparity: Maximum disparity value (near objects)
    /// - Note: Modifies the buffer in-place. Values outside range are clamped.
    func normalize(minDisparity: Float, maxDisparity: Float) {
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
        let range = maxDisparity - minDisparity
        guard range > 0 else {
            CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
            return
        }

        for i in 0..<count {
            let value = floatPixels[i]
            if value.isFinite {
                // Normalize and clamp to 0-1 range
                let normalized = (value - minDisparity) / range
                floatPixels[i] = max(0.0, min(1.0, normalized))
            }
        }

        CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
    }
}

/// Processes depth data from AVCaptureDepthDataOutput
class DepthProcessor {

    // MARK: - Properties

    /// Minimum disparity value for normalization (corresponds to ~5m)
    /// Disparity is inverse of distance, so lower values = farther objects
    var minDisparity: Float = 0.2

    /// Maximum disparity value for normalization (corresponds to ~0.5m)
    /// Higher values = closer objects
    var maxDisparity: Float = 2.0

    // MARK: - Public Methods

    /// Converts and normalizes depth data for visualization
    /// - Parameter depthData: Raw depth data from camera
    /// - Returns: Normalized depth map as CVPixelBuffer
    func processDepthData(_ depthData: AVDepthData) -> CVPixelBuffer {
        // Convert to 32-bit floating-point disparity format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let depthMap = convertedDepth.depthDataMap

        // Normalize to 0-1 range using fixed disparity range
        depthMap.normalize(minDisparity: minDisparity, maxDisparity: maxDisparity)

        return depthMap
    }

    /// Samples average depth from a center aperture region
    /// - Parameters:
    ///   - depthMap: Normalized depth pixel buffer
    ///   - apertureSize: Size of the center region to sample (0.0 to 1.0, as fraction of image)
    /// - Returns: Average normalized depth value (0.0 = far, 1.0 = close)
    func sampleCenterDepth(from depthMap: CVPixelBuffer, apertureSize: CGFloat = 0.1) -> Float {
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
