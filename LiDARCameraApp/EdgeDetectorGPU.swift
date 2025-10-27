//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  GPU-accelerated edge detection using LiDAR depth data only
//
//  ALGORITHM OVERVIEW:
//  This depth-only approach detects "occluding edges" by analyzing sharp discontinuities in the LiDAR depth map.
//  The algorithm is a GPU-accelerated implementation of the method described by Bose, et al. in
//  "Fast RGB-D Edge Detection for SLAM" (2017).
//
//  An edge is detected if the depth difference between two adjacent pixels exceeds a proportional threshold
//  (i.e., `abs(depth1 - depth2) > min(depth1, depth2) * ratio`). The pixel closer to the camera is marked as the edge.
//  This method is effective at finding object boundaries and sharp drop-offs like curbs and walls.
//
//  IMPLEMENTATION DETAILS:
//  Uses a custom Core Image Kernel written in Metal Shading Language (MSL) for massively parallel GPU execution.
//  The kernel checks each pixel against its 4 neighbors. The rest of the pipeline handles downscaling for performance,
//  amplification, and thresholding. All operations execute on the GPU via Metal for real-time performance.
//
//  CUSTOMIZABLE PARAMETERS:
//  - edgeDetectionThresholdRatio: Proportional threshold for edge detection (lower = more sensitive). Default: 0.05
//  - edgeAmplification: Multiplier for edge strength (default: 2.5)
//  - edgeThreshold: Minimum edge strength to display (default: 0.1)
//

import Foundation
import CoreImage
import CoreVideo

/// GPU-accelerated edge detector using a proportional-threshold method on depth data.
class EdgeDetectorGPU {

    // MARK: - Properties

    private let ciContext: CIContext
    private let occludingEdgeKernel: CIKernel

    // MARK: - Custom Kernel Source (Metal Shading Language)

    private static let occludingEdgeMetalSource = """
    #include <CoreImage/CoreImage.h>

    extern "C" {
        namespace coreimage {
            float4 occludingEdge(sampler src, float ratio) {
                float d = src.sample(src.coord()).r;
                if (d == 0.0) { return float4(0.0); }

                float2 neighbors[] = {
                    float2(1.0, 0.0),
                    float2(-1.0, 0.0),
                    float2(0.0, 1.0),
                    float2(0.0, -1.0)
                };

                for (int i = 0; i < 4; i++) {
                    float d_n = src.sample(src.coord() + neighbors[i]).r;
                    if (d_n > 0.0) {
                        float threshold = min(d, d_n) * ratio;
                        if (abs(d - d_n) > threshold && d < d_n) {
                            return float4(1.0);
                        }
                    }
                }

                return float4(0.0);
            }
        }
    }
    """

    // MARK: - Customizable Edge Detection Parameters

    /// Proportional threshold for edge detection. A lower value detects more edges.
    /// Represents the `T` parameter from the research paper.
    /// `abs(d1 - d2) > min(d1, d2) * ratio`
    /// Default: 0.05
    var edgeDetectionThresholdRatio: CGFloat = 0.05

    /// Multiplier for edge strength amplification (higher = more visible edges)
    /// Default: 2.5
    var edgeAmplification: CGFloat = 2.5

    /// Minimum edge strength threshold (0.0 - 1.0). Edges below this are filtered out.
    /// Default: 0.1
    var edgeThreshold: CGFloat = 0.1

    /// Enable/disable edge thresholding.
    /// Default: true
    var enableThresholding: Bool = true

    /// Smoothing factor applied before edge detection (reduces noise).
    /// Default: 0.5
    var preSmoothingRadius: CGFloat = 0.5

    // MARK: - Performance Parameters

    /// Downscale factor for processing (massive performance boost!).
    /// Default: 0.5 (4x faster, great quality/performance balance)
    var downscaleFactor: CGFloat = 0.5

    /// Upscale output back to original resolution after processing.
    /// Default: true
    var upscaleOutput: Bool = true

