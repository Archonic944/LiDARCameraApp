//
//  EdgeDetectorGPU.swift
//  LiDARCameraApp
//
//  Implements Bose et al. (2017), "Fast RGB-D Edge Detection for SLAM"
//  - Algorithm 1 (P_Scan): Row and column depth discontinuity scanning.
//  - Algorithm 2 (Occluding_Edge_Detection): Patch-based temporal coherence optimization.
//

import Foundation
import CoreVideo
import Metal
import MetalKit

class EdgeDetectorGPU {

    // MARK: - Configuration Parameters
    
    // T in Algorithm 1, controls sensitivity (lower T = more sensitive)
    var sensitivityT: Float = 0.065
    
    // Threshold for Normal-based crease detection (Cosine similarity).
    // 0.85 corresponds to approx 31 degrees difference.
    var sensitivityCreaseT: Float = 0.85
    
    // N patches horizontally (e.g., 32 for 640/32=20 pixel wide patches)
    var gridN: Int = 32
    
    // M patches vertically (e.g., 24 for 480/24=20 pixel high patches)
    var gridM: Int = 24
    
    // K (rowcol_skip) in Algorithm 2. K=1 means no skipping/downscaling.
    var rowColSkipK: Int = 1
    
    // rand_search (Eq 1). Percentage of patches randomly searched each frame.
    var randomSearchRatio: Float = 0.8
    
    // Distance (meters) where edge intensity begins to fade (1.0 at < distance, fading as distance increases)
    var edgeEmphasisDistance: Float = 1.0

    // MARK: - Metal Resources
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    
    private var pipelineRowScan: MTLComputePipelineState?
    private var pipelineColScan: MTLComputePipelineState?
    private var pipelineClear: MTLComputePipelineState?
    
