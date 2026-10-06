# MetalPlayer Core Architecture & Regression Prevention Rules

This document defines the core architecture principles, colorimetry standards, threading invariants, and architectural decoupling rules for `MetalPlayer`. Any future additions (audio pipeline, subtitle renderers, UI, additional container/codec formats) **must strictly adhere** to these rules to prevent regressions.

---

## 1. Project Mission & Target Visual Standards
Deliver reference-grade playback of HDR and Dolby Vision (Profile 8.1 / HDR10) video on macOS:
1. **On Standard SDR Displays (External 4K/5K monitors without HDR, EDR == 1.0):**
   - Provide vibrant color fidelity, deep and detailed shadow retrieval, and crisp highlight roll-off without the washed-out, dark, or crushed look produced by default operating system tone mapping.
   - Powered by a custom **Metal SDR Tone-Mapper** implementing the ITU-R BT.2390 EETF specification (203 nits target white point, Display P3 destination gamut, pure Gamma 2.2 output, and FidelityFX Contrast-Adaptive Sharpening).
2. **On Native Liquid Retina XDR / Extended Dynamic Range Displays (EDR > 1.01):**
   - Route uncompressed video straight to the native Apple DisplayLayer hardware overlay, unlocking full 1000–1600 nits Mini-LED peak brightness.

---

## 2. Decoupled Architecture & Layer Boundaries

The codebase is split into three strictly separated layers to prevent UI changes from polluting or breaking low-level media pipelines:

```
[UI / Presentation Layer (SwiftUI / AppKit)]
               ↓ (observes state & calls user intent actions)
[ViewModel / Facade Layer (@Observable)]
               ↓ (drives contract protocol)
[protocol PlayerEngine: AnyObject]
               ↓ (implemented by headless engine)
[Headless Engine Core (Metal / VideoToolbox / Demuxer / Synchronizer)]
```

### 2.1. Layer 1: Headless Engine Core (`PlayerEngineCore`)
- **Zero UI Dependency:** Must never import SwiftUI or depend on UI views, buttons, layouts, or control state.
- **Responsibilities:** Demuxing, decoding, hardware master clock synchronization, Metal rendering, frame queues, EDR/screen handover.
- **Public Surface:** Implements `protocol PlayerEngine` and exports a lightweight `NSView` / `CALayer` video canvas (`videoSurface`).

### 2.2. Layer 2: Facade & ViewModel (`PlayerViewModel`)
- Lives on `@MainActor`.
- Acts as the single communication bridge between the headless engine and the user interface.
- Exposes observable properties (`currentTime`, `duration`, `progress`, `playbackState`, `isControlsVisible`, `mediaTitle`) and public user actions (`play()`, `pause()`, `seek(progress:)`, `openFile(url:)`).

### 2.3. Layer 3: Presentation UI (`SwiftUI / AppKit`)
- Purely declarative UI components (`ControlsOverlay`, `TimelineSlider`, `SettingsSheet`, `HUD`).
- Consumes `PlayerViewModel` via SwiftUI observation.
- Changing, rewriting, or animating UI components must never impact or require changes to decoding loops, Metal shaders, or A/V sync.

---

## 3. Video Pipeline Invariants (DO NOT BREAK)

### 3.1. Display-Adaptive Rendering & Graceful Handover
- The default player mode is `.auto` (`Auto (Display Adaptive)`).
- EDR capabilities are queried dynamically across display changes:
  ```swift
  let isHDR = (screen.maximumExtendedDynamicRangeColorComponentValue) > 1.01
  ```
- **Graceful Handover Mechanics:**
  - **HDR ➔ SDR Transition:** The underlying hardware `AVSampleBufferDisplayLayer` must remain continuously visible until the background `VTVideoDecoder` produces its first valid frame matching or exceeding `currentSyncTime`. Only then does `CAMetalLayer` surface over the display layer (`isMetalLayerVisible = true`). This prevents black flickers or frame pauses.
  - **SDR ➔ HDR Transition:** `isMetalLayerVisible` is immediately reset to `false`, revealing the native system HDR overlay with zero latency.
  - **Pipeline Queue Hygiene:** On every render mode handover, `frameQueue.clear()` and asynchronous `decoder.flush()` must be executed to flush stale frames and prevent stutter or packet queue desynchronization.
  - While on an HDR display, `VTVideoDecoder` must not decode idle frames (`modeLock == .metalToneMap`) to conserve hardware decoder bandwidth and energy.

