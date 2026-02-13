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
    
    // Current depth level (0: short, 1: medium, 2: long)
    private var currentDepthLevelIndex: Int = 1
    
    // Focus toggle state
    private var isFocusToggled: Bool = false

    // UI components
    private var depthPreviewView: UIImageView!
    private var apertureCircleView: UIView!
    private var debugLabel: UILabel!
    private var disparityContainer: UIView!
    
    // Action Buttons
    private var controlsStackView: UIStackView!
    private var shortenButton: UIButton!
    private var lengthenButton: UIButton!
    private var focusButton: UIButton!
    
    // Description Buttons
    private var descriptionStackView: UIStackView!
    private var describeKeyItemButton: UIButton!
    private var describeBackgroundButton: UIButton!

    // Disparity controls
    private var minLabel: UILabel!
    private var maxLabel: UILabel!
    private var minSlider: UISlider!
    private var maxSlider: UISlider!
    private var hintLabel: UILabel!

    // Cached depth data for tap-to-calibrate
    private var latestDepthData: AVDepthData?
    
    // Gemini Analysis State
    private var pendingAnalysisPrompt: String?
    private var isAnalyzing: Bool = false
    private var analysisResultLabel: UILabel!
    private var analysisOverlay: UIView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true;
        setupDepthPreviewView()
        setupApertureCircle()
        setupDebugLabel()
        setupGestureManager()
        setupButtons()
        setupAnalysisUI()
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
        layoutApertureCircle()
    }

    // MARK: - Setup

    /// Sets up the action buttons (Shorten, Lengthen, Focus)
    private func setupButtons() {
        // Core control buttons
        shortenButton = createHighContrastButton(title: "Shorten", action: #selector(onShortenPressed))
        lengthenButton = createHighContrastButton(title: "Lengthen", action: #selector(onLengthenPressed))
        focusButton = createHighContrastButton(title: "Focus", action: #selector(onFocusToggled))
        
        // VoiceOver Accessibility for core controls
        shortenButton.accessibilityLabel = "Shorten depth range"
        shortenButton.accessibilityHint = "Decreases the maximum distance sensed"
        
        lengthenButton.accessibilityLabel = "Lengthen depth range"
        lengthenButton.accessibilityHint = "Increases the maximum distance sensed"
        
        focusButton.accessibilityLabel = "Toggle Focus"
        focusButton.accessibilityHint = "Reduces aperture size for precise sensing"
        focusButton.accessibilityTraits = [.button, .selected]

        controlsStackView = UIStackView(arrangedSubviews: [shortenButton, lengthenButton, focusButton])
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        controlsStackView.axis = .horizontal
        controlsStackView.distribution = .fillEqually
        controlsStackView.spacing = 20
        view.addSubview(controlsStackView)
        
        // Description buttons (Accent color)
        describeKeyItemButton = createAccentButton(title: "Describe Key Item", action: #selector(onDescribeKeyItemPressed))
        describeBackgroundButton = createAccentButton(title: "Describe Background Items", action: #selector(onDescribeBackgroundPressed))
        
        // VoiceOver Accessibility for descriptions
        describeKeyItemButton.accessibilityLabel = "Describe and read a key item in the frame, especially an item that you are holding."
        describeBackgroundButton.accessibilityLabel = "Give a brief overview of your surroundings in the frame."

        descriptionStackView = UIStackView(arrangedSubviews: [describeKeyItemButton, describeBackgroundButton])
        descriptionStackView.translatesAutoresizingMaskIntoConstraints = false
        descriptionStackView.axis = .horizontal
        descriptionStackView.distribution = .fillEqually
        descriptionStackView.spacing = 20
        view.addSubview(descriptionStackView)

        NSLayoutConstraint.activate([
            controlsStackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
            controlsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            controlsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            controlsStackView.heightAnchor.constraint(equalToConstant: 60),
            
            descriptionStackView.bottomAnchor.constraint(equalTo: controlsStackView.topAnchor, constant: -20),
            descriptionStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descriptionStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            descriptionStackView.heightAnchor.constraint(equalToConstant: 60)
        ])
    }

    private func createHighContrastButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        button.backgroundColor = .black
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 3
        button.layer.borderColor = UIColor.white.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func createAccentButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        // Use system accent color (indigo or blue) if AccentColor is not defined
        button.backgroundColor = UIColor(named: "AccentColor") ?? .systemIndigo
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 3
        button.layer.borderColor = UIColor.white.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// Sets up the depth preview overlay
    private func setupDepthPreviewView() {
        depthPreviewView = UIImageView(frame: view.bounds)
        depthPreviewView.contentMode = .scaleAspectFill
        depthPreviewView.alpha = 0.8  // Partially transparent
        depthPreviewView.isUserInteractionEnabled = false
        view.addSubview(depthPreviewView)
    }

    /// Sets up the aperture circle overlay (no fill, white stroke)
    private func setupApertureCircle() {
        apertureCircleView = UIView()
        apertureCircleView.isUserInteractionEnabled = false
        apertureCircleView.backgroundColor = .clear
        view.addSubview(apertureCircleView)
        layoutApertureCircle()
    }

    private func layoutApertureCircle() {
        guard let circle = apertureCircleView else { return }
        let diameter = min(view.bounds.width, view.bounds.height) * CGFloat(depthProcessor.apertureSize)
        circle.frame = CGRect(x: view.bounds.midX - diameter / 2,
                              y: view.bounds.midY - diameter / 2,
                              width: diameter, height: diameter)
        circle.layer.cornerRadius = diameter / 2

        // Remove old border shape if any, then set border
        circle.layer.borderWidth = 1.5
        circle.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
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

    /// Sets up gesture manager for tap-to-calibrate and depth range cycling
    private func setupGestureManager() {
        gestureManager = GestureManager(parentView: view)
        gestureManager.delegate = self
        gestureManager.addGestures(to: depthPreviewView)
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
    
    // MARK: - Button Actions
    
    @objc private func onShortenPressed() {
        if currentDepthLevelIndex > 0 {
            currentDepthLevelIndex -= 1
            updateDepthRangeToCurrentLevel()
            hapticManager.fireTransientPulse(intensity: 0.6, sharpness: 0.3)
        }
    }
    
    @objc private func onLengthenPressed() {
        if currentDepthLevelIndex < DepthLevels.all.count - 1 {
            currentDepthLevelIndex += 1
            updateDepthRangeToCurrentLevel()
            hapticManager.fireTransientPulse(intensity: 0.8, sharpness: 0.5)
        }
    }
    
    @objc private func onFocusToggled() {
        isFocusToggled.toggle()
        
        if isFocusToggled {
            depthProcessor.apertureSize = AppConfig.baseApertureSize / 5.0
            focusButton.backgroundColor = .white
            focusButton.setTitleColor(.black, for: .normal)
            focusButton.layer.borderColor = UIColor.black.cgColor
            focusButton.accessibilityTraits.insert(.selected)
            hapticManager.fireTransientPulse(intensity: 0.4, sharpness: 0.8)
        } else {
            depthProcessor.apertureSize = AppConfig.baseApertureSize
            focusButton.backgroundColor = .black
            focusButton.setTitleColor(.white, for: .normal)
            focusButton.layer.borderColor = UIColor.white.cgColor
            focusButton.accessibilityTraits.remove(.selected)
        }
        
        layoutApertureCircle()
        print("Focus toggled: \(isFocusToggled), aperture: \(depthProcessor.apertureSize)")
    }
    
    @objc private func onDescribeKeyItemPressed() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        hapticManager.fireTransientPulse(intensity: 0.5, sharpness: 0.5)
        
        pendingAnalysisPrompt = "Analyze the object held or pointed at.\n\nVisuals: Describe color, shape, and material in under 15 words.\n\nText: Read prominent text verbatim.\nConstraint: Use telegraphic style (no articles, no filler). Always include visual description."
        
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        settings.isDepthDataDeliveryEnabled = false // No depth needed for Gemini
        settings.embedsDepthDataInPhoto = false
        photoOutput.capturePhoto(with: settings, delegate: self)
        
        showAnalysisOverlay(text: "Analyzing...")
    }
    
    @objc private func onDescribeBackgroundPressed() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        hapticManager.fireTransientPulse(intensity: 0.5, sharpness: 0.5)
        
        pendingAnalysisPrompt = "Scan immediate surroundings. Output phrases separated by periods:\n\nContext: Identify setting and main contents (e.g. 'kitchen, dirty dishes').\n\nHazards: List immediate obstacles (left/right/center).\n\nNavigation: Describe the path ahead ONLY if a clear, open route is visible.\nConstraint: Telegraphic style. Max 30 words total."
        
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed
        settings.isDepthDataDeliveryEnabled = false
        settings.embedsDepthDataInPhoto = false
        photoOutput.capturePhoto(with: settings, delegate: self)
        
        showAnalysisOverlay(text: "Analyzing...")
    }
    
    private func setupAnalysisUI() {
        // Create a container view for the overlay
        analysisOverlay = UIView()
        analysisOverlay.translatesAutoresizingMaskIntoConstraints = false
        analysisOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        analysisOverlay.layer.cornerRadius = 16
        analysisOverlay.layer.borderWidth = 2
        analysisOverlay.layer.borderColor = UIColor.white.cgColor
        analysisOverlay.alpha = 0
        view.addSubview(analysisOverlay)
        
        // Create the label for the result
        analysisResultLabel = UILabel()
        analysisResultLabel.translatesAutoresizingMaskIntoConstraints = false
        analysisResultLabel.textColor = .white
        analysisResultLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        analysisResultLabel.numberOfLines = 0
        analysisResultLabel.textAlignment = .center
        // VoiceOver should treat this as a prominent announcement
        analysisResultLabel.accessibilityTraits = [.staticText, .header]
        analysisOverlay.addSubview(analysisResultLabel)
        
        NSLayoutConstraint.activate([
            analysisOverlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            analysisOverlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            analysisOverlay.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40),
            analysisOverlay.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.6),
            
            analysisResultLabel.topAnchor.constraint(equalTo: analysisOverlay.topAnchor, constant: 24),
            analysisResultLabel.bottomAnchor.constraint(equalTo: analysisOverlay.bottomAnchor, constant: -24),
            analysisResultLabel.leadingAnchor.constraint(equalTo: analysisOverlay.leadingAnchor, constant: 24),
            analysisResultLabel.trailingAnchor.constraint(equalTo: analysisOverlay.trailingAnchor, constant: -24)
        ])
        
        // Add tap to dismiss
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissAnalysisOverlay))
        analysisOverlay.addGestureRecognizer(tap)
    }
    
    private func showAnalysisOverlay(text: String) {
        // Update UI on main thread
        DispatchQueue.main.async {
            self.analysisResultLabel.text = text
            self.analysisOverlay.isHidden = false
            
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5, options: [], animations: {
                self.analysisOverlay.alpha = 1.0
                self.analysisOverlay.transform = .identity
            }, completion: { _ in
                // Move VoiceOver focus to the result label and read it
                UIAccessibility.post(notification: .layoutChanged, argument: self.analysisResultLabel)
            })
        }
    }
    
    @objc private func dismissAnalysisOverlay() {
        UIView.animate(withDuration: 0.2, animations: {
            self.analysisOverlay.alpha = 0
            self.analysisOverlay.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }) { _ in
            self.analysisOverlay.isHidden = true
            self.analysisResultLabel.text = ""
            self.isAnalyzing = false
        }
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
        // Reset to default depth range (Medium)
        currentDepthLevelIndex = 1
        updateDepthRangeToCurrentLevel()
        print("Reset depth range to default values")
    }
    
    private func updateDepthRangeToCurrentLevel() {
        let level = DepthLevels.all[currentDepthLevelIndex]
        depthProcessor.minDisparity = level.min
        depthProcessor.maxDisparity = level.max
        
        // Update sliders if in tuning mode
        if FeatureFlags.tuningMode {
            minSlider.value = level.min
            maxSlider.value = level.max
            updateDisparityLabelsAndHint()
        }
        
        print("Depth level changed to index \(currentDepthLevelIndex): \(level.min)m - \(level.max)m")
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
        let result = surfaceAnalyzer.analyze(depthMap: processedDepthMap, apertureSize: depthProcessor.apertureSize,
                                              rangeMin: depthProcessor.minDisparity, rangeMax: depthProcessor.maxDisparity)
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
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                    didFinishProcessingPhoto photo: AVCapturePhoto,
                    error: Error?) {

        if let error = error {
            print("Error capturing photo: \(error.localizedDescription)")
            if isAnalyzing {
                showAnalysisOverlay(text: "Error capturing image.")
                isAnalyzing = false
            }
            return
        }

        // Capture state on main thread (or whatever thread callback is on)
        let prompt = pendingAnalysisPrompt
        if prompt != nil {
            pendingAnalysisPrompt = nil
        }
        
        // Move heavy processing (data extraction + image decoding) to background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                print("Could not get photo data.")
                if self.isAnalyzing {
                    self.showAnalysisOverlay(text: "Could not capture image data.")
                    DispatchQueue.main.async { self.isAnalyzing = false }
                }
                return
            }

            // Check if this capture is for Gemini analysis
            if let prompt = prompt {
                // Perform analysis
                GeminiService.shared.generateContent(prompt: prompt, image: image) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        
                        switch result {
                        case .success(let text):
                            self.showAnalysisOverlay(text: text)
                            // Haptic feedback for success
                            self.hapticManager.fireTransientPulse(intensity: 1.0, sharpness: 0.8)
                            
                        case .failure(let error):
                            let errorMsg: String
                            switch error {
                            case .noAPIKey:
                                errorMsg = "API Key missing. Please add it to Config.swift."
                            case .networkError(let err):
                                errorMsg = "Network error: \(err.localizedDescription)"
                            case .apiError(let msg):
                                errorMsg = "Gemini Error: \(msg)"
                            default:
                                errorMsg = "Analysis failed. Please try again."
                            }
                            self.showAnalysisOverlay(text: errorMsg)
                            // We keep isAnalyzing = true so the user sees the error overlay
                        }
                    }
                }
                return
            }

            // Normal photo capture flow (save to library)
            // Log depth data info if available
            if let depth = photo.depthData {
                self.logDepthInfo(depth)
            } else {
                print("No depth data in this photo.")
            }

            // Save to photo library
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            print("Photo saved to library.")
        }
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
