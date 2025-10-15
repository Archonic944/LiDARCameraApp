//
//  CameraViewController.swift
//  LiDARCameraApp
//
//  Created by Gabriel C on 10/12/25.
//

import UIKit
import AVFoundation
import Photos

/// Main view controller for the LiDAR camera app
/// Coordinates camera capture, depth processing, and visualization
class CameraViewController: UIViewController {

    // MARK: - Properties

    // Camera components
    private let captureSession = AVCaptureSession()
    private var photoOutput = AVCapturePhotoOutput()
    private var depthOutput = AVCaptureDepthDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    // Depth processing components
    private let depthProcessor = DepthProcessor()
    private let depthVisualizer = DepthVisualizer()

    // UI components
    private var depthPreviewView: UIImageView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDepthPreviewView()
        requestCameraAccess()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        previewLayer?.frame = view.bounds
        depthPreviewView?.frame = view.bounds
    }

    // MARK: - Setup

    /// Sets up the depth preview overlay
    private func setupDepthPreviewView() {
        depthPreviewView = UIImageView(frame: view.bounds)
        depthPreviewView.contentMode = .scaleAspectFill
        depthPreviewView.alpha = 0.8  // Partially transparent
        view.addSubview(depthPreviewView)
    }

    // MARK: - Camera Permission
    private func requestCameraAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showCameraPermissionError()
                    }
                }
            }
        default:
            showCameraPermissionError()
        }
    }

    private func showCameraPermissionError() {
        let alert = UIAlertController(
            title: "Camera Access Needed",
            message: "Please allow camera access in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        do {
            // Configure camera device
            guard let device = getCameraDevice() else {
                print("⚠️ No suitable camera found.")
                return
            }

            // Add camera input
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            // Configure outputs
            configurePhotoOutput()
            configureDepthOutput()

            captureSession.commitConfiguration()

            // Set up preview layer
            setupPreviewLayer()

            // Start capture session
            captureSession.startRunning()

        } catch {
            print("❌ Error setting up camera: \(error)")
        }
    }

    private func getCameraDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) ??
               AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configurePhotoOutput() {
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
            print("✅ Depth data delivery enabled.")
        } else {
            print("⚠️ Depth data not supported on this device.")
        }
    }

    private func configureDepthOutput() {
        if captureSession.canAddOutput(depthOutput) {
            captureSession.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            print("✅ Depth output added.")
        }

        let depthQueue = DispatchQueue(label: "com.gabe.depthQueue")
        depthOutput.setDelegate(self, callbackQueue: depthQueue)

        if let connection = depthOutput.connection(with: .depthData) {
            connection.isEnabled = true
        }
    }

    private func setupPreviewLayer() {
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds

        // Sync depth connection with RGB connection
        if let rgbConn = previewLayer.connection,
           let depthConn = depthOutput.connection(with: .depthData) {
            depthConn.videoRotationAngle = rgbConn.videoRotationAngle
            depthConn.isVideoMirrored = rgbConn.isVideoMirrored
        }

        view.layer.insertSublayer(previewLayer, at: 0)
    }

    // MARK: - Photo Capture
    @IBAction func takePhoto(_ sender: Any) {
        let settings = AVCapturePhotoSettings()
        settings.isDepthDataDeliveryEnabled = true
        settings.embedsDepthDataInPhoto = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate

extension CameraViewController: AVCaptureDepthDataOutputDelegate {

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                        didOutput depthData: AVDepthData,
                        timestamp: CMTime,
                        connection: AVCaptureConnection) {

        // Process depth data
        let processedDepthMap = depthProcessor.processDepthData(depthData)

        // Get current orientation and screen size
        guard let videoOrientation = previewLayer.connection?.videoOrientation else { return }
        let viewSize = UIScreen.main.bounds.size

        // Visualize depth data
        guard let depthImage = depthVisualizer.visualizeDepth(
            depthMap: processedDepthMap,
            orientation: videoOrientation,
            targetSize: viewSize
        ) else { return }

        // Update UI on main thread
        Task { @MainActor in
            self.depthPreviewView.image = UIImage(cgImage: depthImage)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                    didFinishProcessingPhoto photo: AVCapturePhoto,
                    error: Error?) {

        if let error = error {
            print("❌ Error capturing photo: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            print("⚠️ Could not get photo data.")
            return
        }

        // Log depth data info if available
        if let depth = photo.depthData {
            logDepthInfo(depth)
        } else {
            print("⚠️ No depth data in this photo.")
        }

        // Save to photo library
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        print("✅ Photo saved to library.")
    }

    private func logDepthInfo(_ depthData: AVDepthData) {
        print("✅ Depth data captured!")

        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let depthMap = convertedDepth.depthDataMap

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        print("Depth map size: \(width)x\(height)")

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
            let centerValue = floatBuffer[Int(width * height / 2)]
            print("Center depth: \(centerValue) (disparity units)")
        }
    }
}
