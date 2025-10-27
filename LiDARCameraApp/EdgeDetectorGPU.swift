//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  GPU-accelerated occluding-edge detection using LiDAR depth data
//  Implements Bose et al. (2017), "Fast RGB-D Edge Detection for SLAM"
//
//  The algorithm scans each row and column of the depth map to find
//  occluding edges: pixels where the depth difference to the last valid
//  neighbor exceeds a proportional threshold: |d1 - d2| > min(d1, d2) * T.
//  The nearer pixel is marked as the edge.
//
//  This GPU implementation uses Metal compute kernels for row and column
//  scans, eliminating CPU readbacks and achieving real-time performance.
//

import Foundation
import CoreImage
import CoreVideo
import Metal
import MetalKit

class EdgeDetectorGPU {

    // MARK: - Properties

    private let ciContext: CIContext
    private let metalDevice: MTLDevice?
    private let metalCommandQueue: MTLCommandQueue?
    private var rowPipeline: MTLComputePipelineState?
    private var colPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    // MARK: - Customizable Parameters

    var edgeDetectionThresholdRatio: CGFloat = 0.05
    var edgeAmplification: CGFloat = 2.5
    var edgeThreshold: CGFloat = 0.1
    var enableThresholding: Bool = true
    var preSmoothingRadius: CGFloat = 0.5
    var downscaleFactor: CGFloat = 0.5
    var upscaleOutput: Bool = true

    // MARK: - Initialization

    init() {
        if let dev = MTLCreateSystemDefaultDevice() {
            self.metalDevice = dev
            self.metalCommandQueue = dev.makeCommandQueue()
            self.ciContext = CIContext(mtlDevice: dev)
        } else {
            self.metalDevice = nil
            self.metalCommandQueue = nil
            self.ciContext = CIContext()
        }

        // Compile compute shaders
        if let dev = metalDevice {
            do {
                let lib = try dev.makeLibrary(source: EdgeDetectorGPU.occludingEdgeComputeSource, options: nil)
                if let rowFunc = lib.makeFunction(name: "rowScan"),
                   let colFunc = lib.makeFunction(name: "colScan") {
                    self.rowPipeline = try dev.makeComputePipelineState(function: rowFunc)
                    self.colPipeline = try dev.makeComputePipelineState(function: colFunc)
                }
            } catch {
                print("⚠️ Failed to compile Metal kernels: \(error)")
            }

            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache
        }
    }

    // MARK: - Metal Compute Kernels

