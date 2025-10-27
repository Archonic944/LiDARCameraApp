//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  GPU-accelerated occluding-edge detection using LiDAR depth data
//  Implements Bose et al. (2017), "Fast RGB-D Edge Detection for SLAM" Algorithm 1
//
//  The algorithm scans each row and column of the depth map to find
//  occluding edges: pixels where the depth difference to the last valid
//  neighbor exceeds a proportional threshold: |d1 - d2| > min(d1, d2) * T.
//  The nearer pixel is marked as the edge.
//
//  This GPU implementation uses Metal compute kernels for row and column
//  scans, eliminating CPU readbacks and achieving real-time performance.

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
    private var combinePipeline: MTLComputePipelineState?
    private var clearPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var supportsNonUniformThreadgroups: Bool = false

    // MARK: - Customizable Parameters

    var edgeDetectionThresholdRatio: CGFloat = 0.05
    var edgeAmplification: CGFloat = 2.5
    var edgeThreshold: CGFloat = 0.1
    var enableThresholding: Bool = true
    var preSmoothingRadius: CGFloat = 0.5
    var downscaleFactor: CGFloat = 0.8

    // MARK: - Initialization

    init() {
        if let dev = MTLCreateSystemDefaultDevice() {
            self.metalDevice = dev
            self.metalCommandQueue = dev.makeCommandQueue()
            self.ciContext = CIContext(mtlDevice: dev)
            
            // Check for non-uniform threadgroup support
            if #available(iOS 11.0, macOS 10.13, *) {
                self.supportsNonUniformThreadgroups = dev.supportsFamily(.apple4) ||
                                                       dev.supportsFamily(.mac2)
            }
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
                   let colFunc = lib.makeFunction(name: "colScan"),
                   let combineFunc = lib.makeFunction(name: "combineMasks"),
                   let clearFunc = lib.makeFunction(name: "clearTexture") {
                    self.rowPipeline = try dev.makeComputePipelineState(function: rowFunc)
                    self.colPipeline = try dev.makeComputePipelineState(function: colFunc)
                    self.combinePipeline = try dev.makeComputePipelineState(function: combineFunc)
                    self.clearPipeline = try dev.makeComputePipelineState(function: clearFunc)
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

    // Clear texture kernel - GPU-based clearing
    kernel void clearTexture(
        texture2d<float, access::write> tex [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = tex.get_width();
        uint height = tex.get_height();
        if (gid.x >= width || gid.y >= height) return;
        tex.write(float4(0.0), gid);
    }

    // Row-scan kernel: each thread scans one row
    // Writes to separate output texture to avoid race conditions
    kernel void rowScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> rowMaskTex [[texture(1)]],
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
                        rowMaskTex.write(float4(1.0), uint2(x, row));
                    } else if ((d - lastV) > thresh) {
                        rowMaskTex.write(float4(1.0), uint2(lastX, row));
                    }
                }
                lastX = int(x);
                lastV = d;
            }
        }
    }

    // Column-scan kernel: each thread scans one column
    // Writes to separate output texture to avoid race conditions
    kernel void colScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> colMaskTex [[texture(1)]],
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
                        colMaskTex.write(float4(1.0), uint2(col, y));
                    } else if ((d - lastV) > thresh) {
                        colMaskTex.write(float4(1.0), uint2(col, lastY));
                    }
                }
                lastY = int(y);
                lastV = d;
            }
        }
    }

    // Combine row and column masks into final output
    kernel void combineMasks(
        texture2d<float, access::read> rowMaskTex [[texture(0)]],
        texture2d<float, access::read> colMaskTex [[texture(1)]],
        texture2d<float, access::write> outputTex [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint width = outputTex.get_width();
        uint height = outputTex.get_height();
        if (gid.x >= width || gid.y >= height) return;

        float rowEdge = rowMaskTex.read(gid).r;
        float colEdge = colMaskTex.read(gid).r;
        
        // Combine edges with max operation
        float combinedEdge = max(rowEdge, colEdge);
        outputTex.write(float4(combinedEdge), gid);
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

        return createPixelBuffer(from: edgeImage)
    }

    // MARK: - GPU Row/Column Scan Logic

    private func runGPUScan(depthCIImage: CIImage, ratio: Float) -> CIImage? {
        guard let dev = metalDevice,
              let queue = metalCommandQueue,
              let cache = textureCache,
              let rowPipe = rowPipeline,
              let colPipe = colPipeline,
              let combinePipe = combinePipeline,
              let clearPipe = clearPipeline else {
            return nil
        }

        let width = Int(depthCIImage.extent.width)
        let height = Int(depthCIImage.extent.height)

        // Create source texture
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

        // Create row mask texture (RGBA for better compatibility)
        var rowMaskPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options, &rowMaskPB)
        guard let rowMaskPixelBuffer = rowMaskPB else { return nil }

        var rowMaskTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, rowMaskPixelBuffer, nil, .bgra8Unorm, width, height, 0, &rowMaskTexRef)
        guard let rowMaskTexture = rowMaskTexRef.flatMap(CVMetalTextureGetTexture) else { return nil }

        // Create column mask texture (RGBA for better compatibility)
        var colMaskPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options, &colMaskPB)
        guard let colMaskPixelBuffer = colMaskPB else { return nil }

        var colMaskTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, colMaskPixelBuffer, nil, .bgra8Unorm, width, height, 0, &colMaskTexRef)
        guard let colMaskTexture = colMaskTexRef.flatMap(CVMetalTextureGetTexture) else { return nil }

        // Create output mask texture
        var outputMaskPB: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options, &outputMaskPB)
        guard let outputMaskPixelBuffer = outputMaskPB else { return nil }

        var outputMaskTexRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, outputMaskPixelBuffer, nil, .bgra8Unorm, width, height, 0, &outputMaskTexRef)
        guard let outputMaskTexture = outputMaskTexRef.flatMap(CVMetalTextureGetTexture) else { return nil }

        // Clear row mask texture using GPU
        guard let clearRowCmd = queue.makeCommandBuffer(),
              let clearRowEncoder = clearRowCmd.makeComputeCommandEncoder() else { return nil }
        
        clearRowEncoder.setComputePipelineState(clearPipe)
        clearRowEncoder.setTexture(rowMaskTexture, index: 0)
        
        let clearThreadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let clearThreadExecutionWidth = clearPipe.threadExecutionWidth
        let clearThreadsPerGroup = MTLSize(width: clearThreadExecutionWidth, height: 1, depth: 1)
        
        if supportsNonUniformThreadgroups {
            clearRowEncoder.dispatchThreads(clearThreadsPerGrid, threadsPerThreadgroup: clearThreadsPerGroup)
        } else {
            let groupsW = (width + clearThreadExecutionWidth - 1) / clearThreadExecutionWidth
            let groupsH = height
            clearRowEncoder.dispatchThreadgroups(MTLSize(width: groupsW, height: groupsH, depth: 1),
                                                 threadsPerThreadgroup: clearThreadsPerGroup)
        }
        clearRowEncoder.endEncoding()
        clearRowCmd.commit()
        clearRowCmd.waitUntilCompleted()

        // Clear column mask texture using GPU
        guard let clearColCmd = queue.makeCommandBuffer(),
              let clearColEncoder = clearColCmd.makeComputeCommandEncoder() else { return nil }
        
        clearColEncoder.setComputePipelineState(clearPipe)
        clearColEncoder.setTexture(colMaskTexture, index: 0)
        clearColEncoder.dispatchThreads(clearThreadsPerGrid, threadsPerThreadgroup: clearThreadsPerGroup)
        clearColEncoder.endEncoding()
        clearColCmd.commit()
        clearColCmd.waitUntilCompleted()

        // Dispatch row scan
        guard let rowCmd = queue.makeCommandBuffer(),
              let rowEncoder = rowCmd.makeComputeCommandEncoder() else { return nil }

        rowEncoder.setComputePipelineState(rowPipe)
        rowEncoder.setTexture(srcTexture, index: 0)
        rowEncoder.setTexture(rowMaskTexture, index: 1)
        var ratioVar = ratio
        rowEncoder.setBytes(&ratioVar, length: MemoryLayout<Float>.size, index: 0)

        let rowThreadExecutionWidth = rowPipe.threadExecutionWidth
        let rowThreadsPerGrid = MTLSize(width: height, height: 1, depth: 1)
        let rowThreadsPerGroup = MTLSize(width: min(rowThreadExecutionWidth, height), height: 1, depth: 1)
        
        if supportsNonUniformThreadgroups {
            rowEncoder.dispatchThreads(rowThreadsPerGrid, threadsPerThreadgroup: rowThreadsPerGroup)
        } else {
            let numGroups = (height + rowThreadsPerGroup.width - 1) / rowThreadsPerGroup.width
            rowEncoder.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1),
                                           threadsPerThreadgroup: rowThreadsPerGroup)
        }
        rowEncoder.endEncoding()
        rowCmd.commit()
        rowCmd.waitUntilCompleted()

        // Dispatch column scan
        guard let colCmd = queue.makeCommandBuffer(),
              let colEncoder = colCmd.makeComputeCommandEncoder() else { return nil }

        colEncoder.setComputePipelineState(colPipe)
        colEncoder.setTexture(srcTexture, index: 0)
        colEncoder.setTexture(colMaskTexture, index: 1)
        colEncoder.setBytes(&ratioVar, length: MemoryLayout<Float>.size, index: 0)

        let colThreadExecutionWidth = colPipe.threadExecutionWidth
        let colThreadsPerGrid = MTLSize(width: width, height: 1, depth: 1)
        let colThreadsPerGroup = MTLSize(width: min(colThreadExecutionWidth, width), height: 1, depth: 1)
        
        if supportsNonUniformThreadgroups {
            colEncoder.dispatchThreads(colThreadsPerGrid, threadsPerThreadgroup: colThreadsPerGroup)
        } else {
            let numGroups = (width + colThreadsPerGroup.width - 1) / colThreadsPerGroup.width
            colEncoder.dispatchThreadgroups(MTLSize(width: numGroups, height: 1, depth: 1),
                                           threadsPerThreadgroup: colThreadsPerGroup)
        }
        colEncoder.endEncoding()
        colCmd.commit()
        colCmd.waitUntilCompleted()

        // Combine row and column masks
        guard let combineCmd = queue.makeCommandBuffer(),
              let combineEncoder = combineCmd.makeComputeCommandEncoder() else { return nil }

        combineEncoder.setComputePipelineState(combinePipe)
        combineEncoder.setTexture(rowMaskTexture, index: 0)
        combineEncoder.setTexture(colMaskTexture, index: 1)
        combineEncoder.setTexture(outputMaskTexture, index: 2)

        let combineThreadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let combineThreadExecutionWidth = combinePipe.threadExecutionWidth
        let combineThreadsPerGroup = MTLSize(width: combineThreadExecutionWidth, height: 1, depth: 1)
        
        if supportsNonUniformThreadgroups {
            combineEncoder.dispatchThreads(combineThreadsPerGrid, threadsPerThreadgroup: combineThreadsPerGroup)
        } else {
            let groupsW = (width + combineThreadExecutionWidth - 1) / combineThreadExecutionWidth
            let groupsH = height
            combineEncoder.dispatchThreadgroups(MTLSize(width: groupsW, height: groupsH, depth: 1),
                                               threadsPerThreadgroup: combineThreadsPerGroup)
        }
        combineEncoder.endEncoding()
        combineCmd.commit()
        combineCmd.waitUntilCompleted()

        // Return CIImage from combined mask
        return CIImage(cvPixelBuffer: outputMaskPixelBuffer)
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
}
