//
//  DepthProcessor.swift
//  LiDARCameraApp
//
//  Handles depth data processing and normalization
//

import Foundation
import AVFoundation
import CoreImage

/// Extends CVPixelBuffer with depth conversion utilities
extension CVPixelBuffer {
    /// Converts meter values to normalized proximity (0-1) where 0=far, 1=close
    /// Creates a NEW pixel buffer, preserves original meter values
    /// - Parameters:
    ///   - minDepth: Minimum depth value (meters) - closest distance
    ///   - maxDepth: Maximum depth value (meters) - farthest distance
    /// - Returns: New CVPixelBuffer with proximity values (0-1)
    func convertMetersToProximity(minDepth: Float, maxDepth: Float) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        // Create new pixel buffer for output
        var newPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &newPixelBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = newPixelBuffer else {
            return nil
        }

        // Lock both buffers
        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))

        defer {
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))
        }

        guard let inputBuffer = CVPixelBufferGetBaseAddress(self),
              let outputBaseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            return nil
        }

        let inputPixels = inputBuffer.assumingMemoryBound(to: Float.self)
        let outputPixels = outputBaseAddress.assumingMemoryBound(to: Float.self)
        let count = width * height

        let range = maxDepth - minDepth
        guard range > 0 else {
            return nil
        }

        // Convert meters to proximity: 0=far, 1=close
        for i in 0..<count {
            let metersValue = inputPixels[i]
            if metersValue.isFinite {
                let normalized = (metersValue - minDepth) / range
                let clamped = max(0.0, min(1.0, normalized))
                outputPixels[i] = 1.0 - clamped  // Invert: close objects = high proximity
            } else {
                outputPixels[i] = 0.0
            }
        }

        return outputBuffer
    }
}

/// Processes depth data from AVCaptureDepthDataOutput
class DepthProcessor {

    // MARK: - Properties

    /// Default minimum depth value in meters (closest distance)
    public static var defaultMinDepth: Float = DepthLevels.medium.min

    /// Default maximum depth value in meters (farthest distance)
    public static var defaultMaxDepth: Float = DepthLevels.medium.max

    /// Aperture size; the radius of the region sampled (0-1)
    public static var APERTURE_SIZE = 0.15

    /// Minimum depth value in meters (closest distance in range)
    var minDisparity: Float = DepthProcessor.defaultMinDepth

    /// Maximum depth value in meters (farthest distance in range)
    var maxDisparity: Float = DepthProcessor.defaultMaxDepth

    /// Reusable Core Image context for orientation operations
    private let ciContext = CIContext()

    // MARK: - Public Methods

    /// Converts depth data to meters format and orients it to match screen orientation
    /// - Parameters:
    ///   - depthData: Raw depth data from camera
    ///   - orientation: Current device/video orientation
    /// - Returns: Oriented depth map in meters as CVPixelBuffer (Float32)
    func processDepthData(_ depthData: AVDepthData, orientation: AVCaptureVideoOrientation) -> CVPixelBuffer {
        // Convert to 32-bit floating-point depth format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap

        // Orient the depth map to match screen coordinates
        // depthMap[row][col] corresponds to screen position (col, row)
        return orientDepthMap(depthMap, videoOrientation: orientation)
    }

    /// Gets unoriented depth map for edge detection (in native camera orientation)
    /// - Parameter depthData: Raw depth data from camera
    /// - Returns: Unoriented depth map in meters as CVPixelBuffer (Float32)
    func getUnorientedDepthMap(_ depthData: AVDepthData) -> CVPixelBuffer {
        // Convert to 32-bit floating-point depth format but don't orient
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        return convertedDepth.depthDataMap
    }

    /// Orients an edge map to match screen orientation
    /// - Parameters:
    ///   - edgeMap: Unoriented edge map from EdgeDetectorGPU
    ///   - orientation: Current device/video orientation
    /// - Returns: Oriented edge map
    func orientEdgeMap(_ edgeMap: CVPixelBuffer, orientation: AVCaptureVideoOrientation) -> CVPixelBuffer {
        return orientDepthMap(edgeMap, videoOrientation: orientation, mirrorX: false, mirrorY: true);
    }

    /// Calibrates the depth range to fit the current frame using statistical analysis
    /// - Parameter depthData: Raw depth data from camera
    /// - Note: Uses 5th and 95th percentiles to eliminate outliers
    func calibrateToCurrentFrame(from depthData: AVDepthData) {
        // Convert to 32-bit floating-point METERS format
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap

        guard let (p5, p95) = calculatePercentiles(from: depthMap) else {
            print("⚠️ Could not calculate frame statistics")
            return
        }

        // Set range based on percentiles (auto-fit to scene)
        minDisparity = p5
        maxDisparity = p95

        print("🎯 Calibrated to scene: P5=\(String(format: "%.2f", p5))m, P95=\(String(format: "%.2f", p95))m (range: \(String(format: "%.2f", p95 - p5))m)")
    }

