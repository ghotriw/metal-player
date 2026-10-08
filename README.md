# <img src="docs/logo.svg" width="40" height="40" valign="bottom" /> MetalPlayer

A video player for macOS built on VideoToolbox, AVSampleBufferDisplayLayer, and Metal.

> [!WARNING]
> **Status: pre-alpha.** Not ready for everyday use. Network streaming, subtitles, and standalone packaging are not implemented yet.

## Roadmap

- [x] Rendering: Apple HDR passthrough and Metal BT.2390 EETF tone mapping
- [x] Video: HEVC 10-bit, H.264 8/10-bit, Dolby Vision Profile 5, HLG
- [x] Audio: master clock sync, multiple PCM tracks, Spatial Audio, 5.1/7.1
- [x] Diagnostics overlay: CPU/RAM, A/V drift, queue levels
- [x] Desktop UX: keyboard shortcuts, double-click fullscreen, cursor auto-hide
- [x] HTTP/HTTPS streaming with custom auth headers
- [ ] Dolby Vision Profile 8/8.1 RPU processing (per-frame L1 metadata)
- [ ] AV1 (VideoToolbox on M3 and later, `dav1d` on M1/M2)
- [ ] Subtitles: embedded and external SRT, WebVTT, ASS
- [ ] Embedding the video view in a WKWebView-based client
- [ ] Bundling FFmpeg dylibs into the app

Details: [docs/ROADMAP.md](docs/ROADMAP.md).

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
