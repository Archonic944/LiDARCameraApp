//
//  CameraViewController.swift
//  LiDARCameraApp
//
//  Created by Gabriel Cohen on 10/12/25.
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
    private var videoOutput = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!

    private final var APERTURE_SIZE = 0.05

    // Depth processing components
    private let depthProcessor = DepthProcessor()
    private let depthVisualizer = DepthVisualizer()
    private let edgeDetectorGPU = EdgeDetectorGPU()

    // Edge detection performance
    private let edgeQueue = DispatchQueue(label: "com.gabe.edgeQueue", qos: .userInitiated)
    private var edgeFrameCounter: Int = 0
    private let edgeFrameSkip: Int = 3  // Process every 3rd frame for GPU (faster)

    // Cached frames for edge detection
    private var latestRGBImage: CIImage?
    private var latestEdgeMap: CVPixelBuffer?

    // Haptic feedback
    private let hapticManager = HapticFeedbackManager()

    // Gesture management
    private var gestureManager: GestureManager!

    // UI components
    private var depthPreviewView: UIImageView!
    private var edgePreviewView: UIImageView!

    // Cached depth data for tap-to-calibrate
    private var latestDepthData: AVDepthData?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDepthPreviewView()
        setupEdgePreviewView()
        setupGestureManager()
        requestCameraAccess()

        // Start continuous haptic feedback
        hapticManager.start()
    }

    deinit {
        // Stop haptics when view controller is deallocated
        hapticManager.stop()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        previewLayer?.frame = view.bounds
        depthPreviewView?.frame = view.bounds
        edgePreviewView?.frame = view.bounds
    }

    // MARK: - Setup

    /// Sets up the depth preview overlay
    private func setupDepthPreviewView() {
        depthPreviewView = UIImageView(frame: view.bounds)
        depthPreviewView.contentMode = .scaleAspectFill
        depthPreviewView.alpha = 0.8  // Partially transparent
        depthPreviewView.isUserInteractionEnabled = false
        view.addSubview(depthPreviewView)
    }

    /// Sets up the edge preview overlay
    private func setupEdgePreviewView() {
        edgePreviewView = UIImageView(frame: view.bounds)
        edgePreviewView.contentMode = .scaleAspectFill
        edgePreviewView.alpha = 1.0  // Fully opaque for edges
        edgePreviewView.isUserInteractionEnabled = true
        view.addSubview(edgePreviewView)
    }

    /// Sets up gesture manager for tap-to-calibrate
    private func setupGestureManager() {
        gestureManager = GestureManager(parentView: view)
        gestureManager.delegate = self
        gestureManager.addTapGesture(to: edgePreviewView)
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
            configureVideoOutput()

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

    private func configureVideoOutput() {
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)

            // Configure for RGB video frames
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]

            // Use same queue as depth for easier synchronization
            let videoQueue = DispatchQueue(label: "com.gabe.videoQueue")
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

            print("✅ Video output added for RGB edge detection.")
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

// MARK: - GestureManagerDelegate

extension CameraViewController: GestureManagerDelegate {

    func gestureManager(_ manager: GestureManager, didTapAt point: CGPoint) {
        guard let depthData = latestDepthData else {
            print("⚠️ No depth data available for calibration")
            return
        }

        // Calibrate depth range to current scene (tap location is irrelevant)
        depthProcessor.calibrateToCurrentFrame(from: depthData)
    }

    func gestureManagerDidDoubleTap(_ manager: GestureManager) {
        // Reset to default depth range
        depthProcessor.resetToDefaultRange()
        print("🔄 Reset depth range to default values")
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate

extension CameraViewController: AVCaptureDepthDataOutputDelegate {

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                        didOutput depthData: AVDepthData,
                        timestamp: CMTime,
                        connection: AVCaptureConnection) {

        // Cache latest depth data for tap-to-calibrate
        latestDepthData = depthData

        // Process depth data
        let processedDepthMap = depthProcessor.processDepthData(depthData)

        // GPU-accelerated edge detection (RGB + Depth fusion)
        edgeFrameCounter += 1
        if edgeFrameCounter >= edgeFrameSkip {
            edgeFrameCounter = 0

            // Run GPU edge detection on separate queue
            edgeQueue.async { [weak self] in
                guard let self = self else { return }

                let startTime = Date()

                // Detect edges using GPU (combines RGB + depth)
                let edgeMap = self.edgeDetectorGPU.detectEdges(
                    rgbImage: self.latestRGBImage,
                    depthMap: processedDepthMap
                )

                let elapsed = Date().timeIntervalSince(startTime)
                print("⏱️ GPU edge detection took \(String(format: "%.1f", elapsed * 1000))ms")

                // Update cached edge map
                self.latestEdgeMap = edgeMap

                // Visualize edges and update UI
                if let edgeMap = edgeMap,
                   let videoOrientation = self.previewLayer.connection?.videoOrientation {
                    let viewSize = UIScreen.main.bounds.size

                    if let edgeImage = self.depthVisualizer.visualizeEdges(
                        edgeMap: edgeMap,
                        orientation: videoOrientation,
                        targetSize: viewSize
                    ) {
                        print("✅ GPU edge image created")
                        Task { @MainActor in
                            self.edgePreviewView.image = UIImage(cgImage: edgeImage)
                        }
                    }
                }
            }
        }

        // Sample center depth for haptic feedback
        let centerDepth = depthProcessor.sampleCenterDepth(from: processedDepthMap, apertureSize: APERTURE_SIZE)

        // Update haptic intensity based on proximity
        // Higher depth value = closer object = stronger vibration
        hapticManager.updateIntensity(forDepth: centerDepth)

        // Get current orientation and screen size
        guard let videoOrientation = previewLayer.connection?.videoOrientation else { return }
        let viewSize = UIScreen.main.bounds.size

        // Visualize depth data
        guard let depthImage = depthVisualizer.visualizeDepth(
            depthMap: processedDepthMap,
            orientation: videoOrientation,
            targetSize: viewSize
        ) else { return }

        // Update depth UI on main thread
        Task { @MainActor in
            self.depthPreviewView.image = UIImage(cgImage: depthImage)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                      didOutput sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {

        // Extract CIImage from RGB video frame
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Cache latest RGB frame for edge detection
        latestRGBImage = CIImage(cvPixelBuffer: pixelBuffer)
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
