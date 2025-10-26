# LiDAR Camera App

An iOS application that displays a real-time LiDAR depth overlay on the camera preview using object-oriented architecture.

## Overview

This app uses the iPhone/iPad's LiDAR sensor to capture depth data and display it as a colored overlay on top of the camera feed. Objects are color-coded based on distance:
- **Red**: Close objects (high proximity, low meter values)
- **Blue**: Far objects (low proximity, high meter values)

## IMPORTANT: Code Modification Guidelines

**⚠️ DO NOT change hardcoded calibration values unless explicitly requested by the user.**

The default depth range values (e.g., `defaultMinDepth = 1.321`, `defaultMaxDepth = 1.639`) are **carefully tuned and calibrated** for specific use cases. These values may seem arbitrary but have been empirically determined. Do not suggest "sensible" or "standard" values (like 0.5m to 5.0m) as replacements without explicit user request.

When modifying code:
- **Preserve** existing numeric constants unless asked to change them
- **Ask** before suggesting value changes that seem more "intuitive"
- **Respect** that unusual values (like 1.321m) are intentionally calibrated

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
┌───────▼─────┐  ┌─▼────────────┐ ┌▼──────────────┐  ┌▼─────────────────┐ ┌▼─────────────┐
│ Depth       │  │ Depth        │ │ EdgeDetector │  │ Gesture          │ │ Haptic       │
│ Processor   │  │ Visualizer   │ │ GPU          │  │ Manager          │ │ Feedback Mgr │
├─────────────┤  ├──────────────┤ ├──────────────┤  ├──────────────────┤ ├──────────────┤
│ - Convert   │  │ - Color map  │ │ - Depth Sobel│  │ - Tap/double tap │ │ - Continuous │
│ - Normalize │  │ - Orient     │ │ - Amplify    │  │ - Focus UI       │ │   vibration  │
│ - Calibrate │  │ - Scale/crop │ │ - Threshold  │  │ - Delegate       │ │ - Dynamic    │
│ - Sample    │  │ - Render     │ │ - GPU/Metal  │  │   pattern        │ │   intensity  │
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
**Responsibility**: Depth data processing and calibration (preserves raw meter values)

Handles:
- Converting AVDepthData to 32-bit float **depth format (meters, not disparity!)**
- **Preserving raw meter values** throughout pipeline
- CVPixelBuffer manipulation
- Center aperture sampling for haptic feedback (returns meters)
- **Tap-to-calibrate range adjustment**
- On-demand conversion from meters to proximity (0-1)

**Key Features**:
- Extension on CVPixelBuffer for `convertMetersToProximity()` (creates new buffer, non-destructive)
- Fixed range for consistent depth visualization
- Configurable min/max depth values in meters (default: `defaultMinDepth = 1.321m`, `defaultMaxDepth = 1.639m`)
- Thread-safe operations
- `metersToProximity()` helper for single-value conversion
- `calibrateToCurrentFrame()` method for dynamic range adjustment

**Data Preservation Strategy**:
- **Does NOT mutate original depth buffers** - raw meter values preserved
- `processDepthData()` returns CVPixelBuffer with Float32 meter values
- Proximity conversion happens **on-demand** in DepthVisualizer and for haptics
- All downstream components can access real-world measurements

**Proximity Conversion** (0-1 range):
- **0.0 = far** (at or beyond maxDepth)
- **1.0 = close** (at or below minDepth)
- Formula: `proximity = 1.0 - clamp((meters - minDepth) / (maxDepth - minDepth))`
- Used for visualization (color mapping) and haptic feedback (intensity)

**Calibration Method**:
- `calibrateToCurrentFrame(from:)` analyzes entire depth frame
- `calculatePercentiles(from:)` helper extracts valid values, sorts, and computes P5/P95
- Sets new min/max range based on scene statistics (in meters)
- Ensures minimum range of 0.1m to avoid division by zero

### DepthVisualizer.swift
**Responsibility**: Rendering depth data as visual overlays

Manages:
- **On-demand conversion from meters to proximity** (0-1) for visualization
- False color mapping (configurable colors)
- Orientation transforms for device rotation
- Aspect-fill scaling and cropping
- CGImage rendering

