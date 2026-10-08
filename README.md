# <img src="docs/logo.svg" width="40" height="40" valign="bottom" /> MetalPlayer

A video player for macOS built on VideoToolbox, AVSampleBufferDisplayLayer, and Metal.

> [!WARNING]
> **Status: pre-alpha.** Not ready for everyday use. Subtitles and standalone packaging are not implemented yet.

## Roadmap

- [x] Rendering: Apple HDR passthrough and Metal BT.2390 EETF tone mapping
- [x] Video: HEVC 10-bit, H.264 8/10-bit, Dolby Vision Profile 5, HLG
- [x] Audio: master clock sync, multiple PCM tracks, Spatial Audio, 5.1/7.1
- [x] Diagnostics overlay: CPU/RAM, A/V drift, queue levels
- [x] Desktop UX: keyboard shortcuts, double-click fullscreen, cursor auto-hide
- [x] HTTP/HTTPS streaming with custom auth headers
- [x] Resume playback & start time position control (Watch Later)
- [ ] Dolby Vision Profile 8/8.1 RPU processing (per-frame L1 metadata)
- [ ] AV1 (VideoToolbox on M3 and later, `dav1d` on M1/M2)
- [ ] Subtitles: embedded and external SRT, WebVTT, ASS
- [ ] Embedding the video view in a WKWebView-based client
- [ ] Bundling FFmpeg dylibs into the app

Details: [docs/ROADMAP.md](docs/ROADMAP.md).

## API Usage

Add `MetalPlayer` to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../metal-player") // or git repository URL
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MetalPlayerKit", package: "metal-player")
        ]
    )
]
```

### High-level Window API (`MetalPlayerKit`)

```swift
import MetalPlayerKit

let controller = PlayerWindowController()

// Stream remote media with custom auth headers and start from a specific second:
controller.openStream(
    url: URL(string: "https://media.server/stream.mkv")!,
    headers: ["Authorization": "Bearer secret_token"],
    startTime: 120.0 // Optional; overrides local resume history
)

// Open local media file:
controller.openFile(
    url: fileURL,
    startTime: nil // Pass nil to automatically resume from saved position (if enabled)
)

// Observability and Event Callbacks:
controller.onTimeUpdate = { currentTime, duration in
    // Called periodically (every ~0.1s during active playback)
}

controller.onPlaybackStateChanged = { state in
    // .idle, .loading, .playing, .paused, .completed, .failed(String)
}

controller.onPlaybackEnded = {
    // Media finished playing to the end
}

controller.onClose = {
    // Window was closed by user
}
```

### Low-level Rendering Engine (`MetalPlayerCore`)

```swift
import MetalPlayerCore

let engine = PlayerEngine()

// Async loading for network streams:
await engine.loadAsync(
    path: "https://media.server/stream.mkv",
    headers: ["X-Api-Key": "my-key"],
    startTime: 300.0
)
```

## Requirements

- macOS 15+
- Apple Silicon
- FFmpeg shared libraries (`brew install ffmpeg`)

## Building

```bash
swift build -c release
```

Build a signed `.app` bundle and launch it:

```bash
./scripts/bundle_app.sh --run
```

Tests and formatting check:

```bash
swift test
./scripts/format.sh check
```

## License

[MIT](LICENSE)
