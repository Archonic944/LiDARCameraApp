//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  GPU-accelerated edge detection using LiDAR depth data only
//
//  ALGORITHM OVERVIEW:
//  This depth-only approach detects edges by analyzing geometric discontinuities in the LiDAR depth map.
//  Depth edge detection finds surface boundaries and depth jumps using Sobel gradient analysis.
//  The edge strength can be amplified and thresholded using customizable parameters.
//
//  IMPLEMENTATION DETAILS:
//  Uses Core Image filters for GPU acceleration. Depth edges detected via CISobelGradients on the
//  depth map (raw meter values). Edge amplification uses CIColorMatrix for intensity scaling.
//  Optional thresholding filters out weak edges. All operations execute on GPU via Metal,
//  achieving <10ms processing time for real-time performance. Output is normalized edge strength
//  map (0-1 range) suitable for visualization or further processing.
//
//  CUSTOMIZABLE PARAMETERS:
//  - edgeAmplification: Multiplier for edge strength (default: 2.0)
//  - edgeThreshold: Minimum edge strength to display (default: 0.1)
//  - enableThresholding: Whether to apply threshold filter (default: true)
//

import Foundation
import CoreImage
import CoreVideo

/// GPU-accelerated edge detector using depth data only
class EdgeDetectorGPU {

    // MARK: - Properties

    private let ciContext: CIContext

    // MARK: - Customizable Edge Detection Parameters

    /// Multiplier for edge strength amplification (higher = more visible edges)
    /// Typical range: 1.0 - 5.0
    /// Default: 2.0
    var edgeAmplification: CGFloat = 2.0

    /// Minimum edge strength threshold (0.0 - 1.0)
    /// Edges below this value are filtered out
    /// Lower values = more edges visible, higher values = only strong edges
    /// Default: 0.1
    var edgeThreshold: CGFloat = 0.6

    /// Enable/disable edge thresholding
    /// When false, all edges are shown regardless of strength
    /// Default: true
    var enableThresholding: Bool = true

    /// Smoothing factor applied before edge detection (reduces noise)
    /// Higher values = smoother edges, but may lose detail
    /// Set to 0.0 to disable smoothing
    /// Default: 0.0 (disabled)
    var preSmoothingRadius: CGFloat = 0.2

    // MARK: - Initialization

    init() {
        // Create GPU-accelerated context
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }

    // MARK: - Edge Detection

    /// Detects edges using depth data only
    /// - Parameters:
    ///   - rgbImage: RGB camera frame (IGNORED - kept for API compatibility)
    ///   - depthMap: Depth map as CVPixelBuffer (raw meter values)
    /// - Returns: Depth edge map as CVPixelBuffer, or nil if detection fails
    func detectEdges(rgbImage: CIImage?, depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        return detectDepthEdges(from: depthMap)
    }

    // MARK: - Depth Edge Detection

    /// Detects edges in depth map using gradient analysis with customizable parameters
    /// - Parameter depthMap: Depth map as CVPixelBuffer (raw meter values)
    /// - Returns: Edge map as CVPixelBuffer, or nil if detection fails
    private func detectDepthEdges(from depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        // Convert depth map to CIImage
        var ciDepth = CIImage(cvPixelBuffer: depthMap)

        // Optional pre-smoothing to reduce noise
        if preSmoothingRadius > 0.0 {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(ciDepth, forKey: kCIInputImageKey)
                blurFilter.setValue(preSmoothingRadius, forKey: kCIInputRadiusKey)
                if let output = blurFilter.outputImage {
                    ciDepth = output
                }
            }
        }

        // Apply Sobel gradient to depth (finds depth discontinuities)
        guard let sobelFilter = CIFilter(name: "CISobelGradients") else {
            print("❌ CISobelGradients filter not available")
            return nil
        }

        sobelFilter.setValue(ciDepth, forKey: kCIInputImageKey)

        guard var edgeImage = sobelFilter.outputImage else {
            return nil
        }

        // Amplify depth edges using customizable amplification factor
        if let multiplyFilter = CIFilter(name: "CIColorMatrix") {
            multiplyFilter.setValue(edgeImage, forKey: kCIInputImageKey)
            let scale = edgeAmplification
            multiplyFilter.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
            multiplyFilter.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
            multiplyFilter.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
            multiplyFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")

            if let output = multiplyFilter.outputImage {
                edgeImage = output
            }
        }

        // Optional thresholding to filter weak edges
        if enableThresholding && edgeThreshold > 0.0 {
            // Step 1: Subtract threshold using color matrix
            if let subtractFilter = CIFilter(name: "CIColorMatrix") {
                subtractFilter.setValue(edgeImage, forKey: kCIInputImageKey)
                // Keep RGB channels as-is (multiplied by 1)
                subtractFilter.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                subtractFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                subtractFilter.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                subtractFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                // Subtract threshold from all channels via bias vector
                subtractFilter.setValue(CIVector(x: -edgeThreshold, y: -edgeThreshold, z: -edgeThreshold, w: 0), forKey: "inputBiasVector")

                if let subtracted = subtractFilter.outputImage {
                    edgeImage = subtracted
                }
            }

            // Step 2: Clamp negatives to 0 (removes values that were below threshold)
            if let clampFilter = CIFilter(name: "CIColorClamp") {
                clampFilter.setValue(edgeImage, forKey: kCIInputImageKey)
                // Clamp minimum to 0 (removes negative values from subtraction)
                clampFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
                // Keep maximum at 1.0
                clampFilter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")

                if let output = clampFilter.outputImage {
                    edgeImage = output
                }
            }
        }

        // Convert to pixel buffer
        return createPixelBuffer(from: edgeImage)
    }

    // MARK: - Helper Methods

    /// Creates a CVPixelBuffer from CIImage
    private func createPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)

        var pixelBuffer: CVPixelBuffer?
        let options = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent32Float,
            options,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        // Render to pixel buffer
        ciContext.render(image, to: buffer)

        return buffer
    }
}
