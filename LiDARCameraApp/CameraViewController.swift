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
    private var previewLayer: AVCaptureVideoPreviewLayer!

    // Depth processing components
    private let depthProcessor = DepthProcessor()
    private let depthVisualizer = DepthVisualizer()

    // Surface analysis (replaces GPU edge detection)
    private let surfaceAnalyzer = SurfaceAnalyzer()

    // Haptic feedback
    private let hapticManager = HapticFeedbackManager()

    // Gesture management
    private var gestureManager: GestureManager!

    // UI components
    private var depthPreviewView: UIImageView!
    private var debugLabel: UILabel!
    private var disparityContainer: UIView!

    // Disparity controls
    private var minLabel: UILabel!
    private var maxLabel: UILabel!
    private var minSlider: UISlider!
    private var maxSlider: UISlider!
    private var hintLabel: UILabel!

    // Cached depth data for tap-to-calibrate
    private var latestDepthData: AVDepthData?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDepthPreviewView()
        setupDebugLabel()
        if FeatureFlags.tuningMode {
            setupDisparityControls()
        }
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
        gestureManager?.updateEdgeIndicatorFrames()
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

    /// Sets up the debug label for surface analysis readouts
    private func setupDebugLabel() {
        debugLabel = UILabel()
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.textColor = .white
        debugLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        debugLabel.numberOfLines = 3
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        debugLabel.layer.cornerRadius = 6
        debugLabel.clipsToBounds = true
        debugLabel.textAlignment = .center
        view.addSubview(debugLabel)

        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            debugLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            debugLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24)
        ])
    }

    /// Sets up gesture manager for tap-to-calibrate
    private func setupGestureManager() {
        gestureManager = GestureManager(parentView: view)
        gestureManager.delegate = self
        gestureManager.addTapGesture(to: depthPreviewView)
        depthPreviewView.isUserInteractionEnabled = true
    }

    /// Sets up on-screen sliders to tweak min/max disparity in real time
    private func setupDisparityControls() {
        // Ensure defaults are applied at startup
        depthProcessor.resetToDefaultRange()

        disparityContainer = UIView()
        disparityContainer.translatesAutoresizingMaskIntoConstraints = false
        disparityContainer.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        disparityContainer.layer.cornerRadius = 10
        disparityContainer.clipsToBounds = true
        view.addSubview(disparityContainer)

        // Labels and sliders
        minLabel = UILabel()
        minLabel.translatesAutoresizingMaskIntoConstraints = false
        minLabel.textColor = .white
        minLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        maxLabel = UILabel()
        maxLabel.translatesAutoresizingMaskIntoConstraints = false
        maxLabel.textColor = .white
        maxLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        minSlider = UISlider()
        minSlider.translatesAutoresizingMaskIntoConstraints = false
        minSlider.minimumValue = 0.0
        minSlider.maximumValue = 5.0
        minSlider.addTarget(self, action: #selector(onMinSliderChanged), for: .valueChanged)

        maxSlider = UISlider()
        maxSlider.translatesAutoresizingMaskIntoConstraints = false
        maxSlider.minimumValue = 0.1
        maxSlider.maximumValue = 8.0
        maxSlider.addTarget(self, action: #selector(onMaxSliderChanged), for: .valueChanged)

        hintLabel = UILabel()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = .systemYellow
        hintLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hintLabel.numberOfLines = 0

        // Add subviews
        disparityContainer.addSubview(minLabel)
        disparityContainer.addSubview(minSlider)
        disparityContainer.addSubview(maxLabel)
        disparityContainer.addSubview(maxSlider)
        disparityContainer.addSubview(hintLabel)

        // Set initial slider values from processor
        minSlider.value = depthProcessor.minDisparity
        maxSlider.value = depthProcessor.maxDisparity
        updateDisparityLabelsAndHint()

        // Layout constraints
        NSLayoutConstraint.activate([
            disparityContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            disparityContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            disparityContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            minLabel.topAnchor.constraint(equalTo: disparityContainer.topAnchor, constant: 10),
            minLabel.leadingAnchor.constraint(equalTo: disparityContainer.leadingAnchor, constant: 12),
            minLabel.trailingAnchor.constraint(equalTo: disparityContainer.trailingAnchor, constant: -12),

            minSlider.topAnchor.constraint(equalTo: minLabel.bottomAnchor, constant: 6),
            minSlider.leadingAnchor.constraint(equalTo: disparityContainer.leadingAnchor, constant: 12),
            minSlider.trailingAnchor.constraint(equalTo: disparityContainer.trailingAnchor, constant: -12),

            maxLabel.topAnchor.constraint(equalTo: minSlider.bottomAnchor, constant: 10),
            maxLabel.leadingAnchor.constraint(equalTo: disparityContainer.leadingAnchor, constant: 12),
            maxLabel.trailingAnchor.constraint(equalTo: disparityContainer.trailingAnchor, constant: -12),

            maxSlider.topAnchor.constraint(equalTo: maxLabel.bottomAnchor, constant: 6),
            maxSlider.leadingAnchor.constraint(equalTo: disparityContainer.leadingAnchor, constant: 12),
            maxSlider.trailingAnchor.constraint(equalTo: disparityContainer.trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: maxSlider.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: disparityContainer.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: disparityContainer.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: disparityContainer.bottomAnchor, constant: -10)
        ])
    }

    private func updateDisparityLabelsAndHint() {
        let minVal = minSlider.value
        let maxVal = maxSlider.value
        minLabel.text = String(format: "Min disparity (far): %.3f", minVal)
        maxLabel.text = String(format: "Max disparity (near): %.3f", maxVal)
        hintLabel.text = String(
            format: "Use as defaults:\nDepthProcessor.defaultMinDisparity = %.3f\nDepthProcessor.defaultMaxDisparity = %.3f",
            minVal, maxVal
        )
    }

    @objc private func onMinSliderChanged() {
        // Maintain invariant: min < max
        if minSlider.value >= maxSlider.value {
            maxSlider.value = min(minSlider.value + 0.01, maxSlider.maximumValue)
        }
        depthProcessor.minDisparity = minSlider.value
        depthProcessor.maxDisparity = maxSlider.value
        updateDisparityLabelsAndHint()
    }

    @objc private func onMaxSliderChanged() {
        // Maintain invariant: min < max
        if maxSlider.value <= minSlider.value {
            minSlider.value = max(maxSlider.value - 0.01, minSlider.minimumValue)
        }
        depthProcessor.minDisparity = minSlider.value
        depthProcessor.maxDisparity = maxSlider.value
        updateDisparityLabelsAndHint()
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
                print("No suitable camera found.")
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
            print("Error setting up camera: \(error)")
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
            print("Depth data delivery enabled.")
        } else {
            print("Depth data not supported on this device.")
        }
    }

    private func configureDepthOutput() {
        if captureSession.canAddOutput(depthOutput) {
            captureSession.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            print("Depth output added.")
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

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        gestureManager?.updateTouchState(touches: touches, in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        gestureManager?.updateTouchState(touches: touches, in: view)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        gestureManager?.clearTouchState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        gestureManager?.clearTouchState()
    }
}

// MARK: - GestureManagerDelegate

extension CameraViewController: GestureManagerDelegate {

    func gestureManager(_ manager: GestureManager, didTapAt point: CGPoint) {
        guard let depthData = latestDepthData else {
            print("No depth data available for calibration")
            return
        }

        // Calibrate depth range to current scene (tap location is irrelevant)
        // TODO Commented for now due to poor functionality and conflicting with other gestures
        // depthProcessor.calibrateToCurrentFrame(from: depthData)
    }

    func gestureManagerDidDoubleTap(_ manager: GestureManager) {
        // Reset to default depth range
        depthProcessor.resetToDefaultRange()
        print("Reset depth range to default values")
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

        // Get current orientation
        guard let videoOrientation = previewLayer.connection?.videoOrientation else { return }

        // Process depth data and orient it to match screen coordinates
        let processedDepthMap = depthProcessor.processDepthData(depthData, orientation: videoOrientation)

        // Check if any part of the scene is closer than 0.25m for alert mode
        let isTooClose = depthProcessor.checkForMinDistance(in: processedDepthMap, minDistance: 0.25)
        hapticManager.updateProximityAlert(isClose: isTooClose)

        // Surface analysis: detect normal changes and depth drops in center aperture
        let result = surfaceAnalyzer.analyze(depthMap: processedDepthMap)
        if result.shouldClick {
            hapticManager.fireTransientPulse(intensity: 1.0, sharpness: 1.0)
        }

        // Update debug label with surface analysis readouts
        let debugText = String(format: " dot: %.2f  \u{0394}d: %.3fm  angle: %.0f\u{00B0} ", result.normalDot, result.depthDelta, result.angleDegrees)
        Task { @MainActor in
            self.debugLabel.text = debugText
        }

        // Sample center depth for haptic feedback (in meters)
        let centerDepthMeters = depthProcessor.sampleCenterDepth(from: processedDepthMap)

        // Convert meters to proximity (0=far, 1=close) for haptic feedback
        let proximity = depthProcessor.metersToProximity(centerDepthMeters)

        // Update haptic intensity based on proximity
        // Higher proximity value = closer object = stronger vibration
        hapticManager.updateIntensity(forDepth: proximity)

        // Visualize depth data
        let viewSize = UIScreen.main.bounds.size

        guard let depthImage = depthVisualizer.visualizeDepth(
            depthMap: processedDepthMap,
            orientation: videoOrientation,
            targetSize: viewSize,
            minDepth: depthProcessor.minDisparity,
            maxDepth: depthProcessor.maxDisparity
        ) else { return }

        // Update depth UI on main thread
        Task { @MainActor in
            self.depthPreviewView.image = UIImage(cgImage: depthImage)
        }E
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                    didFinishProcessingPhoto photo: AVCapturePhoto,
                    error: Error?) {

        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            print("Could not get photo data.")
            return
        }

        // Log depth data info if available
        if let depth = photo.depthData {
            logDepthInfo(depth)
        } else {
            print("No depth data in this photo.")
        }

        // Save to photo library
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        print("Photo saved to library.")
    }

    private func logDepthInfo(_ depthData: AVDepthData) {
        print("Depth data captured!")

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