    // MARK: - Initialization

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }

        do {
            // Load and compile the custom kernel from the Metal source string
            let kernels = try CIKernel.kernels(withMetalString: EdgeDetectorGPU.occludingEdgeMetalSource)
            if let kernel = kernels.first {
                self.occludingEdgeKernel = kernel
            } else {
                fatalError("❌ Custom Metal kernel 'occludingEdge' not found.")
            }
        } catch {
            fatalError("❌ Failed to load custom Metal kernel with error: \(error)")
        }
    }

    // MARK: - Edge Detection

    func detectEdges(rgbImage: CIImage?, depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        return detectDepthEdges(from: depthMap)
    }

    // MARK: - Depth Edge Detection

    private func detectDepthEdges(from depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        var ciDepth = CIImage(cvPixelBuffer: depthMap)
        let originalExtent = ciDepth.extent

        // Clamp to reasonable range: [0, 99] meters (handles NaN/Inf)
        if let clampFilter = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: ciDepth,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 99, y: 99, z: 99, w: 1)
        ]), let output = clampFilter.outputImage {
            ciDepth = output
        }

        // PERFORMANCE: Downscale before processing
        if downscaleFactor < 1.0,
           let scaleFilter = CIFilter(name: "CILanczosScaleTransform", parameters: [
                kCIInputImageKey: ciDepth,
                kCIInputScaleKey: downscaleFactor,
                kCIInputAspectRatioKey: 1.0
           ]), let scaled = scaleFilter.outputImage {
            ciDepth = scaled
        }

        // Optional pre-smoothing to reduce noise
        if preSmoothingRadius > 0.0,
           let blurFilter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: ciDepth,
                kCIInputRadiusKey: preSmoothingRadius
           ]), let output = blurFilter.outputImage {
            ciDepth = output
        }

        // Apply custom occluding edge detection kernel
        let roi = ciDepth.extent
        guard var edgeImage = self.occludingEdgeKernel.apply(
            extent: roi,
            roiCallback: { _, rect in rect },
            arguments: [ciDepth, self.edgeDetectionThresholdRatio]
        ) else {
            return nil
        }

        // Amplify depth edges
        if edgeAmplification > 1.0,
           let multiplyFilter = CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: edgeImage,
                "inputRVector": CIVector(x: edgeAmplification, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: edgeAmplification, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: edgeAmplification, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
           ]), let output = multiplyFilter.outputImage {
            edgeImage = output
        }

        // Optional thresholding to filter weak edges
        if enableThresholding && edgeThreshold > 0.0,
           let clampFilter = CIFilter(name: "CIColorClamp", parameters: [
                kCIInputImageKey: edgeImage,
                "inputMinComponents": CIVector(x: edgeThreshold, y: edgeThreshold, z: edgeThreshold, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
           ]), let output = clampFilter.outputImage {
            edgeImage = output
        }

        // PERFORMANCE: Upscale back to original resolution
        if upscaleOutput && downscaleFactor < 1.0 {
            let currentWidth = edgeImage.extent.width
            let targetWidth = originalExtent.width
            let upscale = targetWidth / currentWidth
            if let scaleFilter = CIFilter(name: "CILanczosScaleTransform", parameters: [
                kCIInputImageKey: edgeImage,
                kCIInputScaleKey: upscale,
                kCIInputAspectRatioKey: 1.0
            ]), let scaled = scaleFilter.outputImage {
                edgeImage = scaled
            }
        }

        return createPixelBuffer(from: edgeImage)
    }

    // MARK: - Calibration & Presets

    func resetToDefaults() {
        edgeDetectionThresholdRatio = 0.05
        edgeAmplification = 2.5
        edgeThreshold = 0.1
        enableThresholding = true
        preSmoothingRadius = 0.5
        downscaleFactor = 0.5
        upscaleOutput = true
    }

    func applySubtlePreset() {
        edgeDetectionThresholdRatio = 0.1
        edgeAmplification = 1.5
        edgeThreshold = 0.15
        enableThresholding = true
        preSmoothingRadius = 1.0
        downscaleFactor = 0.75
        upscaleOutput = true
    }

    func applyStrongPreset() {
        edgeDetectionThresholdRatio = 0.03
        edgeAmplification = 3.5
        edgeThreshold = 0.05
        enableThresholding = true
        preSmoothingRadius = 0.5
        downscaleFactor = 0.5
        upscaleOutput = true
    }

    func applyMaximumPreset() {
        edgeDetectionThresholdRatio = 0.01
        edgeAmplification = 5.0
        edgeThreshold = 0.0
        enableThresholding = false
        preSmoothingRadius = 0.0
        downscaleFactor = 0.5
        upscaleOutput = true
    }

    func applyCleanPreset() {
        edgeDetectionThresholdRatio = 0.08
        edgeAmplification = 2.5
        edgeThreshold = 0.2
        enableThresholding = true
        preSmoothingRadius = 1.5
        downscaleFactor = 0.5
        upscaleOutput = true
    }

    func applyPerformancePreset() {
        edgeDetectionThresholdRatio = 0.05
        edgeAmplification = 2.5
        edgeThreshold = 0.1
        enableThresholding = true
        preSmoothingRadius = 0.0
        downscaleFactor = 0.25
        upscaleOutput = false
    }

    // MARK: - Helper Methods

    private func createPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixelBuffer: CVPixelBuffer?
        let options = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float, options, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }
}
