# MetalPlayer: Architecture & Roadmap

This document outlines the architecture, current implementation status, and development roadmap for `MetalPlayer`.
The goal is to evolve the dual-engine video rendering core into a complete standalone media player with audio playback, subtitle rendering, network streaming, and host integration capabilities (e.g., embedding into a `WKWebView`-based Emby/Jellyfin client).

---

## 1. Current Core Status (Completed)

- [x] **Reference Video Pipeline (Dual-Engine Architecture):**
  - **Apple Liquid Retina XDR:** Direct hardware overlay via `AVSampleBufferDisplayLayer` (1000–1600 nits).
  - **SDR / External Displays (e.g. LG UltraFine 5K):** Custom Metal tone-mapping compute shader (ITU-R BT.2390 EETF, 203 nits reference white, Display P3, pure 2.2 gamma, FidelityFX CAS 5x luma-optimized sharpening).
- [x] **Hardware HEVC VideoToolbox Decoder:** P010 biplanar YCbCr, MSB normalization.
- [x] **Dynamic Color Metadata:** Extract primaries/TRC/matrix from FFmpeg `codecpar` and NAL SEI/VUI.
- [x] **Annex B & MP4/HVCC Normalization:** Robust container support for MKV, TS, MP4, and raw HEVC streams.
- [x] **Modular SPM Decomposition:** `MetalPlayerCore` (pure system library without `unsafeFlags`), `MetalPlayerUI`, `MetalPlayerApp`.

---

## 2. MVP Implementation Roadmap

```mermaid
flowchart TD
    M1["Stage 1: H.264 / HEVC / DV P5 / HLG ✅"] --> M15["Stage 1.5: Dolby Vision Profile 8/8.1 RPU Engine"]
    M15 --> M2["Stage 2: Audio Pipeline ✅"]
    M2 --> M3["Stage 3: Network & Remote Streaming"]
    M3 --> M4["Stage 4: Subtitles Subsystem SRT/ASS"]
    M4 --> M5["Stage 5: WKWebView Bridge"]
    M5 --> M6["Stage 6: Desktop UI & UX Controls"]
    M6 --> M7["Stage 7: Standalone App Bundling & Release"]
    M2 -.-> M25["Stage 2.5: AV1 Hybrid Engine M3+ HW / Dav1d SW"]
```

---

### Stage 1: Video Codecs & Formats Expansion — [COMPLETED] ✅
> Evolve from a specialized HEVC demuxer into a versatile video playback engine.

- [x] **1.1. H.264 / AVC Support (SDR 8-bit & 10-bit):**
  - Add `AV_CODEC_ID_H264` support in demuxer.
  - Parse SPS (NAL 7) and PPS (NAL 8) parameter sets.
  - Initialize decompression session via `CMVideoFormatDescriptionCreateFromH264ParameterSets`.
  - Dynamic pixel format selection (`.r8Unorm` vs `.r16Unorm`, Video Range vs Full Range).
  - Direct SDR Metal render pipeline: BT.709 OETF $\to$ Linear BT.709 $\to$ Display P3 with gamma 2.2 and FidelityFX CAS without EETF tone-mapping overhead.
- [x] **1.2. Extended HDR Standards (HLG & Dolby Vision Profile 5):**
  - HLG (Hybrid Log-Gamma, ARIB STD-B67 / BT.2100): Inverse OETF + display-adapted OOTF gamma scaling.
  - Dolby Vision Profile 5: Hardware detection of `dvvC`/`dvcC` atom boxes, IPTc2 / ICtCp unpack $\to$ LMS' $\to$ ST 2084 PQ EOTF $\to$ Linear BT.2020 in nits (eliminates green/purple tint).
- [x] **1.3. Container Extradata Parsing (`avcC` / `hvcC`):**
  - Instant extraction of SPS/PPS/VPS from MP4/MKV extradata headers without needing to scan packet bitstreams.
  - Packet-level scanning retained as a fallback for raw Annex-B streams.
- [x] **1.4. Unified `MediaDemuxer` & Audio Buffering:**
  - Rename `HEVCDemuxer` $\to$ `MediaDemuxer`.
  - Traverse all container streams, extracting audio metadata (`audioStreamIndex`, `audioTimebase`, `audioCodecId`, `audioChannels`, `audioSampleRate`).
  - Implement concurrent `audioQueue` with `nextAudioPacket()`: demux audio concurrently during video traversal, preserving unified disk I/O.

---

### Stage 1.5: Dynamic HDR & Dolby Vision Profile 8/8.1 RPU Engine
> Full frame-by-frame dynamic metadata adaptation (SMPTE ST 2094-10) for Web-DL and UHD Blu-ray rips.

