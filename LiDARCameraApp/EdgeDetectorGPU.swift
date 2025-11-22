//
// EdgeDetectorGPU.swift
//
// Implements Bose et al. (2017), "Fast RGB-D Edge Detection for SLAM"
// - Algorithm 1 (P_Scan): Row and column depth discontinuity scanning.
// - Algorithm 2 (Occluding_Edge_Detection): Patch-based temporal coherence optimization.
//
// NOTE: For simplicity and portability, the Metal shader source is included directly
// as a string constant within the Swift file.
//

import Foundation
import CoreVideo
import Metal
import MetalKit

class EdgeDetectorGPU {

    // MARK: - Configuration Parameters
    
    // T in Algorithm 1, controls sensitivity (lower T = more sensitive)
    var sensitivityT: Float = 0.05
    
    // N patches horizontally (e.g., 32 for 640/32=20 pixel wide patches)
    var gridN: Int = 32
    
    // M patches vertically (e.g., 24 for 480/24=20 pixel high patches)
    var gridM: Int = 24
    
    // K (rowcol_skip) in Algorithm 2. K=1 means no skipping/downscaling.
    var rowColSkipK: Int = 1
    
    // rand_search (Eq 1). Percentage of patches randomly searched each frame.
    var randomSearchRatio: Float = 0.05

    // MARK: - Metal Resources
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    
    private var pipelineRowScan: MTLComputePipelineState?
    private var pipelineColScan: MTLComputePipelineState?
    private var pipelineClear: MTLComputePipelineState?

    // MARK: - Algorithm State
    
    // F: The N x M array of boolean flags. 1 = True (search this patch next frame), 0 = False.
    private var patchFlags: [UInt8] = []
    
    // Buffers
    private var patchFlagsBuffer: MTLBuffer?
    private var patchCountsBuffer: MTLBuffer?
    
    private var previousSize: CGSize = .zero
    
    // MARK: - Metal Shader Source (Algorithm 1)

    private static let occludingEdgeComputeSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EdgeGenParams {
        uint imgWidth;
        uint imgHeight;
        uint patchGridX;    // N patches horizontally
        uint patchGridY;    // M patches vertically
        uint rowColSkip;    // K parameter
        float thresholdT;   // T parameter
    };

    // MARK: - Algorithm 1: P_Scan Core Logic
    // Each GPU thread processes one entire Row or Column to maintain the serial nature 
    // of the "last_valid" tracking required by Algorithm 1.
    void p_scan_line(
        texture2d<float, access::read> depthTex,
        texture2d<float, access::write> edgeTex,
        device atomic_uint* patchCounts, // To track where edges are found (for Alg 2)
        constant uint8_t* patchFlags,    // F: boolean flags from previous frame
        constant EdgeGenParams& params,
        uint lineIndex,                  // The row (Y) or column (X) index
        bool isRowScan                   // True = Scanning X, False = Scanning Y
    ) {
        uint length = isRowScan ? params.imgWidth : params.imgHeight;
        
        // State variables from Source [53]
        float v_last_valid = 0.0;
        int last_valid_idx = -1;
        
        // Step K (rowColSkip)
        uint step = params.rowColSkip;
        
        // Iterate n = 0 to N, stepping by K [Source 92]
        for (uint n = 0; n < length; n += step) {
            
            // Determine coordinates
            uint2 coords = isRowScan ? uint2(n, lineIndex) : uint2(lineIndex, n);
            
            // Determine current patch index
            uint patchW = params.imgWidth / params.patchGridX;
            uint patchH = params.imgHeight / params.patchGridY;
            
            uint pX = coords.x / patchW;
            uint pY = coords.y / patchH;
            
            // Bounds safety
            if (pX >= params.patchGridX) pX = params.patchGridX - 1;
            if (pY >= params.patchGridY) pY = params.patchGridY - 1;
            
            uint patchIdx = pY * params.patchGridX + pX;
            
            // ALGORITHM 2 Optimization:
            // Skip scanning logic if the patch flag is false (0) [Source 73]
            if (patchFlags[patchIdx] == 0) {
                // If this patch is not flagged, we reset valid history to prevent "teleporting" edges.
                last_valid_idx = -1; 
                continue; 
            }

            // Fetch Vn
            float v_n = depthTex.read(coords).r;
            
            if (v_n > 0.001) { // if Vn != 0 (valid pixel)
                
                if (last_valid_idx != -1) {
                    // threshold = Min(Vn, Vlast_valid) * T [Source 53]
                    float threshold = min(v_n, v_last_valid) * params.thresholdT;
                    
                    float diff = v_last_valid - v_n;
                    
                    // Logic from Source [54] and [64]: Edge is the pixel with smaller depth value (closer).
                    if (diff > threshold) {
                        // V_last_valid > V_n. V_n is smaller (closer), so V_n is the edge.
                        edgeTex.write(float4(1.0, 0, 0, 1), coords);
                        atomic_fetch_add_explicit(&patchCounts[patchIdx], 1, memory_order_relaxed);
                    } else if (-diff > threshold) {
                        // V_n > V_last_valid. V_last_valid is smaller (closer), so V_last_valid is the edge.
                        uint2 lastCoords = isRowScan ? uint2(uint(last_valid_idx), lineIndex) : uint2(lineIndex, uint(last_valid_idx));
                        edgeTex.write(float4(1.0, 0, 0, 1), lastCoords);
                        
                        // We must update the patch counter for where the LAST pixel was located.
                        uint lastPX = lastCoords.x / patchW;
                        uint lastPY = lastCoords.y / patchH;
                        if (lastPX < params.patchGridX && lastPY < params.patchGridY) {
                             uint lastPatchIdx = lastPY * params.patchGridX + lastPX;
                             atomic_fetch_add_explicit(&patchCounts[lastPatchIdx], 1, memory_order_relaxed);
                        }
                    }
                }
                
                // Update last valid pixel state
                v_last_valid = v_n;
                last_valid_idx = int(n);
            }
        }
    }

