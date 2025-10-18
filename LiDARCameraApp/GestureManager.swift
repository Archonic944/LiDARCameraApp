//
//  GestureManager.swift
//  LiDARCameraApp
//
//  Manages touch gestures and visual feedback
//

import UIKit

/// Protocol for gesture events
protocol GestureManagerDelegate: AnyObject {
    func gestureManager(_ manager: GestureManager, didTapAt point: CGPoint)
}

/// Manages tap gestures and focus indicator animations
class GestureManager {

    // MARK: - Properties

    weak var delegate: GestureManagerDelegate?

    private var focusIndicator: UIView!
    private weak var parentView: UIView?

    // MARK: - Initialization

    init(parentView: UIView) {
        self.parentView = parentView
        setupFocusIndicator()
    }

    // MARK: - Setup

    private func setupFocusIndicator() {
        guard let parentView = parentView else { return }

        focusIndicator = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        focusIndicator.layer.borderColor = UIColor.systemYellow.cgColor
        focusIndicator.layer.borderWidth = 2
        focusIndicator.backgroundColor = .clear
        focusIndicator.isHidden = true
        parentView.addSubview(focusIndicator)
    }

    /// Adds tap gesture recognizer to the specified view
    func addTapGesture(to view: UIView) {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
    }

    // MARK: - Gesture Handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        let tapPoint = gesture.location(in: view)

        // Show visual feedback
        showFocusIndicator(at: tapPoint)

        // Notify delegate
        delegate?.gestureManager(self, didTapAt: tapPoint)
    }

    // MARK: - Visual Feedback

    private func showFocusIndicator(at point: CGPoint) {
        focusIndicator.center = point
        focusIndicator.isHidden = false
        focusIndicator.alpha = 0
        focusIndicator.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)

        UIView.animate(withDuration: 0.3, animations: {
            self.focusIndicator.alpha = 1.0
            self.focusIndicator.transform = .identity
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0.5, animations: {
                self.focusIndicator.alpha = 0
            }) { _ in
                self.focusIndicator.isHidden = true
            }
        }
    }
}