    private static let occludingEdgeComputeSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Row-scan kernel: each thread scans one row
    kernel void rowScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::read_write> maskTex [[texture(1)]],
        constant float &ratio [[buffer(0)]],
        uint row [[thread_position_in_grid]]
    ) {
        uint width = depthTex.get_width();
        uint height = depthTex.get_height();
        if (row >= height) return;

        int lastX = -1;
        float lastV = 0.0f;

        for (uint x = 0; x < width; ++x) {
            float d = depthTex.read(uint2(x, row)).r;
            if (d > 0.0f) {
                if (lastX >= 0) {
                    float thresh = min(d, lastV) * ratio;
                    if ((lastV - d) > thresh) {
                        maskTex.write(float4(1.0), uint2(x, row));
                    } else if ((d - lastV) > thresh) {
                        maskTex.write(float4(1.0), uint2(lastX, row));
                    }
                }
                lastX = int(x);
                lastV = d;
            }
        }
    }

    // Column-scan kernel: each thread scans one column
    kernel void colScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::read_write> maskTex [[texture(1)]],
        constant float &ratio [[buffer(0)]],
        uint col [[thread_position_in_grid]]
    ) {
        uint width = depthTex.get_width();
        uint height = depthTex.get_height();
        if (col >= width) return;

        int lastY = -1;
        float lastV = 0.0f;

        for (uint y = 0; y < height; ++y) {
            float d = depthTex.read(uint2(col, y)).r;
            if (d > 0.0f) {
                if (lastY >= 0) {
                    float thresh = min(d, lastV) * ratio;
                    if ((lastV - d) > thresh) {
                        maskTex.write(float4(1.0), uint2(col, y));
                    } else if ((d - lastV) > thresh) {
                        maskTex.write(float4(1.0), uint2(col, lastY));
                    }
                }
                lastY = int(y);
                lastV = d;
            }
        }
    }
    """

    // MARK: - Main Edge Detection

    func detectEdges(rgbImage: CIImage?, depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        return detectDepthEdges(from: depthMap)
    }

    private func detectDepthEdges(from depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        var ciDepth = CIImage(cvPixelBuffer: depthMap)
        let originalExtent = ciDepth.extent

        // Clamp invalid depth range
        if let clamp = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: ciDepth,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 99, y: 99, z: 99, w: 1)
        ]), let output = clamp.outputImage {
            ciDepth = output
        }

        // Downscale for performance
        if downscaleFactor < 1.0,
           let scale = CIFilter(name: "CILanczosScaleTransform", parameters: [
                kCIInputImageKey: ciDepth,
                kCIInputScaleKey: downscaleFactor,
                kCIInputAspectRatioKey: 1.0
           ]), let out = scale.outputImage {
            ciDepth = out
        }

        // Optional blur smoothing
        if preSmoothingRadius > 0.0,
           let blur = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: ciDepth,
                kCIInputRadiusKey: preSmoothingRadius
           ]), let out = blur.outputImage {
            ciDepth = out
        }

        // Perform GPU row/column scans
        guard var edgeImage = runGPUScan(depthCIImage: ciDepth, ratio: Float(edgeDetectionThresholdRatio)) else {
            return nil
        }

        // Amplify
        if edgeAmplification > 1.0,
           let mult = CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: edgeImage,
                "inputRVector": CIVector(x: edgeAmplification, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: edgeAmplification, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: edgeAmplification, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
           ]), let out = mult.outputImage {
            edgeImage = out
        }

        // Threshold
        if enableThresholding && edgeThreshold > 0.0,
           let clamp = CIFilter(name: "CIColorClamp", parameters: [
                kCIInputImageKey: edgeImage,
                "inputMinComponents": CIVector(x: edgeThreshold, y: edgeThreshold, z: edgeThreshold, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
           ]), let out = clamp.outputImage {
            edgeImage = out
        }

        // Upscale to original
        if upscaleOutput && downscaleFactor < 1.0 {
            let currentW = edgeImage.extent.width
            let targetW = originalExtent.width
            let scale = targetW / currentW
            if let up = CIFilter(name: "CILanczosScaleTransform", parameters: [
                kCIInputImageKey: edgeImage,
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0
            ]), let out = up.outputImage {
                edgeImage = out
            }
        }

        return createPixelBuffer(from: edgeImage)
    }

    // MARK: - GPU Row/Column Scan Logic

    private func runGPUScan(depthCIImage: CIImage, ratio: Float) -> CIImage? {
        guard let dev = metalDevice,
              let queue = metalCommandQueue,
              let cache = textureCache,
              let rowPipe = rowPipeline,
              let colPipe = colPipeline else {
            return nil
        }

        let width = Int(depthCIImage.extent.width)
        let height = Int(depthCIImage.extent.height)

        // Create source & mask textures
        var srcPixelBuffer: CVPixelBuffer?
        let options: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true
        ] as CFDictionary

        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float, options, &srcPixelBuffer)
        guard let srcPB = srcPixelBuffer else { return nil }

        var srcTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, srcPB, nil, .r32Float, width, height, 0, &srcTexRef)
        guard let srcTexture = srcTexRef.flatMap(CVMetalTextureGetTexture) else { return nil }

        // Render CI depth image into Metal texture
        let cmdBuf = queue.makeCommandBuffer()
        ciContext.render(depthCIImage, to: srcTexture, commandBuffer: cmdBuf, bounds: depthCIImage.extent, colorSpace: CGColorSpaceCreateDeviceGray())
        cmdBuf?.commit()
        cmdBuf?.waitUntilCompleted()

        // Create mask texture (BGRA for CI compatibility)
        var maskPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options, &maskPB)
        guard let maskPixelBuffer = maskPB else { return nil }

        var maskTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, maskPixelBuffer, nil, .bgra8Unorm, width, height, 0, &maskTexRef)
        guard let maskTexture = maskTexRef.flatMap(CVMetalTextureGetTexture) else { return nil }

        // Clear mask
        let zero = MTLRegionMake2D(0, 0, width, height)
        var rowZeros = [UInt8](repeating: 0, count: width * 4)
        for y in 0..<height {
            maskTexture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0, withBytes: rowZeros, bytesPerRow: width * 4)
        }

        // Dispatch row scan
        guard let rowCmd = queue.makeCommandBuffer(),
              let encoder = rowCmd.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(rowPipe)
        encoder.setTexture(srcTexture, index: 0)
        encoder.setTexture(maskTexture, index: 1)
        var ratioVar = ratio
        encoder.setBytes(&ratioVar, length: MemoryLayout<Float>.size, index: 0)

        let threadsPerGrid = MTLSize(width: height, height: 1, depth: 1)
        let threadsPerGroup = MTLSize(width: min(rowPipe.maxTotalThreadsPerThreadgroup, height), height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        rowCmd.commit()
        rowCmd.waitUntilCompleted()

        // Dispatch column scan
        guard let colCmd = queue.makeCommandBuffer(),
              let encoder2 = colCmd.makeComputeCommandEncoder() else { return nil }

        encoder2.setComputePipelineState(colPipe)
        encoder2.setTexture(srcTexture, index: 0)
        encoder2.setTexture(maskTexture, index: 1)
        encoder2.setBytes(&ratioVar, length: MemoryLayout<Float>.size, index: 0)

        let threadsPerGrid2 = MTLSize(width: width, height: 1, depth: 1)
        let threadsPerGroup2 = MTLSize(width: min(colPipe.maxTotalThreadsPerThreadgroup, width), height: 1, depth: 1)
        encoder2.dispatchThreads(threadsPerGrid2, threadsPerThreadgroup: threadsPerGroup2)
        encoder2.endEncoding()
        colCmd.commit()
        colCmd.waitUntilCompleted()

        // Return CIImage from mask
        return CIImage(cvPixelBuffer: maskPixelBuffer)
    }

    // MARK: - Helper

    private func createPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixelBuffer: CVPixelBuffer?
        let opts = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float, opts, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        ciContext.render(image, to: buffer)
        return buffer
    }

    // MARK: - Presets

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
}