    // Kernel: Scan Rows
    kernel void p_scan_rows_kernel(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> edgeTex [[texture(1)]],
        device atomic_uint* patchCounts [[buffer(0)]],
        constant uint8_t* patchFlags [[buffer(1)]],
        constant EdgeGenParams& params [[buffer(2)]],
        uint gid [[thread_position_in_grid]] // gid = row index (Y)
    ) {
        if (gid >= params.imgHeight) return;
        
        // Skip check for row/column skip (K parameter) [Source 92]
        if (gid % params.rowColSkip != 0) return;

        p_scan_line(depthTex, edgeTex, patchCounts, patchFlags, params, gid, true);
    }

    // Kernel: Scan Columns
    kernel void p_scan_cols_kernel(
        texture2d<float, access::read> depthTex [[texture(0)]],
        texture2d<float, access::write> edgeTex [[texture(1)]],
        device atomic_uint* patchCounts [[buffer(0)]],
        constant uint8_t* patchFlags [[buffer(1)]],
        constant EdgeGenParams& params [[buffer(2)]],
        uint gid [[thread_position_in_grid]] // gid = column index (X)
    ) {
        if (gid >= params.imgWidth) return;

        // Skip check for row/column skip (K parameter) [Source 92]
        if (gid % params.rowColSkip != 0) return;

        p_scan_line(depthTex, edgeTex, patchCounts, patchFlags, params, gid, false);
    }

