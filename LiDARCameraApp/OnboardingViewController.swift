//
//  OnboardingViewController.swift
//  LiDARCameraApp
//
//  Onboarding flow for first-time users. Designed for VoiceOver.
//

import UIKit
import AVFoundation

class OnboardingViewController: UIViewController {

    // MARK: - Properties

    private var pages: [(title: String, body: String)] = []
    private var currentPage = 0

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let nextButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let pageIndicatorLabel = UILabel()

    private var hasLiDAR: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildPages()
        setupUI()
        showPage(0)
    }

    // MARK: - Pages

    private func buildPages() {
        if !hasLiDAR {
            pages = [(
                title: "LiDAR Required",
                body: "PocketCane requires a LiDAR sensor, which this device does not have. LiDAR is available on iPhone 12 Pro and later Pro models, and iPad Pro (2020 and later). Please run this app on a supported device."
            )]
            return
        }

        pages = [
            (
                title: "Welcome to PocketCane",
                body: "PocketCane mimics the physical sensation of using a white cane. It turns your phone's LiDAR sensor into a tool you can sweep around to feel your surroundings through vibration."
            ),
            (
                title: "Important Safety Information",
                body: "PocketCane is a tool, not a safety device. It requires significant practice and will not guarantee your safety.\n\nDo not use PocketCane as your primary means of obstacle avoidance. You are responsible for your safety at all times."
            ),
            (
                title: "How It Works",
                body: "Hold your phone upright, as if taking a photo. Do not cover the camera.\n\nA constant vibration tells you how far away things are. Stronger vibration means closer. Use the \"Shorten\" and \"Lengthen\" buttons to adjust the detection range—your virtual white cane."
            ),
            (
                title: "Clicks and Boundaries",
                body: "When the camera passes over a boundary—like the edge of an object or a wall corner—you'll feel a \"click.\"\n\nSweep your phone in three dimensions, covering the area in front of your body. Think of it like shining a flashlight in the dark."
            ),
            (
                title: "Practice Makes Perfect",
                body: "Start in a familiar area and point PocketCane at objects of various distances. Experiment with different sweeping techniques to find what works for you.\n\nUsing PocketCane means building a mental model of your surroundings. With practice, you'll be an expert."
            ),
            (
                title: "AI Features",
                body: "Two additional buttons, \"Key Item\" and \"Environment,\" both require internet access.\n\n\"Key Item\" briefly describes what you're holding or pointing at—text, color, shape, and size.\n\n\"Environment\" gives a brief overview of your surroundings. Keep your phone aligned with your body when using it."
            ),
            (
                title: "Happy Navigating!",
                body: "You're all set. Remember: practice in safe, familiar spaces before relying on PocketCane elsewhere.\n\nTap \"Get Started\" to begin."
            ),
        ]
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .black

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = UIFont.preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        // Body
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.textColor = .white
        bodyLabel.font = UIFont.preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center
        view.addSubview(bodyLabel)

        // Page indicator
        pageIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        pageIndicatorLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        pageIndicatorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        pageIndicatorLabel.textAlignment = .center
        view.addSubview(pageIndicatorLabel)

        // Back button
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle("Back", for: .normal)
        backButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title3)
        backButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        backButton.setTitleColor(.white, for: .normal)
        backButton.layer.cornerRadius = 12
        backButton.addTarget(self, action: #selector(onBack), for: .touchUpInside)
        view.addSubview(backButton)

        // Next button
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title3)
        nextButton.titleLabel?.adjustsFontForContentSizeCategory = true
        nextButton.backgroundColor = .white
        nextButton.setTitleColor(.black, for: .normal)
        nextButton.layer.cornerRadius = 12
        nextButton.addTarget(self, action: #selector(onNext), for: .touchUpInside)
        view.addSubview(nextButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            bodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            pageIndicatorLabel.bottomAnchor.constraint(equalTo: backButton.topAnchor, constant: -16),
            pageIndicatorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            backButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 56),
            backButton.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.35),

            nextButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            nextButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            nextButton.heightAnchor.constraint(equalToConstant: 56),
            nextButton.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.55),
        ])
    }

    // MARK: - Navigation

    private func showPage(_ index: Int) {
        currentPage = index
        let page = pages[index]

        titleLabel.text = page.title
        bodyLabel.text = page.body

        let isFirst = index == 0
        let isLast = index == pages.count - 1
        let isLiDARError = !hasLiDAR

        // Back button
        backButton.isHidden = isFirst || isLiDARError
        backButton.accessibilityLabel = "Back"

        // Next button
        if isLiDARError {
            nextButton.setTitle("Close App", for: .normal)
            nextButton.accessibilityLabel = "Close app. LiDAR is required."
        } else if isLast {
            nextButton.setTitle("Get Started", for: .normal)
            nextButton.accessibilityLabel = "Get started and begin using PocketCane"
        } else {
            nextButton.setTitle("Next", for: .normal)
            nextButton.accessibilityLabel = "Next page"
        }

        // Page indicator
        if isLiDARError {
            pageIndicatorLabel.isHidden = true
        } else {
            pageIndicatorLabel.isHidden = false
            pageIndicatorLabel.text = "\(index + 1) of \(pages.count)"
        }

        // Move VoiceOver focus to title so the page is read aloud
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    // MARK: - Actions

    @objc private func onNext() {
        if !hasLiDAR {
            // Suspend the app (go to home screen). We can't truly "close" an iOS app.
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            return
        }

        if currentPage < pages.count - 1 {
            showPage(currentPage + 1)
        } else {
            finishOnboarding()
        }
    }

    @objc private func onBack() {
        if currentPage > 0 {
            showPage(currentPage - 1)
        }
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        dismiss(animated: true)
    }
}