**Key Features**:
- Takes raw meter buffers and min/max depth parameters
- Converts meters → proximity using `convertMetersToProximity()` before color mapping
- Encapsulates all Core Image operations
- Configurable color scheme (farColor=blue, nearColor=red properties)
- Reusable CIContext for performance
- Private helper methods for single-responsibility functions

### EdgeDetectorGPU.swift
**Responsibility**: GPU-accelerated real-time edge detection using LiDAR depth data only

Implements depth-only edge detection using Core Image filters for GPU acceleration.

**Algorithm Overview**:
This depth-only approach detects edges by analyzing geometric discontinuities in the LiDAR depth map. Depth edge detection finds surface boundaries and depth jumps using Sobel gradient analysis. The edge strength can be amplified and thresholded using customizable parameters.

**Implementation Details**:
- Uses Core Image filters for GPU acceleration via Metal
- Depth edges detected via CISobelGradients on **raw meter depth map**
- Edge amplification uses CIColorMatrix for intensity scaling
- Optional thresholding filters out weak edges using CIColorClamp
- Optional pre-smoothing reduces noise using CIGaussianBlur
- All operations execute on GPU, achieving <10ms processing time
- Outputs normalized edge strength map (0-1 range) as CVPixelBuffer

**Customizable Parameters** (all public properties):
- `edgeAmplification` (CGFloat, default: 2.0): Multiplier for edge strength (range: 1.0-5.0)
- `edgeThreshold` (CGFloat, default: 0.1): Minimum edge strength to display (range: 0.0-1.0)
- `enableThresholding` (Bool, default: true): Enable/disable edge thresholding
- `preSmoothingRadius` (CGFloat, default: 0.0): Gaussian blur radius before edge detection (0.0 = disabled)

**Preset Methods** (for quick calibration):
- `resetToDefaults()`: Reset all parameters to default values
- `applySubtlePreset()`: Subtle, high-quality edges (good for detailed scenes)
- `applyStrongPreset()`: Strong, visible edges (good for bold visualization)
- `applyMaximumPreset()`: Maximum edge detection (shows all edges, including noise)
- `applyCleanPreset()`: Clean edges (reduces noise, shows only strong edges)

**Processing Steps**:
1. Optional pre-smoothing with Gaussian blur (GPU)
2. Apply Sobel edge detection to depth map (GPU)
3. Amplify edges with configurable color matrix multiplication (GPU)
4. Optional threshold to filter weak edges (GPU)
5. Return edge map for visualization

**Performance**:
- ~100x faster than CPU-based approaches
- Processes every 3rd frame (~10fps) for real-time performance
- Typical execution time: <10ms per frame on GPU

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

1. **Capture**:
   - AVCaptureDepthDataOutput streams depth frames from LiDAR camera
   - AVCaptureVideoDataOutput streams RGB frames from camera
2. **Process** (DepthProcessor):
   - Convert to 32-bit floating-point **depth format (METERS)** using `kCVPixelFormatType_DepthFloat32`
   - **Preserve raw meter values** - no in-place mutation
   - Sample center aperture for haptic feedback (returns meters)
3. **Edge Detection** (EdgeDetectorGPU):
   - Depth-only edge detection: Sobel filter on **raw meter values** (GPU)
   - Optional pre-smoothing to reduce noise (GPU)
   - Edge amplification with customizable factor (GPU)
   - Optional thresholding to filter weak edges (GPU)
   - All operations run on Metal GPU for real-time performance (<10ms)
   - Store edge map for visualization
4. **Haptic Feedback** (HapticFeedbackManager):
   - Receive average center depth **in meters** from DepthProcessor
   - Convert to proximity (0-1) using `metersToProximity()`: **0.0 = far, 1.0 = close**
   - Update continuous vibration intensity
   - Stronger vibration for closer objects (higher proximity)
5. **Visualize** (DepthVisualizer):
   - Convert meters → proximity (0-1) using `convertMetersToProximity()` with min/max depth range
   - Depth: Apply false color filter to proximity values (blue=far, red=close)
   - Edges: Apply false color filter (transparent→green gradient)
   - Apply orientation transform
   - Scale and crop to screen size
   - Render to CGImage
