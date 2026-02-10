# agents.md — LiDAR Camera App

iOS app overlaying LiDAR depth (meters) on camera preview. Color mapping: **near = red**, **far = blue**. **Raw meter values are preserved**; convert to 0–1 *proximity* only where needed (visuals, haptics).

**Hard rule:** Do not change hardcoded calibration values (e.g. `defaultMinDepth = 1.321`, `defaultMaxDepth = 1.639`) unless the user explicitly requests it.

---

## Architecture (high level)
- `CameraViewController` — UI, AVCaptureSession, stores latest `AVDepthData`, photo capture.
- `DepthProcessor` — AVDepthData → `kCVPixelFormatType_DepthFloat32` (meters), preserves original buffers, sampling, calibration.
- `DepthVisualizer` — meters → proximity, false-color mapping, orientation/scale, renders CGImage.
- `SurfaceAnalyzer` — CPU-based aperture surface normal analysis; detects normal changes and depth drops for haptic clicks.
- `GestureManager` — taps/holds, focus UI, edge-hold state.
- `HapticFeedbackManager` — continuous proximity-based haptics (auto-renew to bypass 30s Core Haptics limit).
- `EdgeDetectorGPU` — (legacy, no longer referenced) GPU edge detection.
- `EdgeAlertManager` — (legacy, no longer referenced) directional scanning + transient haptic pulses.

---

## Key files & responsibilities

### CameraViewController.swift
- Manages AVCaptureSession lifecycle, permissions, delegates.
- Receives processed buffers and updates UI on main thread.
- Runs `SurfaceAnalyzer` on each depth frame; fires transient haptic pulse on significant change.
- Shows debug label with surface normal dot product, depth delta, and angle.
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

### SurfaceAnalyzer.swift
- Lightweight CPU-based surface normal analysis within the center aperture (~20% of frame).
- For each pixel in aperture: computes surface normal via cross product of depth-derived tangent vectors.
  - `pixelMetricSize = depth * 0.0015`, same math as the Metal shader's `get_normal`.
- Averages all valid normals and depths across aperture.
- Compares to previous frame:
  - **Normal change:** `dot(prevNormal, currentNormal) < normalChangeThreshold` → click.
  - **Depth change:** `abs(currentDepth - prevDepth) > depthDropThreshold` → click.
- Cooldown prevents rapid-fire clicks (default 0.15s).
- Configurable: `normalChangeThreshold` (0.85), `depthDropThreshold` (0.08m), `cooldownInterval` (0.15s).
- Returns `Result` struct with `shouldClick`, `normalDot`, `depthDelta`, `angleDegrees`.

### EdgeDetectorGPU.swift (legacy, not referenced)
- GPU edge detection pipeline. Kept in project but no longer called from CameraViewController.

### GestureManager.swift
- Single/double tap handling, edge-hold detection (left/right/top/bottom).
- Single tap triggers depth calibration; double-tap resets defaults.
- Exposes `isHoldingLeftEdge`, etc., and shows focus indicator animation.

### HapticFeedbackManager.swift
- Continuous haptic intensity driven by proximity (0–1).
- Uses Core Haptics; auto-renews 30s pattern every 28s to emulate continuous vibration.
- Handles engine interruptions and dynamic intensity updates.
- **Provides transient pulse API** (`fireTransientPulse()`) for edge alert system.
- Centralized haptic engine shared by both continuous and transient haptics.

### EdgeAlertManager.swift (legacy, not referenced)
- Directional edge scanning with haptic pulses. Kept in project but no longer called.

---

## Processing pipeline
1. Capture: `AVCaptureDepthDataOutput` (depth only; RGB video output removed).
2. DepthProcessor: convert → Float32 meters; orient to match screen; preserve raw buffer; sample center aperture.
3. SurfaceAnalyzer (on depth queue): compute average surface normal and depth in center aperture; compare to previous frame; fire transient haptic click on significant change.
4. HapticFeedbackManager: average center depth (meters) → `metersToProximity()` → continuous intensity.
5. DepthVisualizer: meters → proximity → false colors; orientation; render CGImage.
6. Display: update UIImageView and debug label on main thread.

**Invariant:** raw meter values remain available end-to-end; proximity conversion is on-demand.

**Threading:** Depth processing and surface analysis on background queue (`com.gabe.depthQueue`); UI updates on main thread.

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
- SurfaceAnalyzer runs on CPU within the center aperture (~20% of ~240x180 LiDAR frame = ~1,700 pixels). Trivial cost (<1ms).
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
- Real-time LiDAR overlay, false-color mapping, preserved meters, aperture surface normal analysis, haptic clicks on surface/depth changes, tap-to-calibrate, double-tap reset, continuous proximity haptics (auto-renew), orientation handling, photo capture with embedded depth.

