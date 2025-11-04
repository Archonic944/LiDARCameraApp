//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  GPU-accelerated occluding-edge detection using LiDAR depth data
//  Implements Bose et al. (2017), "Fast RGB-D Edge Detection for SLAM"
//  - Algorithm 1 (P_Scan): Row and column depth discontinuity scanning
//  - Algorithm 2 (Occluding_Edge_Detection): Patch-based temporal coherence optimization
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
    private var combinePipeline: MTLComputePipelineState?
    private var clearPipeline: MTLComputePipelineState?
    private var checkPatchPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var supportsNonUniformThreadgroups: Bool = false

    // Persistent/reused pixel buffers & textures (to avoid per-frame allocations)
    private var srcPixelBuffer: CVPixelBuffer?
    private var srcTexture: MTLTexture?

    private var rowMaskPixelBuffer: CVPixelBuffer?
    private var rowMaskTexture: MTLTexture?
    private var colMaskPixelBuffer: CVPixelBuffer?
    private var colMaskTexture: MTLTexture?
    private var outputMaskPixelBuffer: CVPixelBuffer?
    private var outputMaskTexture: MTLTexture?

    // Persistent small GPU buffer: one uint per patch indicating "has edge"
    private var patchFlagBuffer: MTLBuffer?



    // Keep last size to detect resize
    private var lastTextureWidth: Int = 0
    private var lastTextureHeight: Int = 0

    // MARK: - Customizable Parameters

    var edgeDetectionThresholdRatio: CGFloat = 0.2 // Baseline, physical threshold for physical sensitivity of the detector. Higher = less sensitive
    var edgeAmplification: CGFloat = 2.5
    var edgeThreshold: CGFloat = 0.4 // Threshold for simple post-processing cleanup
    var enableThresholding: Bool = true
    var preSmoothingRadius: CGFloat = 0.5
    var downscaleFactor: CGFloat = 0.8

    // MARK: - Algorithm 2 Parameters (Patch-based Temporal Coherence)

    var enablePatchOptimization: Bool = true
    var patchGridWidth: Int = 32
    var patchGridHeight: Int = 24
    var randomSearchRate: CGFloat = 0.05
    var rowColSkip: Int = 1

    // MARK: - Temporal State

    private var patchFlags: [[Bool]] = []
    private var previousImageSize: CGSize = .zero

    // MARK: - Initialization

    init() {
        if let dev = MTLCreateSystemDefaultDevice() {
            self.metalDevice = dev
            self.metalCommandQueue = dev.makeCommandQueue()
            self.ciContext = CIContext(mtlDevice: dev)

            // Check for non-uniform threadgroup support (best effort heuristic)
            if #available(iOS 11.0, macOS 10.13, *) {
                self.supportsNonUniformThreadgroups = true
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
                   let clearFunc = lib.makeFunction(name: "clearTexture"),
                   let checkPatchFunc = lib.makeFunction(name: "checkPatchForEdges") {
                    self.rowPipeline = try dev.makeComputePipelineState(function: rowFunc)
                    self.colPipeline = try dev.makeComputePipelineState(function: colFunc)
                    self.combinePipeline = try dev.makeComputePipelineState(function: combineFunc)
                    self.clearPipeline = try dev.makeComputePipelineState(function: clearFunc)
                    self.checkPatchPipeline = try dev.makeComputePipelineState(function: checkPatchFunc)
                }
            } catch {
                print("⚠️ Failed to compile Metal kernels: \(error)")
            }

            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache
        }
    }

    // MARK: - Metal Compute Kernels (modified for batched dispatch + GPU flags)

    private static let occludingEdgeComputeSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Parameters for patch-based scanning (matches Swift PatchScanParams below)
    struct PatchScanParams {
        uint patchMinX;
        uint patchMaxX;
        uint patchMinY;
        uint patchMaxY;
        uint rowColSkip;
        float thresholdRatio;
        uint patchIndex; // index into hasEdges buffer
        uint pad0;
    };

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

    // Row-scan kernel with patch support and row skip: each thread scans one row
    // Writes to separate output texture to avoid race conditions
    kernel void rowScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> rowMaskTex [[texture(1)]],
        constant PatchScanParams &params [[buffer(0)]],
        uint row [[thread_position_in_grid]]
    ) {
        // row is a relative row index across the dispatched grid; we want to map it to global row
        uint globalRow = params.patchMinY + row;
        if (globalRow >= params.patchMaxY) return;
        if ((globalRow - params.patchMinY) % params.rowColSkip != 0) return;

        int lastX = -1;
        float lastV = 0.0f;

        for (uint x = params.patchMinX; x < params.patchMaxX; ++x) {
            float d = depthTex.read(uint2(x, globalRow)).r;
            if (d > 0.0f) {
                if (lastX >= 0) {
                    float thresh = min(d, lastV) * params.thresholdRatio;
                    if ((lastV - d) > thresh) {
                        rowMaskTex.write(float4(1.0), uint2(x, globalRow));
                    } else if ((d - lastV) > thresh) {
                        rowMaskTex.write(float4(1.0), uint2(lastX, globalRow));
                    }
                }
                lastX = int(x);
                lastV = d;
            }
        }
    }

    // Column-scan kernel with patch support and column skip: each thread scans one column
    kernel void colScan(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> colMaskTex [[texture(1)]],
        constant PatchScanParams &params [[buffer(0)]],
        uint col [[thread_position_in_grid]]
    ) {
        uint globalCol = params.patchMinX + col;
        if (globalCol >= params.patchMaxX) return;
        if ((globalCol - params.patchMinX) % params.rowColSkip != 0) return;

        int lastY = -1;
        float lastV = 0.0f;

        for (uint y = params.patchMinY; y < params.patchMaxY; ++y) {
            float d = depthTex.read(uint2(globalCol, y)).r;
            if (d > 0.0f) {
                if (lastY >= 0) {
                    float thresh = min(d, lastV) * params.thresholdRatio;
                    if ((lastV - d) > thresh) {
                        colMaskTex.write(float4(1.0), uint2(globalCol, y));
                    } else if ((d - lastV) > thresh) {
                        colMaskTex.write(float4(1.0), uint2(globalCol, lastY));
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

        float combinedEdge = max(rowEdge, colEdge);
        outputTex.write(float4(combinedEdge), gid);
    }

    // Check if any edges exist in a rectangular patch region (reads both masks)
    // This kernel is dispatched for each patch with a 2D grid covering the patch region.
    kernel void checkPatchForEdges(
        texture2d<float, access::read> rowMaskTex [[texture(0)]],
        texture2d<float, access::read> colMaskTex [[texture(1)]],
        device atomic_uint *hasEdges [[buffer(0)]],
        constant PatchScanParams &params [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        // gid.x/gid.y are local to the dispatched patch grid
        uint localX = gid.x;
        uint localY = gid.y;

        uint patchWidth = params.patchMaxX - params.patchMinX;
        uint patchHeight = params.patchMaxY - params.patchMinY;

        if (localX >= patchWidth || localY >= patchHeight) return;

        uint x = params.patchMinX + localX;
        uint y = params.patchMinY + localY;

        float r = rowMaskTex.read(uint2(x, y)).r;
        float c = colMaskTex.read(uint2(x, y)).r;

        if (r > 0.0f || c > 0.0f) {
            // set flag for this patch index (stored in params.patchIndex)
            atomic_store_explicit(&hasEdges[params.patchIndex], 1u, memory_order_relaxed);
        }
    }
    """

    // MARK: - Patch Management Helpers

    private func initializePatchFlags(width: Int, height: Int) {
        let currentSize = CGSize(width: width, height: height)
        if previousImageSize != currentSize {
            patchFlags = Array(repeating: Array(repeating: true, count: patchGridHeight), count: patchGridWidth)
            previousImageSize = currentSize
        }
    }

    private func selectRandomPatches() {
        let totalPatches = patchGridWidth * patchGridHeight
        let randSearch = max(0.0, min(1.0, randomSearchRate))
        let numRandomPatches = max(1, Int(round(Double(totalPatches) * Double(randSearch))))
        for _ in 0..<numRandomPatches {
            let x = Int.random(in: 0..<patchGridWidth)
            let y = Int.random(in: 0..<patchGridHeight)
            patchFlags[x][y] = true
        }
    }

    private func getPatchBounds(patchX: Int, patchY: Int, imageWidth: Int, imageHeight: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let patchWidth = imageWidth / patchGridWidth
        let patchHeight = imageHeight / patchGridHeight

        let minX = patchX * patchWidth
        let minY = patchY * patchHeight
        let maxX = min((patchX + 1) * patchWidth, imageWidth)
        let maxY = min((patchY + 1) * patchHeight, imageHeight)

        return (minX, minY, maxX, maxY)
    }

    private func setNeighborFlags(patchX: Int, patchY: Int, in flags: inout [[Bool]]) {
        for dx in -1...1 {
            for dy in -1...1 {
                let nx = patchX + dx
                let ny = patchY + dy
                if nx >= 0 && nx < patchGridWidth && ny >= 0 && ny < patchGridHeight {
                    flags[nx][ny] = true
                }
            }
        }
    }

    // MARK: - Public API: Edge detection entry

    func detectEdges(rgbImage: CIImage?, depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        return detectDepthEdges(from: depthMap)
    }

    // MARK: - Main pipeline

    private func ensureResources(width: Int, height: Int) -> Bool {
        guard let dev = metalDevice else { return false }

        // Recreate pixel buffers + MTLTextures only when size changes
        if width == lastTextureWidth && height == lastTextureHeight, patchFlagBuffer != nil {
            return true
        }

        lastTextureWidth = width
        lastTextureHeight = height

        let options: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true
        ] as CFDictionary

        // Source: One-component float (depth)
        if srcPixelBuffer == nil || CVPixelBufferGetWidth(srcPixelBuffer!) != width || CVPixelBufferGetHeight(srcPixelBuffer!) != height {
            srcPixelBuffer = nil
            srcTexture = nil
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent32Float, options, &pb)
            srcPixelBuffer = pb
            if let cache = textureCache, let srcPB = srcPixelBuffer {
                var ref: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, srcPB, nil, .r32Float, width, height, 0, &ref)
                if let ref = ref { srcTexture = CVMetalTextureGetTexture(ref) }
            }
        }

        // Masks & output use BGRA8Unorm
        func makeOrReuseMask(_ pbRef: inout CVPixelBuffer?, _ texRef: inout MTLTexture?, pixelFormat: MTLPixelFormat) {
            if texRef == nil || texRef!.width != width || texRef!.height != height {
                // create/replace
                pbRef = nil
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options, &pb)
                pbRef = pb
                if let cache = textureCache, let pb = pbRef {
                    var ref: CVMetalTexture?
                    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, pixelFormat, width, height, 0, &ref)
                    if let ref = ref { texRef = CVMetalTextureGetTexture(ref) }
                }
            }
        }

        makeOrReuseMask(&rowMaskPixelBuffer, &rowMaskTexture, pixelFormat: .bgra8Unorm)
        makeOrReuseMask(&colMaskPixelBuffer, &colMaskTexture, pixelFormat: .bgra8Unorm)
        makeOrReuseMask(&outputMaskPixelBuffer, &outputMaskTexture, pixelFormat: .bgra8Unorm)

        // patchFlagBuffer: one uint per patch
        let patchCount = max(1, patchGridWidth * patchGridHeight)
        let flagSize = patchCount * MemoryLayout<UInt32>.stride
        patchFlagBuffer = dev.makeBuffer(length: flagSize, options: .storageModeShared)



        return true
    }

    private func runGPUScan(depthCIImage: CIImage, ratio: Float) -> CIImage? {
        guard let dev = metalDevice,
              let queue = metalCommandQueue,
              let cache = textureCache,
              let rowPipe = rowPipeline,
              let colPipe = colPipeline,
              let combinePipe = combinePipeline,
              let clearPipe = clearPipeline,
              let checkPipe = checkPatchPipeline else {
            return nil
        }

        let width = Int(depthCIImage.extent.width)
        let height = Int(depthCIImage.extent.height)
        initializePatchFlags(width: width, height: height)
        if enablePatchOptimization { selectRandomPatches() }

        guard ensureResources(width: width, height: height) else { return nil }
        guard let srcPB = srcPixelBuffer, let srcTex = srcTexture,
              let rowMaskTex = rowMaskTexture, let colMaskTex = colMaskTexture,
              let outputTex = outputMaskTexture, let patchFlagsBuf = patchFlagBuffer else {
            return nil
        }

        // Render CI depth image into srcTexture
        if let cmdBuf = queue.makeCommandBuffer() {
            ciContext.render(depthCIImage, to: srcTex, commandBuffer: cmdBuf, bounds: depthCIImage.extent, colorSpace: CGColorSpaceCreateDeviceGray())
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted() // unavoidable to have srcTexture content before compute
        }

        // Debug: Sample source depth texture to verify depth data is present
        #if DEBUG
        if let srcT = srcTexture {
            let region = MTLRegion(origin: MTLOrigin(x: width/2, y: height/2, z: 0), size: MTLSize(width: 1, height: 1, depth: 1))
            var depthPixel: Float = 0.0
            srcT.getBytes(&depthPixel, bytesPerRow: 4, from: region, mipmapLevel: 0)
            print("🔍 Source depth at center: \(depthPixel) meters")
        }
        #endif

        // Zero-out patch flags buffer on CPU quickly (we will use GPU to set flags)
        let patchCount = patchGridWidth * patchGridHeight
        let ptrZero = patchFlagsBuf.contents().assumingMemoryBound(to: UInt32.self)
        for i in 0..<patchCount { ptrZero[i] = 0 }

        // Single command buffer for all compute work of this frame
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        // 1) Clear masks using clearKernel (batched)
        encoder.setComputePipelineState(clearPipe)
        // clear row mask
        encoder.setTexture(rowMaskTex, index: 0)
        dispatchFullTexture(encoder: encoder, pipe: clearPipe, width: width, height: height)
        // clear col mask
        encoder.setTexture(colMaskTex, index: 0)
        dispatchFullTexture(encoder: encoder, pipe: clearPipe, width: width, height: height)
        // clear output mask
        encoder.setTexture(outputTex, index: 0)
        dispatchFullTexture(encoder: encoder, pipe: clearPipe, width: width, height: height)

        // NOTE: For the row/col kernels we use 1D dispatchs matching the patch HEIGHT and WIDTH respectively,
        // but we keep using the original kernel semantics (rowScan expects a 1D row index, colScan expects a 1D col index).

        // Pre-prepare some values
        let tRowExecWidth = rowPipe.threadExecutionWidth
        let tColExecWidth = colPipe.threadExecutionWidth

        // 2) For each patch: dispatch row and column scans (no waits)
        encoder.setComputePipelineState(rowPipe)
        for px in 0..<patchGridWidth {
            for py in 0..<patchGridHeight {
                // respect optimization flags
                if enablePatchOptimization && !patchFlags[px][py] { continue }

                // compute bounds
                let bounds = getPatchBounds(patchX: px, patchY: py, imageWidth: width, imageHeight: height)
                let patchMinX = UInt32(bounds.minX)
                let patchMaxX = UInt32(bounds.maxX)
                let patchMinY = UInt32(bounds.minY)
                let patchMaxY = UInt32(bounds.maxY)
                var params = PatchScanParamsStruct(patchMinX: patchMinX,
                                                   patchMaxX: patchMaxX,
                                                   patchMinY: patchMinY,
                                                   patchMaxY: patchMaxY,
                                                   rowColSkip: UInt32(max(1, rowColSkip)),
                                                   thresholdRatio: ratio,
                                                   patchIndex: UInt32(px * patchGridHeight + py),
                                                   pad0: 0)
                // Pass params by value to avoid race condition on shared buffer
                encoder.setBytes(&params, length: MemoryLayout<PatchScanParamsStruct>.size, index: 0)

                encoder.setTexture(srcTex, index: 0)
                encoder.setTexture(rowMaskTex, index: 1)

                // dispatch rows = patchHeight (we supply a 1D grid where "row" parameter is relative row)
                let patchHeight = Int(bounds.maxY - bounds.minY)
                if patchHeight <= 0 { continue }
                let threadsPerGrid = MTLSize(width: patchHeight, height: 1, depth: 1)
                let threadsPerGroup = MTLSize(width: min(tRowExecWidth, patchHeight), height: 1, depth: 1)

                if supportsNonUniformThreadgroups {
                    encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
                } else {
                    let groups = (patchHeight + threadsPerGroup.width - 1) / threadsPerGroup.width
                    encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: threadsPerGroup)
                }
            }
        }

        // Column scans
        encoder.setComputePipelineState(colPipe)
        for px in 0..<patchGridWidth {
            for py in 0..<patchGridHeight {
                if enablePatchOptimization && !patchFlags[px][py] { continue }

                let bounds = getPatchBounds(patchX: px, patchY: py, imageWidth: width, imageHeight: height)
                let patchMinX = UInt32(bounds.minX)
                let patchMaxX = UInt32(bounds.maxX)
                let patchMinY = UInt32(bounds.minY)
                let patchMaxY = UInt32(bounds.maxY)
                var params = PatchScanParamsStruct(patchMinX: patchMinX,
                                                   patchMaxX: patchMaxX,
                                                   patchMinY: patchMinY,
                                                   patchMaxY: patchMaxY,
                                                   rowColSkip: UInt32(max(1, rowColSkip)),
                                                   thresholdRatio: ratio,
                                                   patchIndex: UInt32(px * patchGridHeight + py),
                                                   pad0: 0)
                encoder.setBytes(&params, length: MemoryLayout<PatchScanParamsStruct>.size, index: 0)

                encoder.setTexture(srcTex, index: 0)
                encoder.setTexture(colMaskTex, index: 1)

                let patchWidth = Int(bounds.maxX - bounds.minX)
                if patchWidth <= 0 { continue }
                let threadsPerGrid = MTLSize(width: patchWidth, height: 1, depth: 1)
                let threadsPerGroup = MTLSize(width: min(tColExecWidth, patchWidth), height: 1, depth: 1)

                if supportsNonUniformThreadgroups {
                    encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
                } else {
                    let groups = (patchWidth + threadsPerGroup.width - 1) / threadsPerGroup.width
                    encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: threadsPerGroup)
                }
            }
        }

        // 3) Check patches for any edges: dispatch checkPatchForEdges for each patch (2D dispatch equal to patch size).
        encoder.setComputePipelineState(checkPipe)
        encoder.setBuffer(patchFlagsBuf, offset: 0, index: 0) // atomic uint array
        for px in 0..<patchGridWidth {
            for py in 0..<patchGridHeight {
                if enablePatchOptimization && !patchFlags[px][py] { continue }

                let bounds = getPatchBounds(patchX: px, patchY: py, imageWidth: width, imageHeight: height)
                let patchMinX = UInt32(bounds.minX)
                let patchMaxX = UInt32(bounds.maxX)
                let patchMinY = UInt32(bounds.minY)
                let patchMaxY = UInt32(bounds.maxY)
                var params = PatchScanParamsStruct(patchMinX: patchMinX,
                                                   patchMaxX: patchMaxX,
                                                   patchMinY: patchMinY,
                                                   patchMaxY: patchMaxY,
                                                   rowColSkip: UInt32(max(1, rowColSkip)),
                                                   thresholdRatio: ratio,
                                                   patchIndex: UInt32(px * patchGridHeight + py),
                                                   pad0: 0)
                encoder.setBytes(&params, length: MemoryLayout<PatchScanParamsStruct>.size, index: 1)

                encoder.setTexture(rowMaskTex, index: 0)
                encoder.setTexture(colMaskTex, index: 1)

                let patchWidth = Int(bounds.maxX - bounds.minX)
                let patchHeight = Int(bounds.maxY - bounds.minY)
                if patchWidth <= 0 || patchHeight <= 0 { continue }

                // reasonable threadgroup size, tune as needed
                let tpt = MTLSize(width: 8, height: 8, depth: 1)
                let groupsPatch = MTLSize(width: (patchWidth + tpt.width - 1)/tpt.width,
                                          height: (patchHeight + tpt.height - 1)/tpt.height,
                                          depth: 1)
                encoder.dispatchThreadgroups(groupsPatch, threadsPerThreadgroup: tpt)
            }
        }

        // 4) Combine row and column masks into output mask
        encoder.setComputePipelineState(combinePipe)
        encoder.setTexture(rowMaskTex, index: 0)
        encoder.setTexture(colMaskTex, index: 1)
        encoder.setTexture(outputTex, index: 2)
        dispatchFullTexture(encoder: encoder, pipe: combinePipe, width: width, height: height)

        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back patch flags
        var newPatchFlags = Array(repeating: Array(repeating: false, count: patchGridHeight), count: patchGridWidth)
        let ptr = patchFlagsBuf.contents().assumingMemoryBound(to: UInt32.self)
        for px in 0..<patchGridWidth {
            for py in 0..<patchGridHeight {
                let idx = px * patchGridHeight + py
                if ptr[idx] != 0 {
                    newPatchFlags[px][py] = true
                    if enablePatchOptimization { setNeighborFlags(patchX: px, patchY: py, in: &newPatchFlags) }
                } else {
                    newPatchFlags[px][py] = false
                }
            }
        }


        if enablePatchOptimization { patchFlags = newPatchFlags }

        // Debug: Check if any edges were detected
        #if DEBUG
        let debugPtr = patchFlagsBuf.contents().assumingMemoryBound(to: UInt32.self)
        var totalEdgePatches = 0
        for i in 0..<patchCount {
            if debugPtr[i] != 0 { totalEdgePatches += 1 }
        }
        print("🔍 EdgeDetectorGPU: \(totalEdgePatches)/\(patchCount) patches have edges, size=\(width)x\(height)")

        // Sample a few pixels from output texture to verify data
        if let outTex = outputMaskTexture {
            let region = MTLRegion(origin: MTLOrigin(x: width/2, y: height/2, z: 0), size: MTLSize(width: 1, height: 1, depth: 1))
            var pixel: [UInt8] = [0, 0, 0, 0]
            outTex.getBytes(&pixel, bytesPerRow: 4, from: region, mipmapLevel: 0)
            print("🔍 Center pixel BGRA: \(pixel)")
        }
        #endif

        // Convert BGRA output to single-channel float for pipeline compatibility
        // The output texture is BGRA8, but downstream expects OneComponent32Float
        guard let outPB = outputMaskPixelBuffer else { return nil }
        let ciOutput = CIImage(cvPixelBuffer: outPB)

        // Extract red channel and scale from 0-255 byte range to 0-1 float range
        // BGRA8Unorm already normalizes, but we need to ensure proper channel extraction
        let extractedChannel = ciOutput.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        return extractedChannel
    }

    // Helper to dispatch kernels covering the whole texture
    private func dispatchFullTexture(encoder: MTLComputeCommandEncoder, pipe: MTLComputePipelineState, width: Int, height: Int) {
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let threadExecutionWidth = pipe.threadExecutionWidth
        // 1D threadgroup width is fine for these kernels
        let threadsPerGroup = MTLSize(width: threadExecutionWidth, height: 1, depth: 1)
        if supportsNonUniformThreadgroups {
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        } else {
            let groupsW = (width + threadExecutionWidth - 1) / threadExecutionWidth
            let groupsH = height
            encoder.dispatchThreadgroups(MTLSize(width: groupsW, height: groupsH, depth: 1),
                                         threadsPerThreadgroup: threadsPerGroup)
        }
    }

    // MARK: - Public helpers used by app (keeps earlier API)

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

    func detectDepthEdges(from depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        var ciDepth = CIImage(cvPixelBuffer: depthMap)

        // clamp, downscale, blur (same as original)
        if let clamp = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: ciDepth,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 99, y: 99, z: 99, w: 1)
        ]), let output = clamp.outputImage {
            ciDepth = output
        }

        if downscaleFactor < 1.0,
           let scale = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: ciDepth,
            kCIInputScaleKey: downscaleFactor,
            kCIInputAspectRatioKey: 1.0
        ]), let out = scale.outputImage {
            ciDepth = out
        }

        if preSmoothingRadius > 0.0,
           let blur = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: ciDepth,
            kCIInputRadiusKey: preSmoothingRadius
        ]), let out = blur.outputImage {
            ciDepth = out
        }

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

        // Connect nearby pixels and thicken lines
        if let morphology = CIFilter(name: "CIMorphologyMaximum", parameters: [
            kCIInputImageKey: edgeImage,
            kCIInputRadiusKey: 2.5
        ]), let out = morphology.outputImage {
            edgeImage = out
        }

        // Binarize the image to be strictly 0.0 or 1.0
        // This is done by amplifying the signal massively, then clamping back to the 0-1 range.
        if let binarize = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: edgeImage,
            "inputRVector": CIVector(x: 999, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), // Zero out other channels
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]), let clamp = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: binarize.outputImage,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]), let out = clamp.outputImage {
            edgeImage = out
        }

        return createPixelBuffer(from: edgeImage)
    }

    // MARK: - Structs & small helpers

    // Mirror of the MSL PatchScanParams layout
    private struct PatchScanParamsStruct {
        var patchMinX: UInt32
        var patchMaxX: UInt32
        var patchMinY: UInt32
        var patchMaxY: UInt32
        var rowColSkip: UInt32
        var thresholdRatio: Float
        var patchIndex: UInt32
        var pad0: UInt32
    }
}
