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
- Normalizing depth values to 0-1 range
- CVPixelBuffer manipulation

**Key Features**:
- Extension on CVPixelBuffer for reusable normalization
- Stateless processing (no instance state)
- Thread-safe operations

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
   - Normalize depth values to 0-1 range
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
- Continuous haptic pattern with dynamic parameters
- Handles engine interruptions (backgrounding, calls)
- Intensity and sharpness modulation

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
- ✅ Color-coded depth visualization
- ✅ **Continuous haptic feedback** (walking stick metaphor)
- ✅ Proximity-based vibration intensity
- ✅ Object-oriented architecture with separation of concerns
- ✅ Proper orientation handling for all device orientations
- ✅ Photo capture with embedded depth data
- ✅ Transparent overlay (80% opacity) to see camera feed
- ✅ Configurable color schemes (via DepthVisualizer properties)
- ✅ Automatic haptic engine recovery from interruptions

## Requirements

- iOS device with LiDAR sensor (iPhone 12 Pro or later, iPad Pro 2020 or later)
- iOS 14.0+
- Camera and depth data permissions

## Known Issues

None currently.

## Future Enhancements

### Haptic Improvements
- Multiple aperture regions for directional feedback
- Different vibration patterns for different distance ranges
- Customizable aperture size and position
- Audio feedback option alongside haptics
- Haptic strength calibration slider

### Visualization
- UI controls for color scheme selection
- Depth range sliders for custom normalization
- Recording video with depth overlay
- 3D point cloud visualization
- Depth map export (as image or data file)

### Code Quality
- Unit tests for DepthProcessor, DepthVisualizer, and HapticFeedbackManager
- Dependency injection for better testability
- Performance profiling and optimization
