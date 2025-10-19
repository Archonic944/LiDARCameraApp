//
//  EdgeDetector.swift
//  LiDARCameraApp
//
//  Edge detection based on Xia & Wang (2017):
//  "A Fast Edge Extraction Method for Mobile Lidar Point Clouds"
//

import Foundation
import CoreVideo
import Accelerate

/// Detects edges in depth maps using geometric analysis
/// Based on Xia2017 paper: gradient-based edge detection with eigenvalue analysis
class EdgeDetector {

    // MARK: - Properties

    /// Neighborhood radius in pixels (adapted from 0.15m in paper)
    private let neighborhoodRadius: Int = 5

    /// Minimum number of neighbors to consider (M in paper, default 30)
    private let minNeighbors: Int = 15  // Reduced for smaller depth map resolution

    /// Threshold for eigenvalue ratio (T in paper, default 100)
    private let edgeThreshold: Float = 80.0

    /// Gaussian smoothing standard deviation
    private let gaussianSigma: Float = 1.0

    // MARK: - Main Method

    /// Detects edges in a depth map and returns an edge strength map
    /// - Parameter depthMap: Normalized depth pixel buffer (0-1 range)
    /// - Returns: Edge strength map as CVPixelBuffer, or nil if detection fails
    func detectEdges(from depthMap: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let depthData = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let floatDepth = depthData.assumingMemoryBound(to: Float.self)

        // Step 1: Calculate edge indices for all points
        var edgeIndices = [Float](repeating: 0.0, count: width * height)
        calculateAllEdgeIndices(floatDepth: floatDepth, width: width, height: height, output: &edgeIndices)

        // Step 2: Calculate gradients for all points
        var gradients = [(Float, Float, Float)](repeating: (0, 0, 0), count: width * height)
        calculateAllGradients(floatDepth: floatDepth, edgeIndices: edgeIndices, width: width, height: height, output: &gradients)

        // Step 3: Apply Gaussian smoothing to gradients
        var smoothedGradients = gradients
        applyGaussianSmoothing(to: &smoothedGradients, width: width, height: height)

        // Step 4: Calculate eigenvalue ratios to detect edges
        var edgeStrengths = [Float](repeating: 0.0, count: width * height)
        detectEdgeCandidates(gradients: smoothedGradients, width: width, height: height, output: &edgeStrengths)

        // Step 5: Non-maximum suppression
        var suppressedEdges = edgeStrengths
        nonMaximumSuppression(edgeMap: &suppressedEdges, gradients: smoothedGradients, width: width, height: height)

        // Create output buffer
        return createEdgeBuffer(from: suppressedEdges, width: width, height: height)
    }

    // MARK: - Edge Index Calculation (Equation 2)