    /// Resets the depth range to default values
    func resetToDefaultRange() {
        minDisparity = DepthProcessor.defaultMinDepth
        maxDisparity = DepthProcessor.defaultMaxDepth
        print("🔄 Reset to defaults: min=\(String(format: "%.2f", DepthProcessor.defaultMinDepth))m, max=\(String(format: "%.2f", DepthProcessor.defaultMaxDepth))m")
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

    /// Samples maximum value from a center aperture region
    /// - Parameters:
    ///   - buffer: Pixel buffer (Float32)
    ///   - apertureSize: Size of the center region to sample (0.0 to 1.0, as fraction of image)
    /// - Returns: Maximum value in the aperture
    func sampleCenterMax(from buffer: CVPixelBuffer, apertureSize: CGFloat = APERTURE_SIZE) -> Float {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
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

        // Sample max value in aperture
        var maxVal: Float = 0.0

        for y in startY..<endY {
            for x in startX..<endX {
                let index = y * width + x
                let value = floatBuffer[index]
                if value.isFinite && value > maxVal {
                    maxVal = value
                }
            }
        }

        return maxVal
    }

    /// Samples average depth from a center aperture region
    /// - Parameters:
    ///   - depthMap: Depth pixel buffer in METERS
    ///   - apertureSize: Size of the center region to sample (0.0 to 1.0, as fraction of image)
    /// - Returns: Average depth in METERS
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

    // Debug counter
    private static var logCounter = 0

    /// Checks if any pixel in the depth map is closer than the specified distance
    /// - Parameters:
    ///   - depthMap: Depth pixel buffer in METERS
    ///   - minDistance: Minimum distance threshold in meters
    /// - Returns: True if any pixel is closer than minDistance
    func checkForMinDistance(in depthMap: CVPixelBuffer, minDistance: Float) -> Bool {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return false
        }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
        let count = width * height
        
        DepthProcessor.logCounter += 1
        let shouldLog = DepthProcessor.logCounter % 30 == 0
        
        if shouldLog {
            // Debug mode: Scan whole buffer to find true min
            var minVal: Float = Float.greatestFiniteMagnitude
            var found = false
            
            for i in 0..<count {
                let value = floatBuffer[i]
                if value.isFinite && value > 0 {
                    if value < minVal { minVal = value }
                    if value < minDistance { found = true }
                }
            }
            
            print("🔍 Min valid depth in frame: \(String(format: "%.3f", minVal))m (Threshold: \(minDistance)m)")
            return found
        } else {
            // Fast mode: Early exit
            for i in 0..<count {
                let value = floatBuffer[i]
                if value.isFinite && value > 0 && value < minDistance {
                    return true
                }
            }
        }

        return false
    }

    /// Converts a single meter value to proximity (0-1) where 0=far, 1=close
    func metersToProximity(_ meters: Float) -> Float {
        let range = maxDisparity - minDisparity
        guard range > 0 else { return 0.0 }

        let normalized = (meters - minDisparity) / range
        let clamped = max(0.0, min(1.0, normalized))
        return 1.0 - clamped  // Invert: close = high proximity
    }

    // MARK: - Private Methods

    /// Orients depth map to match screen coordinates
    /// All downstream processing uses correctly oriented data
    private func orientDepthMap(_ depthMap: CVPixelBuffer, videoOrientation: AVCaptureVideoOrientation, mirrorX: Bool = false, mirrorY: Bool = false) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: depthMap)

        // Map video orientation to CGImagePropertyOrientation
        let orientation: CGImagePropertyOrientation
        switch videoOrientation {
        case .portrait:
            orientation = .up
        case .portraitUpsideDown:
            orientation = .down
        case .landscapeRight:
            orientation = .right
        case .landscapeLeft:
            orientation = .left
        @unknown default:
            orientation = .up
        }

        // Apply orientation and normalize to origin
        var orientedImage = ciImage.oriented(orientation)
        let orientedExtent = orientedImage.extent
        let a = mirrorX ? -1.0 : 1.0
        let d = mirrorY ? -1.0 : 1.0

        let tx = mirrorX
            ? orientedExtent.origin.x + orientedExtent.width
            : -orientedExtent.origin.x

        let ty = mirrorY
            ? orientedExtent.origin.y + orientedExtent.height
            : -orientedExtent.origin.y

        let transform = CGAffineTransform(
            a: a,
            b: 0,
            c: 0,
            d: d,
            tx: tx,
            ty: ty
        )
        orientedImage = orientedImage.transformed(by:transform)

        // Render back to CVPixelBuffer
        let width = Int(orientedImage.extent.width)
        let height = Int(orientedImage.extent.height)

        var orientedBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &orientedBuffer
        )

        guard let outputBuffer = orientedBuffer else {
            return depthMap  // Fallback to unoriented if creation fails
        }

        ciContext.render(orientedImage, to: outputBuffer)
        return outputBuffer
    }
}
