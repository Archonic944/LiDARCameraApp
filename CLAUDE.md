# agents.md — LiDAR Camera App

iOS app overlaying LiDAR depth (meters) on camera preview. Color mapping: **near = red**, **far = blue**. **Raw meter values are preserved**; convert to 0–1 *proximity* only where needed (visuals, haptics).

**Hard rule:** Do not change hardcoded calibration values (e.g. `defaultMinDepth = 1.321`, `defaultMaxDepth = 1.639`) unless the user explicitly requests it.

---

## Architecture (high level)
- `CameraViewController` — UI, AVCaptureSession, stores latest `AVDepthData`, photo capture.
- `DepthProcessor` — AVDepthData → `kCVPixelFormatType_DepthFloat32` (meters), preserves original buffers, sampling, calibration.
- `DepthVisualizer` — meters → proximity, false-color mapping, orientation/scale, renders CGImage.
- `EdgeDetectorGPU` — GPU Sobel-based depth-only edge map (normalized 0–1 `CVPixelBuffer`).
- `GestureManager` — taps/holds, focus UI, edge-hold state.
- `HapticFeedbackManager` — continuous proximity-based haptics (auto-renew to bypass 30s Core Haptics limit).
- `EdgeAlertManager` — directional scanning + transient haptic pulses.

---

## Key files & responsibilities

### CameraViewController.swift
- Manages AVCaptureSession lifecycle, permissions, delegates.
- Receives processed buffers and updates UI on main thread.
- Implements `GestureManagerDelegate`: single tap → calibrate, double-tap → reset.

### DepthProcessor.swift
- Converts depth frames to Float32 **meters** and **does not mutate original depth buffers**.
- Center aperture sampling returns average in meters (for haptics).
- Calibration:
  - `calibrateToCurrentFrame(from:)` → compute 5th/95th percentiles (P5/P95) and set `minDepth`/`maxDepth` (enforce minimum range 0.1m).
- `metersToProximity(meters, minDepth, maxDepth)`:
  - `proximity = 1.0 - clamp((meters - minDepth) / (maxDepth - minDepth))`
  - Semantics: `0.0 = far (>= maxDepth)`, `1.0 = close (<= minDepth)`.
- Exposes configurable `minDepth`/`maxDepth` (defaults `1.321m` / `1.639m`).

### DepthVisualizer.swift
- Converts meter buffer → proximity → false-color (near=red, far=blue).
- Handles orientation (`CIImage.oriented()`), scale/crop, CGImage rendering.
- Reuses `CIContext`; color scheme configurable.

### EdgeDetectorGPU.swift
- GPU pipeline (operates on raw meters):
  1. Downscale (Lanczos)
  2. Optional Gaussian pre-smoothing
  3. Algorithm 1 from misc/bose_l_fast_rgbd_edge_detection.txt
  4. Amplify (CIColorMatrix)
  5. Optional threshold (CIColorClamp)
  6. Optional upscale
- Outputs normalized edge strength (0–1) `CVPixelBuffer`.
- Public defaults:
  - `edgeAmplification = 2.0`, `edgeThreshold = 0.1`, `enableThresholding = true`
  - `preSmoothingRadius = 0.0`, `downscaleFactor = 0.5`, `upscaleOutput = true`
- Preset helpers: `resetToDefaults()`, `applySubtlePreset()`, `applyStrongPreset()`, `applyMaximumPreset()`, `applyCleanPreset()`, `applyPerformancePreset()`.

### GestureManager.swift
- Single/double tap handling, edge-hold detection (left/right/top/bottom).
- Single tap triggers depth calibration; double-tap resets defaults.
- Exposes `isHoldingLeftEdge`, etc., and shows focus indicator animation.

### HapticFeedbackManager.swift
- Continuous haptic intensity driven by proximity (0–1).
- Uses Core Haptics; auto-renews 30s pattern every 28s to emulate continuous vibration.
- Handles engine interruptions and dynamic intensity updates.

### EdgeAlertManager.swift
- On edge-hold: scans oriented edge map outward from center aperture to find nearest significant edge (above threshold).
- Computes normalized distance (0 = at aperture, 1 = max range) → maps to pulse rate; fires transient haptics (sharp "stabs").
- Defaults:
  - aperture size: 20% of frame
  - detection range: 40% of frame
  - pulse interval range: 0.05s–1.0s (20Hz → 1Hz)
  - edge intensity threshold: 0.3
  - pulse intensity/sharpness: 1.0

---

## Processing pipeline
1. Capture: `AVCaptureDepthDataOutput` (depth) + `AVCaptureVideoDataOutput` (RGB).
2. DepthProcessor: convert → Float32 meters; preserve raw buffer; sample center aperture.
3. EdgeDetectorGPU: depth-only Sobel → normalized edge map.
4. HapticFeedbackManager: average center depth (meters) → `metersToProximity()` → continuous intensity.
5. EdgeAlertManager: scan edge map on edge-hold → transient pulses.
6. DepthVisualizer: meters → proximity → false colors; orientation; render CGImage.
7. Display: update UIImageViews on main thread.

**Invariant:** raw meter values remain available end-to-end; proximity conversion is on-demand.

---

## Orientation
Depth arrives landscape by default. Visualizer maps orientations via `CIImage.oriented()` then translates to origin so extents align.

---

## Tap-to-calibrate
- Tap → analyze full frame, compute P5/P95 using `calculatePercentiles()`, set `minDepth = P5`, `maxDepth = P95` (min range ≥ 0.1m).
- Double-tap → reset to `defaultMinDepth` / `defaultMaxDepth`.

---

## Performance
- Depth work runs on background queue (`com.gabe.depthQueue`); UI updates on main thread.
- Reuse `CIContext`.
- Edge detection runs on GPU; default `downscaleFactor = 0.5` (~4× speedup). Typical times: ~2ms (0.5x), <1ms (0.25x).
- Edge detection often processes every 3rd frame (~10fps) to balance load.
- Proximity conversion non-destructive; new buffers allocated only when needed.

---

## Public API invariants
- Preserve raw meter buffers.
- Keep `metersToProximity()` formula and semantics.
- Keep defaults `defaultMinDepth = 1.321`, `defaultMaxDepth = 1.639` unless user explicitly requests change.
- Single tap = calibrate, double-tap = reset.

---

## Requirements
- iOS device with LiDAR (iPhone 12 Pro+ / iPad Pro 2020+), iOS 14+, camera & depth permissions.

---

## Feature checklist
- Real-time LiDAR overlay, false-color mapping, preserved meters, GPU depth-only edges, tap-to-calibrate, double-tap reset, continuous proximity haptics (auto-renew), directional edge alerts, orientation handling, photo capture with embedded depth.