    // Helper to render textures to CVPixelBuffers
    private lazy var ciContext: CIContext = {
        return CIContext(mtlDevice: self.device)
    }()

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
        float thresholdT;   // T parameter for Occlusion
        float creaseT;      // Cosine Threshold for Creases (e.g. 0.85 for ~30 deg)
        float emphasisDist; // Distance where edges start to fade
    };

    // Helper: 3x3 Box Filter for robust depth
    // Reduces "sparkle" noise from LiDAR before calculating derivatives
    float get_smoothed_depth(texture2d<float, access::read> depthTex, uint2 c) {
        float sum = 0.0;
        float validWeight = 0.0;
        
        // Simple cross kernel (5-tap) is faster and usually sufficient
        int2 offsets[5] = {int2(0,0), int2(1,0), int2(-1,0), int2(0,1), int2(0,-1)};
        
        for (int i = 0; i < 5; i++) {
             uint2 samplePos = uint2(int2(c) + offsets[i]);
             float d = depthTex.read(samplePos).r;
             if (d > 0.001) {
                 sum += d;
                 validWeight += 1.0;
             }
        }
        
        return (validWeight > 0.0) ? (sum / validWeight) : 0.0;
    }

    // Helper: Compute surface normal with depth-dependent scale approximation
    float3 get_normal(texture2d<float, access::read> depthTex, uint2 c, uint width, uint height) {
        float dC = get_smoothed_depth(depthTex, c);
        
        if (dC < 0.001) return float3(0, 0, 1);
        
        // Neighbors
        uint2 cR = c + uint2(1, 0);
        uint2 cU = c + uint2(0, 1);
        
        if (cR.x >= width || cU.y >= height) return float3(0, 0, 1);
        
        float dR = get_smoothed_depth(depthTex, cR);
        float dU = get_smoothed_depth(depthTex, cU);
        
        if (dR < 0.001 || dU < 0.001) return float3(0, 0, 1);

        // Estimate pixel size in meters at this depth.
        // Approx: 640px width, ~60deg FOV -> ~1m width at 1m depth.
        // So 1 pixel ~ 1/640 meters ~= 0.0015 meters * depth.
        float pixelMetricSize = dC * 0.0015;
        
        // Derivatives
        float dz_dx = dR - dC;
        float dz_dy = dU - dC;
        
        // Tangent vectors: 
        // vX = (pixelSize, 0, dz_dx)
        // vY = (0, pixelSize, dz_dy)
        float3 vX = float3(pixelMetricSize, 0.0, dz_dx);
        float3 vY = float3(0.0, pixelMetricSize, dz_dy);
        
        // Normal = normalize(cross(vX, vY))
        return normalize(cross(vX, vY));
    }

    // MARK: - Algorithm 1: P_Scan Core Logic
    void p_scan_line(
        texture2d<float, access::read> depthTex,
        texture2d<float, access::write> edgeTex,
        device atomic_uint* patchCounts, 
        constant uint8_t* patchFlags,   
        constant EdgeGenParams& params,
        uint lineIndex,                  
        bool isRowScan                   
    ) {
        uint length = isRowScan ? params.imgWidth : params.imgHeight;
        
        // State variables
        float v_last_valid = 0.0;
        int last_valid_idx = -1;
        float3 n_last_valid = float3(0,0,1);
        
        uint step = params.rowColSkip;
        
        for (uint n = 0; n < length; n += step) {
            
            uint2 coords = isRowScan ? uint2(n, lineIndex) : uint2(lineIndex, n);
            
            // Patch management
            uint patchW = params.imgWidth / params.patchGridX;
            uint patchH = params.imgHeight / params.patchGridY;
            uint pX = min(coords.x / patchW, params.patchGridX - 1);
            uint pY = min(coords.y / patchH, params.patchGridY - 1);
            uint patchIdx = pY * params.patchGridX + pX;
            
            if (patchFlags[patchIdx] == 0) {
                last_valid_idx = -1; 
                continue; 
            }

            // Read Smoothed Depth for stability
            float v_n = get_smoothed_depth(depthTex, coords);
            
            if (v_n > 0.001) {
                
                bool edgeFound = false;
                float intensity = 0.0;
                
                // Calculate Normal for current pixel
                float3 n_curr = get_normal(depthTex, coords, params.imgWidth, params.imgHeight);
                
                if (last_valid_idx != -1) {
                    
                    // --- 1. Occlusion (Jump) ---
                    float threshold = min(v_n, v_last_valid) * params.thresholdT;
                    float diff = v_last_valid - v_n;
                    
                    if (abs(diff) > threshold) {
                        // Found Jump Edge
                        float closeDepth = (diff > 0) ? v_n : v_last_valid;
                        intensity = clamp(params.emphasisDist / closeDepth, 0.0, 1.0);
                        
                        uint2 writeCoords = (diff > 0) ? coords : 
                            (isRowScan ? uint2(uint(last_valid_idx), lineIndex) : uint2(lineIndex, uint(last_valid_idx)));
                            
                        edgeTex.write(float4(intensity, intensity, intensity, 1), writeCoords);
                        atomic_fetch_add_explicit(&patchCounts[patchIdx], 1, memory_order_relaxed);
                        edgeFound = true;
                    } 
                    
                    // --- 2. Crease (Normal Angle) ---
                    else if (params.creaseT < 0.999) {
                        // Check dot product between current normal and last valid normal
                        // This effectively checks curvature between the last sample and this one.
                        
                        float dotP = dot(n_curr, n_last_valid);
                        
                        // If angle is large (dotP small), it's a crease
                        if (dotP < params.creaseT) {
                             intensity = clamp(params.emphasisDist / v_n, 0.0, 1.0);
                             
                             // Scale intensity by how "sharp" the crease is? 
                             // Optional: make it pop more
                             intensity = max(intensity, 0.5); 
                             
                             edgeTex.write(float4(intensity, intensity, intensity, 1), coords);
                             atomic_fetch_add_explicit(&patchCounts[patchIdx], 1, memory_order_relaxed);
                        }
                    }
                }
                
                // Update History
                v_last_valid = v_n;
                n_last_valid = n_curr;
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
            thresholdT: sensitivityT,
            creaseT: sensitivityCreaseT,
            emphasisDist: edgeEmphasisDistance
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
        
        // Convert the GPU texture to a CVPixelBuffer for the visualizer
        return convertTextureToPixelBuffer(texture: outputTexture)
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
        var creaseT: Float
        var emphasisDist: Float
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
    
    // Creates the output edge mask texture using R32Float for compatibility with DepthVisualizer
    private func createOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }
    
    // Converts the final Metal texture into a CVPixelBuffer using CIContext
    private func convertTextureToPixelBuffer(texture: MTLTexture) -> CVPixelBuffer? {
        // Create a CIImage from the MTLTexture
        // .r32Float texture creates a single-channel CIImage
        guard let ciImage = CIImage(mtlTexture: texture, options: nil)?.oriented(.up) else {
            return nil
        }
        
        let width = texture.width
        let height = texture.height
        
        var pixelBuffer: CVPixelBuffer?
        
        // We MUST use OneComponent32Float so DepthVisualizer sees luminance=1.0
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent32Float, // Matches depth data format
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        // Render the CIImage into the CVPixelBuffer
        ciContext.render(ciImage, to: buffer)
        
        return buffer
    }
}
