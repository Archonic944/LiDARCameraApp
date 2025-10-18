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
        ├───────────────────┬──────────────────┐
        │                   │                  │
┌───────▼──────────┐  ┌─────▼────────────┐  ┌▼─────────────────┐
│ DepthProcessor   │  │ DepthVisualizer  │  │ HapticFeedback   │
├──────────────────┤  ├──────────────────┤  │ Manager          │
│ - Conversion     │  │ - Color mapping  │  ├──────────────────┤
│ - Normalization  │  │ - Orientation    │  │ - Continuous     │
│ - Center sampling│  │ - Scaling/crop   │  │   vibration      │
└──────────────────┘  │ - Rendering      │  │ - Dynamic        │
                      └──────────────────┘  │   intensity      │
                                            └──────────────────┘
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
**Responsibility**: Depth data processing and normalization

Handles:
- Converting AVDepthData to 32-bit float disparity format
- Normalizing depth values to 0-1 range using fixed disparity range
- CVPixelBuffer manipulation
- Center aperture sampling for haptic feedback

**Key Features**:
- Extension on CVPixelBuffer for reusable normalization
- Fixed range normalization for consistent depth visualization
- Configurable min/max disparity values (default: 0.2 to 2.0)
- Thread-safe operations

**Normalization Strategy**:
- Uses **fixed range normalization** instead of per-frame min/max
- Ensures consistent color mapping across frames
- Objects at the same distance always show the same color
- Values outside range are clamped to 0-1
- Default range: minDisparity=0.2 (~5m), maxDisparity=2.0 (~0.5m)

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
   - Normalize depth values to 0-1 range using fixed disparity range (0.2 to 2.0)
   - Values are clamped to ensure consistent visualization across frames
   - Sample center aperture for haptic feedback
3. **Haptic Feedback** (HapticFeedbackManager):
   - Receive average center depth (0.0 = far, 1.0 = close)
   - Update continuous vibration intensity
   - Stronger vibration for closer objects
4. **Visualize** (DepthVisualizer):
   - Apply false color filter (blue→red gradient)
   - Apply orientation transform
   - Scale and crop to screen size
   - Render to CGImage
5. **Display**: Update UIImageView on main thread

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

## Requirements

- iOS device with LiDAR sensor (iPhone 12 Pro or later, iPad Pro 2020 or later)
- iOS 14.0+
- Camera and depth data permissions

## Known Issues

None currently.

## Technical Notes

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
- UI controls for adjusting min/max disparity range in real-time
- Recording video with depth overlay
- 3D point cloud visualization
- Depth map export (as image or data file)
- Display actual distance values on screen (convert disparity to meters)

### Code Quality
- Unit tests for DepthProcessor, DepthVisualizer, and HapticFeedbackManager
- Dependency injection for better testability
- Performance profiling and optimization
