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
    func gestureManagerDidDoubleTap(_ manager: GestureManager)
    func gestureManagerDidSwipeUp(_ manager: GestureManager)
    func gestureManagerDidSwipeDown(_ manager: GestureManager)
    func gestureManagerDidBeginPress(_ manager: GestureManager)
    func gestureManagerDidEndPress(_ manager: GestureManager)
}

/// Manages tap gestures and focus indicator animations
class GestureManager {

    // MARK: - Properties

    weak var delegate: GestureManagerDelegate?

    private var focusIndicator: UIView!
    private weak var parentView: UIView?

    // MARK: - Edge Holding State

    /// Configurable margin from screen edge to detect edge holds (in points)
    var edgeMargin: CGFloat = 100.0

    /// Current edge holding states (can be queried at any time)
    private(set) var isHoldingLeftEdge: Bool = false
    private(set) var isHoldingRightEdge: Bool = false
    private(set) var isHoldingTopEdge: Bool = false
    private(set) var isHoldingBottomEdge: Bool = false

    // Edge visual indicators
    private var leftEdgeIndicator: UIView!
    private var rightEdgeIndicator: UIView!
    private var topEdgeIndicator: UIView!
    private var bottomEdgeIndicator: UIView!

    // MARK: - Initialization

    init(parentView: UIView) {
        self.parentView = parentView
        setupFocusIndicator()
        setupEdgeIndicators()
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

    private func setupEdgeIndicators() {
        guard let parentView = parentView else { return }

        let indicatorColor = UIColor.white.withAlphaComponent(0.2)

        // Left edge indicator
        leftEdgeIndicator = UIView()
        leftEdgeIndicator.backgroundColor = indicatorColor
        leftEdgeIndicator.alpha = 0
        leftEdgeIndicator.isUserInteractionEnabled = false
        parentView.addSubview(leftEdgeIndicator)

        // Right edge indicator
        rightEdgeIndicator = UIView()
        rightEdgeIndicator.backgroundColor = indicatorColor
        rightEdgeIndicator.alpha = 0
        rightEdgeIndicator.isUserInteractionEnabled = false
        parentView.addSubview(rightEdgeIndicator)

        // Top edge indicator
        topEdgeIndicator = UIView()
        topEdgeIndicator.backgroundColor = indicatorColor
        topEdgeIndicator.alpha = 0
        topEdgeIndicator.isUserInteractionEnabled = false
        parentView.addSubview(topEdgeIndicator)

        // Bottom edge indicator
        bottomEdgeIndicator = UIView()
        bottomEdgeIndicator.backgroundColor = indicatorColor
        bottomEdgeIndicator.alpha = 0
        bottomEdgeIndicator.isUserInteractionEnabled = false
        parentView.addSubview(bottomEdgeIndicator)
    }

    /// Update edge indicator frames based on parent view bounds
    func updateEdgeIndicatorFrames() {
        guard let parentView = parentView else { return }
        let bounds = parentView.bounds
        let thickness: CGFloat = 12.0

        leftEdgeIndicator.frame = CGRect(x: 0, y: 0, width: thickness, height: bounds.height)
        rightEdgeIndicator.frame = CGRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height)
        topEdgeIndicator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: thickness)
        bottomEdgeIndicator.frame = CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
    }

    /// Adds gesture recognizers to the specified view
    func addGestures(to view: UIView) {
        // Single tap gesture
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.numberOfTapsRequired = 1
        view.addGestureRecognizer(tapGesture)

        // Double tap gesture
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTapGesture)

        // Require double tap to fail before single tap fires (prevents both from firing)
        tapGesture.require(toFail: doubleTapGesture)
        
        // Swipe up gesture
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp(_:)))
        swipeUp.direction = .up
        view.addGestureRecognizer(swipeUp)
        
        // Swipe down gesture
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown(_:)))
        swipeDown.direction = .down
        view.addGestureRecognizer(swipeDown)
        
        // Press gesture (immediate)
        let pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        pressGesture.minimumPressDuration = 0
        view.addGestureRecognizer(pressGesture)
    }

    // MARK: - Touch Tracking

    /// Call this from touchesBegan/touchesMoved to update edge holding state
    func updateTouchState(touches: Set<UITouch>, in view: UIView) {
        guard let parentView = parentView else { return }
        let bounds = parentView.bounds

        // Reset all states
        var leftHeld = false
        var rightHeld = false
        var topHeld = false
        var bottomHeld = false

        // Check all active touches
        for touch in touches {
            let location = touch.location(in: view)

            // Check each edge
            if location.x <= edgeMargin {
                leftHeld = true
            }
            if location.x >= bounds.width - edgeMargin {
                rightHeld = true
            }
            if location.y <= edgeMargin {
                topHeld = true
            }
            if location.y >= bounds.height - edgeMargin {
                bottomHeld = true
            }
        }

        // Update states and visual feedback
        updateEdgeState(left: leftHeld, right: rightHeld, top: topHeld, bottom: bottomHeld)
    }

    /// Call this from touchesEnded/touchesCancelled to clear edge holding state
    func clearTouchState() {
        updateEdgeState(left: false, right: false, top: false, bottom: false)
    }

    private func updateEdgeState(left: Bool, right: Bool, top: Bool, bottom: Bool) {
        // Update left edge
        if isHoldingLeftEdge != left {
            isHoldingLeftEdge = left
            UIView.animate(withDuration: 0.05) {
                self.leftEdgeIndicator.alpha = left ? 1.0 : 0.0
            }
        }

        // Update right edge
        if isHoldingRightEdge != right {
            isHoldingRightEdge = right
            UIView.animate(withDuration: 0.05) {
                self.rightEdgeIndicator.alpha = right ? 1.0 : 0.0
            }
        }

        // Update top edge
        if isHoldingTopEdge != top {
            isHoldingTopEdge = top
            UIView.animate(withDuration: 0.05) {
                self.topEdgeIndicator.alpha = top ? 1.0 : 0.0
            }
        }

        // Update bottom edge
        if isHoldingBottomEdge != bottom {
            isHoldingBottomEdge = bottom
            UIView.animate(withDuration: 0.05) {
                self.bottomEdgeIndicator.alpha = bottom ? 1.0 : 0.0
            }
        }
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

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Notify delegate (no visual feedback needed for reset)
        delegate?.gestureManagerDidDoubleTap(self)
    }
    
    @objc private func handleSwipeUp(_ gesture: UISwipeGestureRecognizer) {
        delegate?.gestureManagerDidSwipeUp(self)
    }
    
    @objc private func handleSwipeDown(_ gesture: UISwipeGestureRecognizer) {
        delegate?.gestureManagerDidSwipeDown(self)
    }
    
    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            delegate?.gestureManagerDidBeginPress(self)
        case .ended, .cancelled, .failed:
            delegate?.gestureManagerDidEndPress(self)
        default:
            break
        }
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
