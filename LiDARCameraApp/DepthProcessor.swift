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
    /// Normalizes the pixel buffer values to 0-1 range
    /// - Note: Modifies the buffer in-place
    func normalize() {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        CVPixelBufferLockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
        guard let floatBuffer = CVPixelBufferGetBaseAddress(self) else {
            CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
            return
        }

        let floatPixels = floatBuffer.assumingMemoryBound(to: Float.self)
        let count = width * height

        // Find min and max values
        var minVal: Float = Float.greatestFiniteMagnitude
        var maxVal: Float = -Float.greatestFiniteMagnitude

        for i in 0..<count {
            let value = floatPixels[i]
            if value.isFinite {
                minVal = min(minVal, value)
                maxVal = max(maxVal, value)
            }
        }

        // Normalize to 0-1 range
        let range = maxVal - minVal
        if range > 0 {
            for i in 0..<count {
                let value = floatPixels[i]
                if value.isFinite {
                    floatPixels[i] = (value - minVal) / range
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(self, CVPixelBufferLockFlags(rawValue: 0))
    }
}

/// Processes depth data from AVCaptureDepthDataOutput
class DepthProcessor {

    // MARK: - Public Methods

    /// Converts and normalizes depth data for visualization
    /// - Parameter depthData: Raw depth data from camera
    /// - Returns: Normalized depth map as CVPixelBuffer
    func processDepthData(_ depthData: AVDepthData) -> CVPixelBuffer {
        // Convert to 32-bit floating-point disparity format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let depthMap = convertedDepth.depthDataMap

        // Normalize to 0-1 range for visualization
        depthMap.normalize()

        return depthMap
    }
}