- [ ] **1.5.1. DOVI RPU Extraction (FFmpeg / NAL SEI Prefix):**
  - Detect and extract Dolby Vision RPU bitstream (`AV_PKT_DATA_DOVI_CONF` side data or `NAL_UNSPEC62` NAL units).
  - Parse Dolby Vision Level 1 (L1) dynamic metadata: frame-accurate `min_pq`, `max_pq`, and `avg_pq`.
- [ ] **1.5.2. Adaptive Scene-by-Scene Tone Mapping:**
  - Forward dynamic L1 target parameters with frame PTS through `FrameQueue`.
  - Feed dynamic shot peak luminance directly into `HDRToneMapping.metal`, adjusting EETF kneepoints on the fly (retaining shadow details in dark scenes without blowing out highlights).
- [ ] **1.5.3. Hybrid Profile Detection:**
  - Distinguish Profile 5 (native ICtCp colorspace) vs Profile 8/8.1 (standard BT.2020 YCbCr base layer + dynamic RPU metadata) vs Profile 7 (FEL/MEL fallback to HDR10/BL).

---

### Stage 2: Audio Pipeline & Synchronization — [COMPLETED] ✅
> **Critical MVP milestone.** Seamless high-fidelity audio playback synchronized with video.

- [x] **2.1. Hardware Master Clock Synchronization:**
  - Attach `AVSampleBufferAudioRenderer` to the shared `AVSampleBufferRenderSynchronizer`.
  - Video and audio synchronize against a single CoreAudio hardware timebase, eliminating A/V lip-sync drift.
- [x] **2.2. Audio Demuxing & Decoding (FFmpeg libavcodec + libswresample):**
  - Read audio packets from demuxer's `audioQueue`.
  - Decode via FFmpeg `libavcodec` and resample via `libswresample` to 48kHz Float32 Linear PCM.
  - Apple Spatial Audio & multichannel support: preserve 5.1/7.1 channel layouts with SMPTE/AudioUnit tags (`kAudioChannelLayoutTag_AudioUnit_5_1` / `kAudioChannelLayoutTag_AudioUnit_7_1`) in `CMAudioFormatDescription`.
  - Package PCM into `CMSampleBuffer` with automatic sample size calculation.
- [x] **2.3. Queue Management, Spatial Audio & Control Center Integration:**
  - Non-blocking `audioFeedQueue` feeding `AVSampleBufferAudioRenderer.requestMediaDataWhenReady` with ~0.3s lead time backpressure.
  - Enable `allowedAudioSpatializationFormats = .monoStereoAndMultichannel` for Dynamic Head Tracking on AirPods.
  - Listen for `.AVSampleBufferAudioRendererOutputConfigurationDidChange` and `.AVSampleBufferAudioRendererWasFlushedAutomatically` notifications for instant CoreAudio DSP-graph reconfiguration on Spatial Audio mode switch (*Off / Fixed / Head Tracked*).
  - Multi-track discovery (`audioTracks: [AudioTrack]`) and live track switching (`selectAudioTrack(id:)`).
  - Volume control (`volume: 0.0 ... 1.0`), mute toggle (`isMuted: Bool`), custom UI slider and track picker in `ControlsOverlay`.
  - Flush audio decoder and renderer buffers on seek and track change.
- [x] **2.4. App Bundle Lifecycle & System Integration:**
  - Build and ad-hoc sign `MetalPlayer.app` with `CFBundleIdentifier` (`com.ghotriw.metalplayer`) via `scripts/bundle_app.sh`, enabling macOS Control Center integration.
  - Implement native window controller and `AppDelegate` with `applicationShouldTerminateAfterLastWindowClosed = true` and standard macOS menu shortcuts (`⌘Q`, `⌘W`, `⌘O`).

---

### Stage 2.5: AV1 Hybrid Engine (AOMedia Video 1)
> Apple Silicon M1/M2 chips lack hardware AV1 decoders (introduced in M3/M4+), necessitating a hybrid fallback.

- **2.5.1. Decoder Protocol Abstraction (`VideoDecoderProtocol`):**
  - Common decoder interface enabling transparent switching between hardware `VTVideoDecoder` and software backends.
- **2.5.2. M3/M4+ Hardware Path (VideoToolbox):**
  - Check `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)`.
  - Parse `av1C` config atoms and OBUs (Open Bitstream Units).
- **2.5.3. M1/M2 Software Path (`libdav1d`):**
  - Integrate high-performance SIMD/NEON assembly decoder `dav1d` (VideoLAN).
  - Direct zero-copy or fast mapping of `dav1d_data` YUV420P buffers into `CVPixelBuffer` for Metal / DisplayLayer rendering.