    /// Calculate edge indices for all pixels
    private func calculateAllEdgeIndices(floatDepth: UnsafePointer<Float>, width: Int, height: Int, output: inout [Float]) {
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                output[idx] = calculateEdgeIndex(x: x, y: y, floatDepth: floatDepth, width: width, height: height)
            }
        }
    }

    /// Calculate edge index Ic for a point (Equation 2 from paper)
    /// Ic = (1/R) * ||Pc - (1/n)Σ Pi||
    private func calculateEdgeIndex(x: Int, y: Int, floatDepth: UnsafePointer<Float>, width: Int, height: Int) -> Float {
        let idx = y * width + x
        let centerDepth = floatDepth[idx]

        // Skip invalid depths
        guard centerDepth.isFinite && centerDepth > 0 else {
            return 0.0
        }

        // Get neighborhood
        var neighbors: [(x: Int, y: Int, depth: Float)] = []
        let r = neighborhoodRadius

        for dy in -r...r {
            for dx in -r...r {
                let nx = x + dx
                let ny = y + dy

                // Skip out of bounds and center point
                guard nx >= 0 && nx < width && ny >= 0 && ny < height && !(dx == 0 && dy == 0) else {
                    continue
                }

                let nIdx = ny * width + nx
                let nDepth = floatDepth[nIdx]

                if nDepth.isFinite && nDepth > 0 {
                    neighbors.append((nx, ny, nDepth))
                }
            }
        }

        // Need minimum number of neighbors
        guard neighbors.count >= minNeighbors else {
            return 0.0
        }

        // Calculate geometric centroid in 3D
        var centroidX: Float = 0.0
        var centroidY: Float = 0.0
        var centroidZ: Float = 0.0

        for neighbor in neighbors {
            centroidX += Float(neighbor.x)
            centroidY += Float(neighbor.y)
            centroidZ += neighbor.depth
        }

        let n = Float(neighbors.count)
        centroidX /= n
        centroidY /= n
        centroidZ /= n

        // Calculate displacement from centroid
        let dx = Float(x) - centroidX
        let dy = Float(y) - centroidY
        let dz = centerDepth - centroidZ

        let displacement = sqrt(dx * dx + dy * dy + dz * dz)

        // Normalize by radius
        return displacement / Float(neighborhoodRadius)
    }

    // MARK: - Gradient Calculation (Equation 3)

    /// Calculate gradients for all pixels
    private func calculateAllGradients(floatDepth: UnsafePointer<Float>, edgeIndices: [Float], width: Int, height: Int, output: inout [(Float, Float, Float)]) {
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                output[idx] = calculateGradients(x: x, y: y, floatDepth: floatDepth, edgeIndices: edgeIndices, width: width, height: height)
            }
        }
    }

    /// Calculate gradients Ix, Iy, Iz for a point (Equation 3 from paper)
    private func calculateGradients(x: Int, y: Int, floatDepth: UnsafePointer<Float>, edgeIndices: [Float], width: Int, height: Int) -> (Float, Float, Float) {
        let idx = y * width + x
        let centerDepth = floatDepth[idx]
        let centerEdgeIndex = edgeIndices[idx]

        guard centerDepth.isFinite && centerDepth > 0 else {
            return (0, 0, 0)
        }

        var maxGradX: Float = 0.0
        var maxGradY: Float = 0.0
        var maxGradZ: Float = 0.0

        let r = neighborhoodRadius

        for dy in -r...r {
            for dx in -r...r {
                let nx = x + dx
                let ny = y + dy

                guard nx >= 0 && nx < width && ny >= 0 && ny < height && !(dx == 0 && dy == 0) else {
                    continue
                }

                let nIdx = ny * width + nx
                let nDepth = floatDepth[nIdx]
                let nEdgeIndex = edgeIndices[nIdx]

                guard nDepth.isFinite && nDepth > 0 else {
                    continue
                }

                // Calculate 3D distance
                let deltaX = Float(dx)
                let deltaY = Float(dy)
                let deltaZ = centerDepth - nDepth
                let distance = sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)

                guard distance > 0 else { continue }

                // Calculate gradient contribution (Equation 3)
                let edgeDiff = centerEdgeIndex - nEdgeIndex
                let gradX = edgeDiff * (deltaX / distance)
                let gradY = edgeDiff * (deltaY / distance)
                let gradZ = edgeDiff * (deltaZ / distance)

                // Keep maximum (as in paper)
                if abs(gradX) > abs(maxGradX) {
                    maxGradX = gradX
                }
                if abs(gradY) > abs(maxGradY) {
                    maxGradY = gradY
                }
                if abs(gradZ) > abs(maxGradZ) {
                    maxGradZ = gradZ
                }
            }
        }

        return (maxGradX, maxGradY, maxGradZ)
    }

    // MARK: - Gaussian Smoothing (Equation 7)

    /// Apply Gaussian smoothing to gradients to avoid Det(M) = 0
    private func applyGaussianSmoothing(to gradients: inout [(Float, Float, Float)], width: Int, height: Int) {
        var smoothed = gradients
        let r = 2  // Smaller radius for efficiency

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x

                var sumX: Float = 0.0
                var sumY: Float = 0.0
                var sumZ: Float = 0.0
                var weightSum: Float = 0.0

                for dy in -r...r {
                    for dx in -r...r {
                        let nx = x + dx
                        let ny = y + dy

                        guard nx >= 0 && nx < width && ny >= 0 && ny < height else {
                            continue
                        }

                        let nIdx = ny * width + nx
                        let dist = sqrt(Float(dx * dx + dy * dy))
                        let weight = exp(-dist * dist / (2 * gaussianSigma * gaussianSigma))

                        sumX += gradients[nIdx].0 * weight
                        sumY += gradients[nIdx].1 * weight
                        sumZ += gradients[nIdx].2 * weight
                        weightSum += weight
                    }
                }

                if weightSum > 0 {
                    smoothed[idx] = (sumX / weightSum, sumY / weightSum, sumZ / weightSum)
                }
            }
        }

        gradients = smoothed
    }

    // MARK: - Edge Detection (Equation 6)

    /// Detect edge candidates using eigenvalue ratio analysis
    private func detectEdgeCandidates(gradients: [(Float, Float, Float)], width: Int, height: Int, output: inout [Float]) {
        for i in 0..<gradients.count {
            let (Ix, Iy, Iz) = gradients[i]

            // Build matrix M (Equation 5)
            let m11 = Ix * Ix
            let m12 = Ix * Iy
            let m13 = Ix * Iz
            let m22 = Iy * Iy
            let m23 = Iy * Iz
            let m33 = Iz * Iz

            // Calculate trace and determinant
            let trace = m11 + m22 + m33
            let det = m11 * (m22 * m33 - m23 * m23) - m12 * (m12 * m33 - m23 * m13) + m13 * (m12 * m23 - m22 * m13)

            // Avoid division by zero
            guard abs(det) > 1e-6 else {
                output[i] = 0.0
                continue
            }

            // Calculate eigenvalue ratio (Equation 6)
            let ratio = (trace * trace * trace) / abs(det)

            // Threshold for edge detection
            output[i] = ratio > edgeThreshold ? ratio : 0.0
        }
    }

    // MARK: - Non-Maximum Suppression

    /// Thin edges using non-maximum suppression along gradient direction
    private func nonMaximumSuppression(edgeMap: inout [Float], gradients: [(Float, Float, Float)], width: Int, height: Int) {
        var suppressed = edgeMap

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let edgeStrength = edgeMap[idx]

                guard edgeStrength > 0 else {
                    continue
                }

                let (gx, gy, _) = gradients[idx]
                let gradMag = sqrt(gx * gx + gy * gy)

                guard gradMag > 0 else {
                    continue
                }

                // Normalize gradient direction
                let dirX = gx / gradMag
                let dirY = gy / gradMag

                // Check neighbors along gradient direction
                let x1 = x + Int(round(dirX))
                let y1 = y + Int(round(dirY))
                let x2 = x - Int(round(dirX))
                let y2 = y - Int(round(dirY))

                // Check bounds
                if x1 >= 0 && x1 < width && y1 >= 0 && y1 < height &&
                   x2 >= 0 && x2 < width && y2 >= 0 && y2 < height {

                    let idx1 = y1 * width + x1
                    let idx2 = y2 * width + x2

                    // Suppress if not local maximum
                    if edgeStrength <= edgeMap[idx1] || edgeStrength <= edgeMap[idx2] {
                        suppressed[idx] = 0.0
                    }
                }
            }
        }

        edgeMap = suppressed
    }

    // MARK: - Helper Methods

    /// Create output CVPixelBuffer from edge strengths
    private func createEdgeBuffer(from edgeStrengths: [Float], width: Int, height: Int) -> CVPixelBuffer? {
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

        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0)) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)

        // Normalize edge strengths to 0-1 range
        let maxEdge = edgeStrengths.max() ?? 1.0

        for i in 0..<edgeStrengths.count {
            floatBuffer[i] = maxEdge > 0 ? edgeStrengths[i] / maxEdge : 0.0
        }

        return buffer
    }
}