    // Utility to clear texture
    kernel void clear_tex_kernel(texture2d<float, access::write> tex [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
        tex.write(float4(0), gid);
    }
    """
    
    // MARK: - Initialization

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.commandQueue = queue
        
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        do {
            // Compile Metal library from source string
            let library = try device.makeLibrary(source: EdgeDetectorGPU.occludingEdgeComputeSource, options: nil)
            
            guard let rowFunc = library.makeFunction(name: "p_scan_rows_kernel"),
                  let colFunc = library.makeFunction(name: "p_scan_cols_kernel"),
                  let clearFunc = library.makeFunction(name: "clear_tex_kernel") else {
                print("Failed to find shader functions")
                return nil
            }
            
            pipelineRowScan = try device.makeComputePipelineState(function: rowFunc)
            pipelineColScan = try device.makeComputePipelineState(function: colFunc)
            pipelineClear = try device.makeComputePipelineState(function: clearFunc)
            
        } catch {
            print("Shader compilation error: \(error)")
            return nil
        }
    }

    // MARK: - Public API (Algorithm 2 Control)
    
    func processFrame(depthPixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)
        
        // 1. Initialize State if size changed
        if width != Int(previousSize.width) || height != Int(previousSize.height) {
            initializeGrid(width: width, height: height)
        }
        
        // 2. Prepare Resources
        // This requires an MTLTexture with R32Float format for the depth image
        guard let inputTexture = createTexture(from: depthPixelBuffer, pixelFormat: .r32Float, planeIndex: 0),
              let outputTexture = createOutputTexture(width: width, height: height),
              let flagsBuf = patchFlagsBuffer,
              let countsBuf = patchCountsBuffer else {
            return nil
        }
        
        // 3. Algorithm 2: Update Flags for the CURRENT frame based on temporal coherence [Source 71, 72]
        updatePatchFlagsForCurrentFrame()
        
        // Send the updated flags array to the GPU buffer
        flagsBuf.contents().copyMemory(from: patchFlags, byteCount: patchFlags.count)
        
        // Clear counts buffer (necessary because they are GPU atomic counters)
        memset(countsBuf.contents(), 0, countsBuf.length)

        // 4. Encode GPU Commands
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        
        // Step A: Clear Output Texture
        if let clearPipe = pipelineClear {
            encoder.setComputePipelineState(clearPipe)
            encoder.setTexture(outputTexture, index: 0)
            let w = pipelineClear!.threadExecutionWidth
            let h = pipelineClear!.maxTotalThreadsPerThreadgroup / w
            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        }
        
        // Params struct
        var params = EdgeGenParams(
            imgWidth: UInt32(width),
            imgHeight: UInt32(height),
            patchGridX: UInt32(gridN),
            patchGridY: UInt32(gridM),
            rowColSkip: UInt32(rowColSkipK),
            thresholdT: sensitivityT
        )
        
        // Step B: Run P_Scan (Row Iteration)
        if let rowPipe = pipelineRowScan {
            encoder.setComputePipelineState(rowPipe)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBuffer(countsBuf, offset: 0, index: 0)
            encoder.setBuffer(flagsBuf, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<EdgeGenParams>.size, index: 2)
            
            // Dispatch 1 Thread per ROW
            let threadsPerGrid = MTLSize(width: height, height: 1, depth: 1)
            let threadsPerGroup = MTLSize(width: min(height, rowPipe.threadExecutionWidth), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        }
        
        // Step C: Run P_Scan (Col Iteration)
        if let colPipe = pipelineColScan {
            encoder.setComputePipelineState(colPipe)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBuffer(countsBuf, offset: 0, index: 0)
            encoder.setBuffer(flagsBuf, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<EdgeGenParams>.size, index: 2)
            
            // Dispatch 1 Thread per COL
            let threadsPerGrid = MTLSize(width: width, height: 1, depth: 1)
            let threadsPerGroup = MTLSize(width: min(width, colPipe.threadExecutionWidth), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        }
        
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Wait for results to update CPU state for next frame
        
        // 5. Algorithm 2: Read back counts and update flags for the NEXT frame
        updateNextFrameFlags(from: countsBuf)
        
        // In a real application, you would convert the outputTexture (BGRA8Unorm)
        // back to a CVPixelBuffer or CIImage for display/further processing.
        return nil // Placeholder, replace with texture-to-CVPixelBuffer logic
    }
    
    // MARK: - Algorithm 2 Logic Helpers
    
    private func initializeGrid(width: Int, height: Int) {
        previousSize = CGSize(width: width, height: height)
        let totalPatches = gridN * gridM
        
        // Initialize flags to 'true' (1) to search the whole image on the first frame
        patchFlags = [UInt8](repeating: 1, count: totalPatches)
        
        // Allocate buffers (GPU memory)
        patchFlagsBuffer = device.makeBuffer(length: totalPatches * MemoryLayout<UInt8>.stride, options: .storageModeShared)
        patchCountsBuffer = device.makeBuffer(length: totalPatches * MemoryLayout<UInt32>.stride, options: .storageModeShared)
    }
    
    private func updatePatchFlagsForCurrentFrame() {
        // Step 1: Set R randomly selected flags from F to True [Source 82]
        
        let totalPatches = gridN * gridM
        let R = Int(round(Float(totalPatches) * randomSearchRatio))
        
        for _ in 0..<max(1, R) {
            let randIdx = Int.random(in: 0..<totalPatches)
            patchFlags[randIdx] = 1 // Randomly select and set to True
        }
    }
    
    private func updateNextFrameFlags(from countsBuf: MTLBuffer) {
        let rawCounts = countsBuf.contents().assumingMemoryBound(to: UInt32.self)
        let totalPatches = gridN * gridM
        
        var newFlags = [UInt8](repeating: 0, count: totalPatches)
        
        for i in 0..<totalPatches {
            if rawCounts[i] > 0 {
                // If edges were detected: set self flag and set neighbor flags [Source 79]
                newFlags[i] = 1
                setNeighbors(index: i, in: &newFlags)
            } else {
                // If no edges were detected: reset patch flag to false [Source 78]
                newFlags[i] = 0
            }
        }
        
        // This is the new state (F) for the next call to processFrame
        self.patchFlags = newFlags
    }
    
    private func setNeighbors(index: Int, in flags: inout [UInt8]) {
        // Map 1D index to 2D
        let x = index % gridN
        let y = index / gridN
        
        // Set 8 neighbors to True (1)
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx
                let ny = y + dy
                
                if nx >= 0 && nx < gridN && ny >= 0 && ny < gridM {
                    let nIndex = ny * gridN + nx
                    flags[nIndex] = 1
                }
            }
        }
    }
    
    // MARK: - Metal Helper Structs and Functions
    
    private struct EdgeGenParams {
        var imgWidth: UInt32
        var imgHeight: UInt32
        var patchGridX: UInt32
        var patchGridY: UInt32
        var rowColSkip: UInt32
        var thresholdT: Float
    }
    
    // Creates an MTLTexture for the depth map (R32Float) from a CVPixelBuffer
    private func createTexture(from buffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> MTLTexture? {
        var textureRef: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            buffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &textureRef
        )
        
        if let textureRef = textureRef {
            return CVMetalTextureGetTexture(textureRef)
        }
        return nil
    }
    
    // Creates the output edge mask texture (BGRA8Unorm for visual output)
    private func createOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }
    
    // Placeholder function: In a working app, this converts the GPU output back to
    // a format usable by UIKit/AppKit (e.g., CVPixelBuffer).
    private func convertTextureToPixelBuffer(texture: MTLTexture) -> CVPixelBuffer? {
        // Implementation omitted for brevity. You would typically use a blit encoder
        // or Core Image to copy/convert the MTLTexture data to a CVPixelBuffer.
        return nil
    }
}
