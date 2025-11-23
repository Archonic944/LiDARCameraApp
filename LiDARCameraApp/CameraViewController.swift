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
    private lazy var edgeAlertManager = EdgeAlertManager(hapticManager: hapticManager)

    // Gesture management
    private var gestureManager: GestureManager!

    // UI components
    private var depthPreviewView: UIImageView!
    private var edgePreviewView: UIImageView!
    private var pageControl: UISegmentedControl!
    private var disparityContainer: UIView!
    private var edgeDetectionContainer: UIView!

    // Disparity controls
    private var minLabel: UILabel!
    private var maxLabel: UILabel!
    private var minSlider: UISlider!
    private var maxSlider: UISlider!
    private var hintLabel: UILabel!

    // Edge detection controls
    private var sensitivityLabel: UILabel!
    private var sensitivitySlider: UISlider!
    private var gridNLabel: UILabel!
    private var gridNSlider: UISlider!
    private var gridMLabel: UILabel!
    private var gridMSlider: UISlider!
    private var rowColSkipLabel: UILabel!
    private var rowColSkipSlider: UISlider!
    private var randomSearchLabel: UILabel!
    private var randomSearchSlider: UISlider!
    private var edgeHintLabel: UILabel!

    // Cached depth data for tap-to-calibrate
    private var latestDepthData: AVDepthData?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDepthPreviewView()
        setupEdgePreviewView()
        if FeatureFlags.tuningMode {
            setupDisparityControls()
        } else {
            setupGestureManager()
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
        edgePreviewView?.frame = view.bounds
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
        edgePreviewView.isUserInteractionEnabled = true
    }

    /// Sets up on-screen sliders to tweak min/max disparity and edge detection parameters in real time
    private func setupDisparityControls() {
        edgePreviewView.isUserInteractionEnabled = false
        // Ensure defaults are applied at startup
        depthProcessor.resetToDefaultRange()

        // Segmented control for page switching
        pageControl = UISegmentedControl(items: ["Disparity", "Edge Detection"])
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.selectedSegmentIndex = 0
        pageControl.addTarget(self, action: #selector(onPageChanged), for: .valueChanged)
        view.addSubview(pageControl)

        // Setup both containers
        setupDisparityPage()
        setupEdgeDetectionPage()

        // Layout page control
        NSLayoutConstraint.activate([
            pageControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            pageControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            pageControl.bottomAnchor.constraint(equalTo: disparityContainer.topAnchor, constant: -12)
        ])

        // Show disparity page by default
        showPage(index: 0)
    }

    /// Creates the disparity controls container
    private func setupDisparityPage() {
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

    /// Creates the edge detection controls container
    private func setupEdgeDetectionPage() {
        edgeDetectionContainer = UIView()
        edgeDetectionContainer.translatesAutoresizingMaskIntoConstraints = false
        edgeDetectionContainer.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        edgeDetectionContainer.layer.cornerRadius = 10
        edgeDetectionContainer.clipsToBounds = true
        view.addSubview(edgeDetectionContainer)

        // Create labels and sliders for edge detection parameters
        sensitivityLabel = UILabel()
        sensitivityLabel.translatesAutoresizingMaskIntoConstraints = false
        sensitivityLabel.textColor = .white
        sensitivityLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        sensitivitySlider = UISlider()
        sensitivitySlider.translatesAutoresizingMaskIntoConstraints = false
        sensitivitySlider.minimumValue = 0.001
        sensitivitySlider.maximumValue = 0.2
        sensitivitySlider.value = edgeDetectorGPU?.sensitivityT ?? 0.05
        sensitivitySlider.addTarget(self, action: #selector(onSensitivitySliderChanged), for: .valueChanged)

        gridNLabel = UILabel()
        gridNLabel.translatesAutoresizingMaskIntoConstraints = false
        gridNLabel.textColor = .white
        gridNLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        gridNSlider = UISlider()
        gridNSlider.translatesAutoresizingMaskIntoConstraints = false
        gridNSlider.minimumValue = 8
        gridNSlider.maximumValue = 128
        gridNSlider.value = Float(edgeDetectorGPU?.gridN ?? 32)
        gridNSlider.addTarget(self, action: #selector(onGridNSliderChanged), for: .valueChanged)

        gridMLabel = UILabel()
        gridMLabel.translatesAutoresizingMaskIntoConstraints = false
        gridMLabel.textColor = .white
        gridMLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        gridMSlider = UISlider()
        gridMSlider.translatesAutoresizingMaskIntoConstraints = false
        gridMSlider.minimumValue = 8
        gridMSlider.maximumValue = 128
        gridMSlider.value = Float(edgeDetectorGPU?.gridM ?? 24)
        gridMSlider.addTarget(self, action: #selector(onGridMSliderChanged), for: .valueChanged)

        rowColSkipLabel = UILabel()
        rowColSkipLabel.translatesAutoresizingMaskIntoConstraints = false
        rowColSkipLabel.textColor = .white
        rowColSkipLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        rowColSkipSlider = UISlider()
        rowColSkipSlider.translatesAutoresizingMaskIntoConstraints = false
        rowColSkipSlider.minimumValue = 1
        rowColSkipSlider.maximumValue = 10
        rowColSkipSlider.value = Float(edgeDetectorGPU?.rowColSkipK ?? 1)
        rowColSkipSlider.addTarget(self, action: #selector(onRowColSkipSliderChanged), for: .valueChanged)

        randomSearchLabel = UILabel()
        randomSearchLabel.translatesAutoresizingMaskIntoConstraints = false
        randomSearchLabel.textColor = .white
        randomSearchLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)

        randomSearchSlider = UISlider()
        randomSearchSlider.translatesAutoresizingMaskIntoConstraints = false
        randomSearchSlider.minimumValue = 0.0
        randomSearchSlider.maximumValue = 1.0
        randomSearchSlider.value = edgeDetectorGPU?.randomSearchRatio ?? 0.08
        randomSearchSlider.addTarget(self, action: #selector(onRandomSearchSliderChanged), for: .valueChanged)

        edgeHintLabel = UILabel()
        edgeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        edgeHintLabel.textColor = .systemYellow
        edgeHintLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        edgeHintLabel.numberOfLines = 0

        // Add subviews
        edgeDetectionContainer.addSubview(sensitivityLabel)
        edgeDetectionContainer.addSubview(sensitivitySlider)
        edgeDetectionContainer.addSubview(gridNLabel)
        edgeDetectionContainer.addSubview(gridNSlider)
        edgeDetectionContainer.addSubview(gridMLabel)
        edgeDetectionContainer.addSubview(gridMSlider)
        edgeDetectionContainer.addSubview(rowColSkipLabel)
        edgeDetectionContainer.addSubview(rowColSkipSlider)
        edgeDetectionContainer.addSubview(randomSearchLabel)
        edgeDetectionContainer.addSubview(randomSearchSlider)
        edgeDetectionContainer.addSubview(edgeHintLabel)

        updateEdgeDetectionLabelsAndHint()

        // Layout constraints
        NSLayoutConstraint.activate([
            edgeDetectionContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            edgeDetectionContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            edgeDetectionContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            sensitivityLabel.topAnchor.constraint(equalTo: edgeDetectionContainer.topAnchor, constant: 10),
            sensitivityLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            sensitivityLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            sensitivitySlider.topAnchor.constraint(equalTo: sensitivityLabel.bottomAnchor, constant: 4),
            sensitivitySlider.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            sensitivitySlider.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            gridNLabel.topAnchor.constraint(equalTo: sensitivitySlider.bottomAnchor, constant: 8),
            gridNLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            gridNLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            gridNSlider.topAnchor.constraint(equalTo: gridNLabel.bottomAnchor, constant: 4),
            gridNSlider.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            gridNSlider.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            gridMLabel.topAnchor.constraint(equalTo: gridNSlider.bottomAnchor, constant: 8),
            gridMLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            gridMLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            gridMSlider.topAnchor.constraint(equalTo: gridMLabel.bottomAnchor, constant: 4),
            gridMSlider.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            gridMSlider.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            rowColSkipLabel.topAnchor.constraint(equalTo: gridMSlider.bottomAnchor, constant: 8),
            rowColSkipLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            rowColSkipLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            rowColSkipSlider.topAnchor.constraint(equalTo: rowColSkipLabel.bottomAnchor, constant: 4),
            rowColSkipSlider.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            rowColSkipSlider.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            randomSearchLabel.topAnchor.constraint(equalTo: rowColSkipSlider.bottomAnchor, constant: 8),
            randomSearchLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            randomSearchLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            randomSearchSlider.topAnchor.constraint(equalTo: randomSearchLabel.bottomAnchor, constant: 4),
            randomSearchSlider.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            randomSearchSlider.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),

            edgeHintLabel.topAnchor.constraint(equalTo: randomSearchSlider.bottomAnchor, constant: 8),
            edgeHintLabel.leadingAnchor.constraint(equalTo: edgeDetectionContainer.leadingAnchor, constant: 12),
            edgeHintLabel.trailingAnchor.constraint(equalTo: edgeDetectionContainer.trailingAnchor, constant: -12),
            edgeHintLabel.bottomAnchor.constraint(equalTo: edgeDetectionContainer.bottomAnchor, constant: -10)
        ])
    }

    private func showPage(index: Int) {
        disparityContainer.isHidden = (index != 0)
        edgeDetectionContainer.isHidden = (index != 1)
    }

    @objc private func onPageChanged() {
        showPage(index: pageControl.selectedSegmentIndex)
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

    private func updateEdgeDetectionLabelsAndHint() {
        let sensitivity = sensitivitySlider.value
        let gridN = Int(gridNSlider.value)
        let gridM = Int(gridMSlider.value)
        let rowColSkip = Int(rowColSkipSlider.value)
        let randomSearch = randomSearchSlider.value

        sensitivityLabel.text = String(format: "Sensitivity T: %.3f (lower = more sensitive)", sensitivity)
        gridNLabel.text = String(format: "Grid N (horizontal patches): %d", gridN)
        gridMLabel.text = String(format: "Grid M (vertical patches): %d", gridM)
        rowColSkipLabel.text = String(format: "Row/Col Skip K: %d", rowColSkip)
        randomSearchLabel.text = String(format: "Random Search Ratio: %.2f", randomSearch)

        edgeHintLabel.text = String(
            format: "Use as defaults:\nsensitivityT = %.3f\ngridN = %d\ngridM = %d\nrowColSkipK = %d\nrandomSearchRatio = %.2f",
            sensitivity, gridN, gridM, rowColSkip, randomSearch
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

    @objc private func onSensitivitySliderChanged() {
        edgeDetectorGPU?.sensitivityT = sensitivitySlider.value
        updateEdgeDetectionLabelsAndHint()
    }

    @objc private func onGridNSliderChanged() {
        edgeDetectorGPU?.gridN = Int(gridNSlider.value)
        updateEdgeDetectionLabelsAndHint()
    }

    @objc private func onGridMSliderChanged() {
        edgeDetectorGPU?.gridM = Int(gridMSlider.value)
        updateEdgeDetectionLabelsAndHint()
    }

    @objc private func onRowColSkipSliderChanged() {
        edgeDetectorGPU?.rowColSkipK = Int(rowColSkipSlider.value)
        updateEdgeDetectionLabelsAndHint()
    }

    @objc private func onRandomSearchSliderChanged() {
        edgeDetectorGPU?.randomSearchRatio = randomSearchSlider.value
        updateEdgeDetectionLabelsAndHint()
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
            print("⚠️ No depth data available for calibration")
            return
        }

        // Calibrate depth range to current scene (tap location is irrelevant)
        // TODO Commented for now due to poor functionality and conflicting with other gestures
        // depthProcessor.calibrateToCurrentFrame(from: depthData)
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

        // Get current orientation
        guard let videoOrientation = previewLayer.connection?.videoOrientation else { return }

        // Process depth data and orient it to match screen coordinates
        let processedDepthMap = depthProcessor.processDepthData(depthData, orientation: videoOrientation)

        // GPU-accelerated edge detection (works on unoriented depth for consistency)
        edgeFrameCounter += 1
        if edgeFrameCounter >= edgeFrameSkip {
            edgeFrameCounter = 0

            // Run GPU edge detection on separate queue
            edgeQueue.async { [weak self] in
                guard let self = self else { return }

                let startTime = Date()

                // Get unoriented depth map for edge detection (native camera orientation)
                let unorientedDepthMap = self.depthProcessor.getUnorientedDepthMap(depthData)

                // Detect edges using GPU
                let unorientedEdgeMap = self.edgeDetectorGPU?.processFrame(depthPixelBuffer: unorientedDepthMap)

                let elapsed = Date().timeIntervalSince(startTime)
                print("⏱️ GPU edge detection took \(String(format: "%.1f", elapsed * 1000))ms")
                
                guard let unorientedEdges = unorientedEdgeMap,
                      let videoOrientation = self.previewLayer.connection?.videoOrientation else {
                    return
                }

                let orientedEdgeMap = self.depthProcessor.orientEdgeMap(unorientedEdges, orientation: videoOrientation)

                // Update cached edge map (now correctly oriented)
                self.latestEdgeMap = orientedEdgeMap

                // Update edge alert based on current hold state
                if let gestureManager = self.gestureManager {
                    self.edgeAlertManager.updateEdgeAlert(
                        edgeMap: orientedEdgeMap,
                        holdingLeft: gestureManager.isHoldingLeftEdge,
                        holdingRight: gestureManager.isHoldingRightEdge,
                        holdingTop: gestureManager.isHoldingTopEdge,
                        holdingBottom: gestureManager.isHoldingBottomEdge
                    )
                }

                // Visualize edges and update UI
                let viewSize = UIScreen.main.bounds.size
                if let edgeImage = self.depthVisualizer.visualizeEdges(
                    edgeMap: orientedEdgeMap,
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

        // Sample center depth for haptic feedback (in meters)
        let centerDepthMeters = depthProcessor.sampleCenterDepth(from: processedDepthMap)

        // Convert meters to proximity (0=far, 1=close) for haptic feedback
        let proximity = depthProcessor.metersToProximity(centerDepthMeters)

        // Update haptic intensity based on proximity
        // Higher proximity value = closer object = stronger vibration
        hapticManager.updateIntensity(forDepth: proximity)

        // Get current orientation and screen size
        guard let videoOrientation = previewLayer.connection?.videoOrientation else { return }
        let viewSize = UIScreen.main.bounds.size

        // Visualize depth data (pass min/max for proximity conversion)
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
