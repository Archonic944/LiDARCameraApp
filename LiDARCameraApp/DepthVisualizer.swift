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
    ///   - depthMap: Normalized depth pixel buffer
    ///   - orientation: Device orientation for proper rotation
    ///   - targetSize: Size to scale the output to
    /// - Returns: Rendered CGImage of the depth overlay
    func visualizeDepth(depthMap: CVPixelBuffer,
                       orientation: AVCaptureVideoOrientation,
                       targetSize: CGSize) -> CGImage? {

        // Create CIImage from depth map
        var ciDepth = CIImage(cvPixelBuffer: depthMap)

        // Apply false color mapping
        ciDepth = applyFalseColor(to: ciDepth)

        // Apply orientation transform
        ciDepth = applyOrientation(to: ciDepth, videoOrientation: orientation)

        // Scale and crop to target size
        ciDepth = scaleAndCrop(image: ciDepth, to: targetSize)

        // Render to CGImage
        return ciContext.createCGImage(ciDepth, from: ciDepth.extent)
    }

    // MARK: - Private Methods

    /// Applies false color filter to depth image
    private func applyFalseColor(to image: CIImage) -> CIImage {
        return image.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": farColor,   // Low values (far) = blue
            "inputColor1": nearColor   // High values (near) = red
        ])
    }

    /// Applies orientation transform to match device orientation
    private func applyOrientation(to image: CIImage,
                                 videoOrientation: AVCaptureVideoOrientation) -> CIImage {

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
        var orientedImage = image.oriented(orientation)
        let orientedExtent = orientedImage.extent
        orientedImage = orientedImage.transformed(
            by: CGAffineTransform(translationX: -orientedExtent.origin.x,
                                 y: -orientedExtent.origin.y)
        )

        return orientedImage
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
