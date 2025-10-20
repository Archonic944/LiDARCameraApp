# LiDAR Camera App

An iOS application that displays a real-time LiDAR depth overlay on the camera preview using object-oriented architecture.

## Overview

This app uses the iPhone/iPad's LiDAR sensor to capture depth data and display it as a colored overlay on top of the camera feed. Objects are color-coded based on distance:
- **Red**: Close objects (high disparity)
- **Blue**: Far objects (low disparity)

## Architecture

The app follows OOP principles with clear separation of concerns:

```
┌──────────────────────────┐
│ CameraViewController     │  ← UI & Coordination
├──────────────────────────┤
│ - Camera setup           │
│ - Session management     │
│ - Delegate coordination  │
└───────┬──────────────────┘
        │ uses
        ├───────────┬──────────────┬──────────────────┬──────────────────┐
        │           │              │                  │                  │
┌───────▼─────┐  ┌─▼────────────┐ ┌▼─────────────┐  ┌▼─────────────────┐ ┌▼─────────────┐
│ Depth       │  │ Depth        │ │ Edge         │  │ Gesture          │ │ Haptic       │
│ Processor   │  │ Visualizer   │ │ Detector     │  │ Manager          │ │ Feedback Mgr │
├─────────────┤  ├──────────────┤ ├──────────────┤  ├──────────────────┤ ├──────────────┤
│ - Convert   │  │ - Color map  │ │ - Edge index │  │ - Tap/double tap │ │ - Continuous │
│ - Normalize │  │ - Orient     │ │ - Gradients  │  │ - Focus UI       │ │   vibration  │
│ - Calibrate │  │ - Scale/crop │ │ - Eigenvalue │  │ - Delegate       │ │ - Dynamic    │
│ - Sample    │  │ - Render     │ │ - NMS        │  │   pattern        │ │   intensity  │
└─────────────┘  └──────────────┘ └──────────────┘  └──────────────────┘ └──────────────┘
```

## Key Components

### CameraViewController.swift
**Responsibility**: UI coordination and camera session management

The main view controller that:
- Manages AVCaptureSession lifecycle
- Handles camera permissions
- Coordinates between depth processor and visualizer
- Updates UI with processed depth frames
- Handles photo capture

**Key Design Patterns**:
- Uses protocol extensions for AVCaptureDepthDataOutputDelegate and AVCapturePhotoCaptureDelegate
- Private methods for clear separation of setup responsibilities
- Weak self references to prevent retain cycles
- MARK comments for code organization

### DepthProcessor.swift
**Responsibility**: Depth data processing, normalization, and calibration

Handles:
- Converting AVDepthData to 32-bit float disparity format
- Normalizing depth values to 0-1 range using fixed disparity range
- CVPixelBuffer manipulation
- Center aperture sampling for haptic feedback
- **Tap-to-calibrate range adjustment**

**Key Features**:
- Extension on CVPixelBuffer for reusable normalization
- Fixed range normalization for consistent depth visualization
- Configurable min/max disparity values (default: 0.2 to 4.0)
- Thread-safe operations
- `calibrateRange()` method for dynamic range adjustment

**Normalization Strategy**:
- Uses **fixed range normalization** instead of per-frame min/max
- Ensures consistent color mapping across frames
- Objects at the same distance always show the same color
- Values outside range are clamped to 0-1
- Default range: minDisparity=0.2 (~5m), maxDisparity=4.0 (~0.25m)

**Calibration Method**:
- `calibrateToCurrentFrame(from:)` analyzes entire depth frame
- `calculatePercentiles(from:)` helper extracts valid values, sorts, and computes P5/P95
- Sets new min/max range based on scene statistics
- Ensures minimum range of 0.1 to avoid division by zero

### DepthVisualizer.swift
**Responsibility**: Rendering depth data as visual overlays

Manages:
- False color mapping (configurable colors)
- Orientation transforms for device rotation
- Aspect-fill scaling and cropping
- CGImage rendering