### 3.2. Metal Tone-Mapping Color Engine (`HDRToneMapping.metal`)
- **Input Format:** 10-bit P010 biplanar YCbCr (`r16Unorm` Y plane, `rg16Unorm` CbCr plane). Normalization must account for VideoToolbox MSB-alignment: `val * 65535.0 / 1023.0`.
- **Output Pixel Format:** `CAMetalLayer` and the render pipeline state must strictly use `.bgr10a2Unorm` (10-bit color depth) configured for the `Display P3` color space. Never regress to 8-bit `.bgra8Unorm`, as it introduces gradient banding across dark regions and skies.
- **Shader Colorimetry Pipeline:**
  - PQ (SMPTE ST 2084) inverse transfer function $\rightarrow$ absolute linear optical light $L \in [0, 10000]$ nits.
  - ITU-R BT.2390 (EETF) tone curve compressed against `targetNits = 203.0` (standard ITU reference white for SDR mastering).
  - Chromaticity conversion: `BT.2020` matrix transform to `Display P3` (D65 white point) with gamut boundary safety clamping.
  - Output electro-optical transfer function: **pure power Gamma 2.2** (`pow(max(c, 0.0), 1.0 / 2.2)`).
  - Contrast-Adaptive Sharpening: AMD FidelityFX CAS formulation (`peak = -1.0 / mix(8.0, 5.0, strength); weight = amplitude * peak;`). Guarantees no division by zero or NaN artifacts when `strength = 1.0`.

### 3.3. Thread Safety & Swift Concurrency
- `MetalVideoRenderer` is isolated using `renderLock: NSLock` (synchronizing draw calls across display link and UI frame invalidation) and `OSAllocatedUnfairLock` (protecting `ToneMapUniforms`).
- Both `ToneMapUniforms` and `RenderMode` must conform to `Sendable`.
- `activeRenderMode` must be held behind an `OSAllocatedUnfairLock` and exposed as `nonisolated` to allow `CVDisplayLink` to query the mode without actor hops or priority inversions.
- From within the `CVDisplayLink` C-callback, any state changes targeting `@MainActor` properties (such as `isMetalLayerVisible`) must be dispatched via `DispatchQueue.main.async`. **Never call `MainActor.assumeIsolated`** from this callback; doing so triggers an immediate trap in `libdispatch`.

### 3.4. Pause Frame Accuracy
- `FrameQueue` preserves the most recently displayed buffer in `lastRenderedBuffer: CVPixelBuffer?`.
- Mode switching or scrubbing while paused invokes `renderCurrentFrame()`, which re-renders the frozen buffer to guarantee frame-accurate parity without time drift.

---

## 4. Invariants for Future Subsystems

### 4.1. Audio Pipeline
- Playback timing must remain driven by a single unified **`AVSampleBufferRenderSynchronizer`**.
- Audio output must utilize `AVSampleBufferAudioRenderer` attached directly to this shared synchronizer.
- This maintains hardware-locked audio/video synchronization without software clock drift.

### 4.2. Universal Demuxing & Color Metadata
- Do not hardcode container metadata:
  - Color space flags (`color_primaries`, `color_trc`, `color_space`) must be read dynamically from `codecpar` and container extradata (`hvcC`).
  - MaxCLL/MaxFALL and Mastering Display Luminance must be parsed from packet side data or SEI payloads and forwarded to `metalRenderer.uniforms.sourcePeakNits`.
  - All timestamps must compute `pts * Int64(timebase.num) / Int64(timebase.den)`.

### 4.3. Pre-Commit Verification
- The package must compile cleanly using `swift build` without errors.
- Any modifications to `HDRToneMapping.metal` must be verified against NaN edge cases at maximum sharpness (`outputSharpness = 1.0`).
