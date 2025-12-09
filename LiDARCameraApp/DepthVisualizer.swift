//
//  DepthVisualizer.swift
//  LiDARCameraApp
//
//  Handles depth visualization and rendering
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Renders depth data as colored overlays
class DepthVisualizer {

    // MARK: - Properties

    private let ciContext: CIContext

    /// Color for far objects (low disparity values)
    var farColor: CIColor = CIColor(red: 0, green: 0, blue: 1)  // Blue

    /// Color for near objects (high disparity values)
    var nearColor: CIColor = CIColor(red: 1, green: 0, blue: 0)  // Red

    // MARK: - Initialization

    init() {
        self.ciContext = CIContext()
    }

    // MARK: - Public Methods

    /// Converts a depth map to a colorized CGImage
    /// - Parameters:
    ///   - depthMap: Depth pixel buffer in METERS (already oriented by DepthProcessor)
    ///   - orientation: Device orientation (kept for API compatibility but not used - orientation handled in DepthProcessor)
    ///   - targetSize: Size to scale the output to
    ///   - minDepth: Minimum depth in meters (for proximity conversion)
    ///   - maxDepth: Maximum depth in meters (for proximity conversion)
    /// - Returns: Rendered CGImage of the depth overlay
    func visualizeDepth(depthMap: CVPixelBuffer,
                       orientation: AVCaptureVideoOrientation,
                       targetSize: CGSize,
                       minDepth: Float,
                       maxDepth: Float) -> CGImage? {

        // Convert meters to proximity (0-1) for visualization
        guard let proximityMap = depthMap.convertMetersToProximity(minDepth: minDepth, maxDepth: maxDepth) else {
            return nil
        }

        // Create CIImage from proximity map (already correctly oriented)
        var ciDepth = CIImage(cvPixelBuffer: proximityMap)

        // Apply false color mapping
        ciDepth = applyFalseColor(to: ciDepth)

        // NOTE: Orientation already applied in DepthProcessor - depthMap[row][col] matches screen (col, row)

        // Scale and crop to target size
        ciDepth = scaleAndCrop(image: ciDepth, to: targetSize)

        // Render to CGImage
        return ciContext.createCGImage(ciDepth, from: ciDepth.extent)
    }

    /// Converts an edge map to a colorized CGImage with custom colors
    /// - Parameters:
    ///   - edgeMap: Normalized edge strength pixel buffer (0-1) (already oriented by DepthProcessor)
    ///   - orientation: Device orientation (kept for API compatibility but not used - orientation handled in DepthProcessor)
    ///   - targetSize: Size to scale the output to
    /// - Returns: Rendered CGImage of the edge overlay
    func visualizeEdges(edgeMap: CVPixelBuffer,
                       orientation: AVCaptureVideoOrientation,
                       targetSize: CGSize) -> CGImage? {

        // Create CIImage from edge map (already correctly oriented by DepthProcessor)
        var ciEdge = CIImage(cvPixelBuffer: edgeMap)

        // Apply edge color mapping (transparent -> bright green)
        ciEdge = ciEdge.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0, green: 1, blue: 0, alpha: 0),      // Transparent Green (preserves brightness for weak edges)
            "inputColor1": CIColor(red: 0, green: 1, blue: 0, alpha: 1)       // Bright Green
        ])

        // NOTE: Orientation already applied in DepthProcessor to edge map
        // Edge map is correctly oriented to match depth map and screen

        // Scale and crop to target size
        ciEdge = scaleAndCrop(image: ciEdge, to: targetSize)

        // Render to CGImage
        return ciContext.createCGImage(ciEdge, from: ciEdge.extent)
    }

    // MARK: - Private Methods

    /// Applies false color filter to depth image
    private func applyFalseColor(to image: CIImage) -> CIImage {
        return image.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": farColor,   // Low values (far) = blue
            "inputColor1": nearColor   // High values (near) = red
        ])
    }

    /// Scales and crops image to target size using aspect fill
    private func scaleAndCrop(image: CIImage, to targetSize: CGSize) -> CIImage {
        let depthExtent = image.extent

        // Calculate scale for aspect fill
        let scaleX = targetSize.width / depthExtent.width
        let scaleY = targetSize.height / depthExtent.height
        let scale = max(scaleX, scaleY)

        // Scale the image
        var scaledImage = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        // Center crop to target size
        let scaledExtent = scaledImage.extent
        let cropX = scaledExtent.origin.x + (scaledExtent.width - targetSize.width) / 2
        let cropY = scaledExtent.origin.y + (scaledExtent.height - targetSize.height) / 2
        scaledImage = scaledImage.cropped(
            to: CGRect(x: cropX, y: cropY,
                      width: targetSize.width,
                      height: targetSize.height)
        )

        return scaledImage
    }
}