6. **Display**: Update UIImageViews on main thread (depth + edges)

**Key Architecture Principle**: Raw meter values flow through the pipeline unchanged. Proximity conversion (0-1) happens **on-demand** only where needed (visualization, haptics).

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
- Continuously samples a small center "aperture" (20% of frame)
- Averages **depth values in meters** in that region
- Converts meters to proximity (0-1) where 0=far, 1=close
- Maps proximity to vibration intensity (0-100%)
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
- **Non-destructive proximity conversion** - creates new buffers only when needed
- Haptic updates throttled by depth frame rate (~30fps)
- Edge detection runs on separate GPU queue, processes every 3rd frame

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
- ✅ **GPU-accelerated depth-only edge detection** with customizable parameters
- ✅ **Calibratable edge detection** (amplification, thresholding, smoothing)
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
- ✅ Configurable depth range in meters (via DepthProcessor minDisparity/maxDisparity properties)
- ✅ **Preserved raw meter values** throughout pipeline for accurate measurements
- ✅ Automatic haptic engine recovery from interruptions
- ✅ Visual focus indicator with smooth animations

## Requirements

- iOS device with LiDAR sensor (iPhone 12 Pro or later, iPad Pro 2020 or later)
- iOS 14.0+
- Camera and depth data permissions

## Known Issues

None currently.

## Technical Notes

### GPU-Accelerated Depth-Only Edge Detection
The app implements real-time edge detection using LiDAR depth data only with customizable, calibratable parameters.

**How It Works**:
1. **Optional Pre-Smoothing**: Apply Gaussian blur to reduce noise (GPU via CIGaussianBlur, configurable radius)
2. **Depth Edge Detection**: Apply Sobel gradient filter to **raw meter depth map** (GPU via CISobelGradients)
3. **Edge Amplification**: Multiply edge strength by configurable factor (GPU via CIColorMatrix, default: 2.0)
4. **Optional Thresholding**: Filter out weak edges below configurable threshold (GPU via CIColorClamp, default: 0.1)
5. **Output**: Normalized edge strength map (CVPixelBuffer, 0-1 range)

**Note**: Edge detection operates directly on raw meter values from LiDAR, detecting geometric discontinuities in real-world distance measurements.

**Why Depth-Only**:
- **Depth edges** capture geometric discontinuities: walls, furniture edges, surface boundaries, depth jumps
- **Lighting-independent**: Works in complete darkness (LiDAR doesn't need light)
- **Fully customizable**: All parameters exposed for tuning to specific use cases
- **Calibratable**: Preset methods for quick adjustments (subtle, strong, maximum, clean)

**Customization Parameters**:
- `edgeAmplification`: Control edge visibility (1.0-5.0, default: 2.0)
- `edgeThreshold`: Filter weak edges (0.0-1.0, default: 0.1)
- `enableThresholding`: Toggle edge filtering (default: true)
- `preSmoothingRadius`: Noise reduction blur (default: 0.0 = disabled)

**Preset Methods for Quick Calibration**:
- `applySubtlePreset()`: Detailed, high-quality edges with smoothing
- `applyStrongPreset()`: Bold, visible edges for clear visualization
- `applyMaximumPreset()`: All edges including noise (no filtering)
- `applyCleanPreset()`: Strong smoothing, high threshold for clean output
- `resetToDefaults()`: Return to default parameters

**Performance**:
- All operations execute on GPU via Metal/Core Image
- Typical execution time: <10ms per frame (100x faster than CPU approaches)
- Processes every 3rd frame (~10fps) for balance between performance and real-time updates
- No blocking of depth or haptic pipelines

**Output**: Green-colored edge overlay (transparent→bright green gradient) displayed above depth visualization

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
- ✅ **Display actual distance values on screen** (raw meter values already available in pipeline!)
- Customizable percentile thresholds (currently P5/P95)
- Histogram visualization of depth distribution
- Real-time depth value readout at tap location

### Code Quality
- Unit tests for DepthProcessor, DepthVisualizer, and HapticFeedbackManager
- Dependency injection for better testability
- Performance profiling and optimization