---

### Stage 3: Remote Network & Media Server Streaming (HTTP / Emby)
> Enable direct streaming from remote media servers (Emby, Jellyfin, Plex) without transcoding.

- **3.1. Remote URLs & HTTP Headers Support:**
  - Extend demuxer initialization: `MediaDemuxer.init(url: String, headers: [String: String])`.
  - Pass custom HTTP request headers to FFmpeg (`AVDictionary` with `headers`, e.g., `X-Emby-Token`, `Authorization`, `User-Agent`).
  - Support `http://`, `https://`, and `file://` protocols uniformly.
- **3.2. Network Buffering & Backpressure:**
  - Track playback buffer health and expose `isBuffering: Bool`.
  - Implement FFmpeg interrupt callbacks (`AVFormatContext.interrupt_callback`) to prevent thread hangs during network dropouts or timeouts.

---

### Stage 4: Subtitles Subsystem (SRT & ASS)
> High-performance subtitle overlay for foreign language content.

- **4.1. Text-based Subtitles (SRT, WebVTT):**
  - Extract embedded subtitle streams from MKV/MP4 containers and load external `.srt` files.
  - Synchronize subtitle cues against master timeline `currentTime`.
- **4.2. Universal Subtitle Overlay Layer:**
  - Position subtitle rendering overlay above both `CAMetalLayer` and `AVSampleBufferDisplayLayer`.
  - Automatic scaling, typography styling, and safe margins handling.

---

### Stage 5: Host Integration Bridge (WKWebView Two-Way Bridge)
> Enable embedding MetalPlayer as a native high-performance rendering backend inside hybrid web applications.

- **5.1. Embedded Native Video Canvas:**
  - `NativeVideoHostView` as an embeddable `NSView` without intrusive UI chrome.
  - Transparent `WKWebView` overlay delegating mouse and keyboard gestures seamlessly.
- **5.2. Two-Way Bridge API Contract:**
  - **Commands IN (JS -> Native):**
    - `open(url, headers)`
    - `play()`, `pause()`, `seek(seconds)`
    - `setVolume(level)`, `setAudioTrack(id)`, `setSubtitleTrack(id)`
    - `setToneMapParams(exposure, shadowLift, sharpness)`
  - **Events OUT (Native -> JS via `messageHandlers`):**
    - `onTimeUpdate({ currentTime, duration, buffered })`
    - `onStateChange({ state: 'playing' | 'paused' | 'buffering' | 'ended' })`
    - `onTracksLoaded({ audioTracks, subtitleTracks })`
    - `onError({ code, message })`

---

### Stage 6: Desktop UI & UX Controls (SwiftUI Player Experience)
> Polished, distraction-free desktop media player interface.

- **6.1. Fullscreen Behavior & Cursor Autohide:**
  - Automatically hide mouse cursor and controls overlay after 3 seconds of user inactivity.
  - Borderless native macOS fullscreen mode.
- **6.2. Keyboard Shortcuts:**
  - `Space` — Play / Pause.
  - `Left` / `Right` — Seek backward / forward (5 seconds).
  - `J` / `K` / `L` — Standard rewind / pause / fast-forward shuttle controls.
  - `Up` / `Down` — Volume adjustment (+/- 5%).
  - `M` — Mute toggle.
  - `F` — Fullscreen toggle.
  - `[` / `]` — Single frame step (1/24s).

---

### Stage 7: Standalone App Bundling & Release Packaging
> Eliminate developer environment dependencies (Homebrew FFmpeg) for zero-friction distribution to end users.

- **7.1. Dynamic Library Bundling (Dylib Bundling):**
  - Populate `Contents/Frameworks` within `MetalPlayer.app`.
  - Copy required FFmpeg dylibs (`libavformat`, `libavcodec`, `libavutil`, `libswresample`) and their transitive dependencies.
  - Rewrite dynamic linker paths using `install_name_tool`: replace hardcoded `/opt/homebrew/...` paths with `@rpath` (`@executable_path/../Frameworks`).
  - Configure `LC_RPATH` (`@loader_path/../Frameworks`) in `MetalPlayer` executable.
- **7.2. CI Automation & Release Artifacts:**
  - Add `--standalone` / `--release` flags to `scripts/bundle_app.sh`.
  - Validate bundle with `otool -L`: verify zero references to non-system directories outside `/System/Library` and `/usr/lib`.
  - Package compressed DMG / ZIP distribution archives automatically via GitHub Actions CI.