**Key Features**:
- Encapsulates all Core Image operations
- Configurable color scheme (farColor, nearColor properties)
- Reusable CIContext for performance
- Private helper methods for single-responsibility functions

### EdgeDetector.swift
**Responsibility**: Real-time edge detection in depth maps

Implements Xia & Wang (2017) algorithm for extracting geometric discontinuities (edges) from LiDAR depth data.

**Algorithm Overview**:
The Xia2017 algorithm detects edges by measuring how each point is displaced from its local geometric centroid, then analyzing how these displacements change spatially to define gradients. A gradient matrix M is constructed from gradient products and smoothed with a Gaussian kernel. Edge detection uses the eigenvalue ratio Tr(M)³/Det(M): when eigenvalues are large, this ratio exceeds a threshold, identifying edge candidates. Non-maximum suppression thins edges to single-pixel width.

**Implementation Details**:
- Adapted for iPhone LiDAR's organized depth maps (2.5D) rather than unorganized 3D point clouds
- Neighborhood radius: 5 pixels (reduced from paper's 0.15m)
- Minimum neighbors: 15 (reduced from paper's 30)
- Processes in pixel space (x, y, depth) for efficiency
- Gaussian smoothing: σ=1.0, 2-pixel radius
- Eigenvalue threshold: 80 (lowered from 100 for mobile data sensitivity)
- Outputs normalized edge strength map (0-1 range) as CVPixelBuffer

**Processing Steps**:
1. Calculate edge index (displacement from local centroid) for all pixels
2. Compute 3D gradients (Ix, Iy, Iz) based on edge index differences
3. Build and smooth gradient matrix M
4. Detect edges using eigenvalue ratio analysis
5. Apply non-maximum suppression along gradient direction

### GestureManager.swift
**Responsibility**: Touch gesture handling and visual feedback

Manages:
- Single and double tap gesture recognition
- Focus indicator UI (yellow square)
- Smooth animations (scale + fade)
- Delegate pattern for gesture events

**Key Features**:
- Protocol-based communication (`GestureManagerDelegate`)
- Single tap: triggers depth range calibration
- Double tap: resets to default depth range
- Reusable across different views
- Camera-like focus indicator animation
- Proper gesture conflict resolution (single tap waits for double tap to fail)

### HapticFeedbackManager.swift
**Responsibility**: Continuous haptic feedback based on proximity

Manages:
- Core Haptics engine lifecycle
- Continuous vibration pattern
- Dynamic intensity updates
- Engine recovery from interruptions

**Key Features**:
- Walking stick metaphor: haptic "echolocation" for environment sensing
- Continuous vibration that never stops (while active)
- Intensity varies with object proximity (closer = stronger)
- Automatic engine restart on interruptions
- Configurable intensity range

## Technical Details

### Depth Data Processing Pipeline

1. **Capture**: AVCaptureDepthDataOutput streams depth frames from LiDAR camera
2. **Process** (DepthProcessor):
   - Convert to 32-bit floating-point disparity format
   - Normalize depth values to 0-1 range using fixed disparity range (0.2 to 4.0)
   - Values are clamped to ensure consistent visualization across frames
   - Sample center aperture for haptic feedback
3. **Edge Detection** (EdgeDetector):
   - Detect geometric discontinuities using Xia2017 algorithm
   - Calculate edge indices (displacement from local centroid)
   - Compute 3D gradients and build gradient matrix
   - Apply eigenvalue ratio analysis for edge detection
   - Non-maximum suppression for clean edges
   - Store edge map for future use
4. **Haptic Feedback** (HapticFeedbackManager):
   - Receive average center depth (0.0 = far, 1.0 = close)
   - Update continuous vibration intensity
   - Stronger vibration for closer objects
5. **Visualize** (DepthVisualizer):
   - Apply false color filter (blue→red gradient)
   - Apply orientation transform
   - Scale and crop to screen size
   - Render to CGImage
6. **Display**: Update UIImageView on main thread

### Orientation Handling

The depth data comes in landscape orientation by default. The DepthVisualizer uses `CIImage.oriented()` to properly rotate the depth map:
- Portrait: `.up`
- Portrait Upside Down: `.down`
- Landscape Right: `.right`
- Landscape Left: `.left`

The oriented image is then translated to origin to ensure correct extent coordinates for subsequent operations.

### Haptic Echolocation System

The haptic feedback system acts like a "walking stick for the blind":

**How It Works**:
- Continuously samples a small center "aperture" (15% of frame)
- Averages depth values in that region
- Maps depth to vibration intensity (0-100%)
- Updates haptic engine in real-time

**Technical Implementation**:
- Uses Core Haptics for precise control
- Continuous haptic pattern (30s max duration per Apple's limit)
- Auto-renewal system: restarts pattern every 28s for truly infinite vibration
- Handles engine interruptions (backgrounding, calls)
- Intensity and sharpness modulation
- Timer-based renewal to work around Core Haptics 30s continuous event limit

**Aperture Sampling**:
```
┌─────────────────────┐
│                     │
│   ┌───────────┐     │
│   │ Aperture  │     │  ← 15% of frame
│   │  Region   │     │     centered
│   └───────────┘     │
│                     │
└─────────────────────┘
```

Average depth in this region determines vibration strength.

### Performance Optimizations

- Depth processing runs on background queue (`com.gabe.depthQueue`)
- UI updates dispatched to main thread using `@MainActor`
- Depth filtering enabled for smoother visualization
- Reusable CIContext to avoid repeated initialization
- In-place pixel buffer normalization
- Haptic updates throttled by depth frame rate (~30fps)

## Code Organization

### MARK Regions in CameraViewController
- **Properties**: Component instances and state
- **Lifecycle**: viewDidLoad, viewWillLayoutSubviews
- **Setup**: UI and component initialization
- **Camera Permission**: Authorization flow
- **Camera Setup**: Session configuration (broken into focused methods)
- **Photo Capture**: Still photo handling

### Modular Setup Methods
- `getCameraDevice()`: Device selection
- `configurePhotoOutput()`: Photo output configuration
- `configureDepthOutput()`: Depth output configuration
- `setupPreviewLayer()`: Preview layer setup

This structure makes the code easier to test, modify, and understand.

## Features

- ✅ Real-time LiDAR depth overlay
- ✅ Color-coded depth visualization with fixed range normalization
- ✅ **Real-time edge detection** using Xia2017 algorithm
- ✅ **Tap-to-calibrate depth range** (single tap)
- ✅ **Double-tap to reset** depth range to defaults
- ✅ Consistent depth mapping (same distance = same color across frames)
- ✅ **Continuous haptic feedback** (walking stick metaphor)
- ✅ Proximity-based vibration intensity
- ✅ Object-oriented architecture with separation of concerns
- ✅ Proper orientation handling for all device orientations
- ✅ Photo capture with embedded depth data
- ✅ Transparent overlay (80% opacity) to see camera feed
- ✅ Configurable color schemes (via DepthVisualizer properties)
- ✅ Configurable depth range (via DepthProcessor min/maxDisparity properties)
- ✅ Automatic haptic engine recovery from interruptions
- ✅ Visual focus indicator with smooth animations

## Requirements

- iOS device with LiDAR sensor (iPhone 12 Pro or later, iPad Pro 2020 or later)
- iOS 14.0+
- Camera and depth data permissions

## Known Issues

None currently.

## Technical Notes

### Edge Detection (Xia2017)
The app implements real-time edge detection based on Xia & Wang's 2017 paper "A Fast Edge Extraction Method for Mobile Lidar Point Clouds."

**How It Works**:
1. **Edge Index**: For each pixel, calculate displacement from local geometric centroid (nearby pixels)
2. **Gradients**: Compute 3D gradients (Ix, Iy, Iz) based on how edge indices change spatially
3. **Gradient Matrix**: Build matrix M from gradient products (Ix², IxIy, IxIz, etc.)
4. **Gaussian Smoothing**: Smooth M to prevent singularities (Det(M) = 0)
5. **Eigenvalue Analysis**: Calculate ratio Tr(M)³/Det(M); high values indicate edges
6. **Non-Maximum Suppression**: Thin edges to single-pixel width along gradient direction

**Key Insight**: Edges (surface boundaries and intersections) have large eigenvalues in their gradient distributions. The trace/determinant ratio amplifies this signal without computing expensive SVD.

**Adaptations for Mobile**:
- Smaller neighborhoods (5px radius vs 0.15m) for lower resolution depth maps
- Pixel-space processing (x, y, depth) instead of full 3D world coordinates
- Fixed Gaussian parameters for consistent real-time performance
- Lower threshold (80 vs 100) for noisier mobile LiDAR data

**Output**: Normalized edge strength map (CVPixelBuffer, 0-1 range) cached in `latestEdgeMap`

## Technical Notes (Continued)

### Tap-to-Calibrate Depth Range
The app supports scene-adaptive depth range calibration using statistical analysis:

**How It Works**:
1. Tap anywhere on the screen (location is irrelevant - just a trigger)
2. App analyzes the **entire depth frame** statistically
3. Calculates 5th percentile (P5) and 95th percentile (P95) of all valid depth values
4. Sets `minDisparity = P5` and `maxDisparity = P95`
5. Shows a yellow focus indicator animation for visual feedback

**Statistical Approach**:
- **Percentile-based outlier rejection**: Uses P5 and P95 instead of min/max
- **Robust to noise**: Ignores extreme outliers and invalid readings
- **Scene-adaptive**: Range automatically fits whatever is currently visible
- **No spatial coupling**: Tap location doesn't matter - full frame is analyzed

**Implementation Details**:
- `GestureManager` handles tap detection and visual feedback
- `CameraViewController` implements `GestureManagerDelegate`
- `DepthProcessor.calibrateToCurrentFrame()` performs statistical analysis
- `calculatePercentiles()` scans entire buffer, filters invalid values, sorts, and extracts P5/P95
- Caches latest `AVDepthData` frame in CameraViewController
- Focus indicator uses UIView animations (scale + fade)
- Clean separation: UI (GestureManager) → Controller → Logic (DepthProcessor)

**Use Case**: Point camera at a scene, tap anywhere to "lock in" the depth range. All objects in view will be spread across the full color spectrum, ignoring outliers.

### Core Haptics Continuous Event Limitation
Core Haptics has a **30-second maximum duration** for continuous haptic events (`CHHapticEvent` with `.hapticContinuous` type). To achieve truly infinite vibration for the walking stick metaphor, the app implements an auto-renewal system:

1. Creates a 30-second continuous haptic pattern
2. Schedules a timer to restart the pattern every 28 seconds
3. Seamlessly transitions between patterns for uninterrupted feedback

This workaround is necessary because setting a longer duration (e.g., 3600s) will cause the haptic to stop after 30 seconds despite the specified value.

## Future Enhancements

### Haptic Improvements
- Multiple aperture regions for directional feedback
- Different vibration patterns for different distance ranges
- Customizable aperture size and position
- Audio feedback option alongside haptics
- Haptic strength calibration slider

### Visualization
- UI controls for color scheme selection
- Recording video with depth overlay
- 3D point cloud visualization
- Depth map export (as image or data file)
- Display actual distance values on screen (convert disparity to meters)
- Customizable percentile thresholds (currently P5/P95)
- Double-tap to reset to default range
- Histogram visualization of depth distribution

### Code Quality
- Unit tests for DepthProcessor, DepthVisualizer, and HapticFeedbackManager
- Dependency injection for better testability
- Performance profiling and optimization
