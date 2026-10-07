import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Observation
import QuartzCore
import os

@Observable
@MainActor
public final class NativePlayerEngine: PlayerEngine {
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var isPlaying: Bool = false
    public var isLoaded: Bool = false
    public var mediaTitle: String = ""
    public var videoWidth: Int = 0
    public var videoHeight: Int = 0
    public var renderMode: RenderMode = .auto {
        didSet {
            updateEffectiveRenderMode()
        }
    }
    public var isHDRDisplay: Bool = false {
        didSet {
            if oldValue != isHDRDisplay {
                updateEffectiveRenderMode()
            }
        }
    }
    public var isToneMappingPermitted: Bool = true {
        didSet {
            if oldValue != isToneMappingPermitted {
                updateEffectiveRenderMode()
            }
        }
    }
    private let activeRenderModeLock = OSAllocatedUnfairLock(initialState: RenderMode.metalToneMap)
    nonisolated public var activeRenderMode: RenderMode {
        activeRenderModeLock.withLock { $0 }
    }
    public var isMetalLayerVisible: Bool = false {
        didSet {
            let visible = isMetalLayerVisible
            isMetalLayerVisibleLock.withLock { $0 = visible }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalRenderer?.metalLayer.isHidden = !visible
            displayLayer.isHidden = visible
            CATransaction.commit()
        }
    }
    public var metalExposure: Float = 1.0 {
        didSet {
            metalRenderer?.uniforms.outputExposure = metalExposure
        }
    }
    public var metalShadowLift: Float = 0.0 {
        didSet {
            metalRenderer?.uniforms.outputShadowLift = metalShadowLift
        }
    }
    public var metalTargetNits: Float = 203.0 {
        didSet {
            metalRenderer?.uniforms.targetNits = metalTargetNits
        }
    }
    public var metalSharpness: Float = 0.5 {
        didSet {
            metalRenderer?.uniforms.outputSharpness = metalSharpness
        }
    }

    // Audio properties
    public var volume: Float = 1.0 {
        didSet {
            audioRenderer.volume = isMuted ? 0.0 : volume
        }
    }
    public var isMuted: Bool = false {
        didSet {
            audioRenderer.volume = isMuted ? 0.0 : volume
        }
    }
    public var audioTracks: [MediaDemuxer.AudioTrack] = []
    public var selectedAudioTrackId: Int = -1

    public let displayLayer = AVSampleBufferDisplayLayer()
    public let metalRenderer = MetalVideoRenderer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    private let decoder = VTVideoDecoder()
    private var audioDecoder: FFAudioDecoder?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var demuxer: MediaDemuxer?
    private let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    private let audioFeedQueue = DispatchQueue(label: "com.nativeplayer.audiofeed", qos: .userInteractive)
    private var audioConfigObserver: (any NSObjectProtocol)?
    private var audioAutoFlushObserver: (any NSObjectProtocol)?
    private var timeObserver: Any?
    @ObservationIgnored
    private let isFeeding = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    private let isMetalLayerVisibleLock = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    private let isVideoDrainPaused = OSAllocatedUnfairLock(initialState: false)
    public var showDebugHUD: Bool = false {
        didSet {
            if showDebugHUD {
                currentMetrics = performanceMonitor.currentMetrics
            }
        }
    }
    public var currentMetrics: PlayerPerformanceMonitor.Metrics = PlayerPerformanceMonitor.Metrics()
    public let performanceMonitor = PlayerPerformanceMonitor.shared
    private var metricsTimer: DispatchSourceTimer?

    private let frameQueue = FrameQueue()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    private final class DisplayLinkTarget: NSObject, @unchecked Sendable {
        private weak var engine: NativePlayerEngine?

        init(engine: NativePlayerEngine) {
            self.engine = engine
            super.init()
        }

        @objc func onTick(_ link: CADisplayLink) {
            engine?.displayLinkTick()
        }
    }

    public convenience init() {
        self.init(configuration: PlayerConfiguration())
    }

    public init(configuration: PlayerConfiguration) {
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        self.metalTargetNits = configuration.targetNits
        self.metalSharpness = configuration.sharpness
        self.volume = configuration.initialVolume

        metalRenderer?.uniforms.targetNits = configuration.targetNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
        audioRenderer.volume = configuration.initialVolume

        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        displayLayer.videoGravity = .resizeAspect

        let queue = self.frameQueue
        decoder.setOutputHandler { frame in
            queue.push(frame)
        }

        setupDisplayLink()
        setupAudioObservers()
        updateEffectiveRenderMode()
        setupMetricsMonitoring()

        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main)
        { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            if !seconds.isNaN && !seconds.isInfinite && seconds >= 0 {
                MainActor.assumeIsolated {
                    self.currentTime = seconds
                }
            }
        }
    }

    private func setupAudioObservers() {
        // When Spatial Audio mode changes (Off/Fixed/Head Tracked) or the audio route changes,
        // CoreAudio posts AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification.
        // As documented by Apple, flushing the renderer and re-enqueuing from the current playhead
        // acknowledges the change and allows the DSP graph to reconfigure without stalling.
        audioConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.handleAudioConfigurationChange()
        }

        audioAutoFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.handleAudioConfigurationChange()
        }
    }

    private func handleAudioConfigurationChange() {
        guard isPlaying else { return }
        print(
            "[NativePlayerEngine] Audio configuration changed / flushed by system (Spatial Audio toggle or route change)"
        )
        audioFeedQueue.async { [weak self] in
            guard let self else { return }
            self.audioRenderer.flush()
            self.audioDecoder?.flush()
        }
    }

    private func setupMetricsMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.showDebugHUD else { return }
            let statusDesc: String = {
                switch self.displayLayer.sampleBufferRenderer.status {
                case .rendering: return "Rendering"
                case .failed: return "Failed"
                default: return "Waiting"
                }
            }()
            self.performanceMonitor.updateNativeLayerStatus(statusDesc)

            // Gather Mach kernel metrics on a low-priority utility queue to keep Main Thread 100% free
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.performanceMonitor.updateProcessMetrics()
                let metrics = self.performanceMonitor.currentMetrics
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.showDebugHUD else { return }
                    self.currentMetrics = metrics
                }
            }
        }
        timer.resume()
        self.metricsTimer = timer
    }

    private func setupDisplayLink() {
        let target = DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        // If a screen is available on initialization, attach CADisplayLink to NSScreen.main
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.displayLink = link
        }
    }

    /// Attaches the engine's CADisplayLink to the video rendering host view.
    /// This ensures accurate VBLANK sync across ProMotion (120Hz) displays and seamless multi-monitor transitions.
    public func attachDisplayLink(to view: NSView) {
        displayLink?.invalidate()
        let target = displayLinkTarget ?? DisplayLinkTarget(engine: self)
        self.displayLinkTarget = target

        let link = view.displayLink(target: target, selector: #selector(DisplayLinkTarget.onTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = !isPlaying
        self.displayLink = link
    }

    private func updateEffectiveRenderMode() {
        let newMode: RenderMode
        switch renderMode {
        case .auto:
            newMode = (isHDRDisplay || !isToneMappingPermitted) ? .system : .metalToneMap
        case .system:
            newMode = .system
        case .metalToneMap:
            newMode = isToneMappingPermitted ? .metalToneMap : .system
        }
        let previousMode = activeRenderModeLock.withLock { mode -> RenderMode in
            let prev = mode
            mode = newMode
            return prev
        }

        guard previousMode != newMode else { return }

        if newMode == .system {
            // Instant handover to Apple HDR: hide Metal layer immediately
            isMetalLayerVisible = false
            frameQueue.clear()

            let decoder = self.decoder
            let feedingActive = isFeeding.withLock { $0 }
            if isPlaying || feedingActive {
                // If currently playing, stop video feeding, flush displayLayer, and restart feeding for system mode
                displayLayer.sampleBufferRenderer.stopRequestingMediaData()
                displayLayer.sampleBufferRenderer.flush()
                isVideoDrainPaused.withLock { $0 = false }
                let demuxer = self.demuxer
                feedQueue.async { [weak self] in
                    decoder.flush()
                    // Re-sync demuxer video packets with audio playhead
                    if let self {
                        let curTime = self.synchronizer.currentTime().seconds
                        if curTime > 0 {
                            demuxer?.seek(to: curTime)
                        }
                        DispatchQueue.main.async {
                            guard self.isFeeding.withLock({ $0 }) else { return }
                            self.startFeedingVideo()
                        }
                    }
                }
            } else {
                feedQueue.async {
                    decoder.flush()
                }
            }
        } else {
            // Switching to Metal Tone Mapping
            frameQueue.clear()
            let feedingActive = isFeeding.withLock { $0 }
            if isPlaying || feedingActive {
                displayLayer.sampleBufferRenderer.stopRequestingMediaData()
                displayLayer.sampleBufferRenderer.flush()
                isVideoDrainPaused.withLock { $0 = false }
                let demuxer = self.demuxer
                let decoder = self.decoder
                feedQueue.async { [weak self] in
                    decoder.flush()
                    if let self {
                        let curTime = self.synchronizer.currentTime().seconds
                        if curTime > 0 {
                            demuxer?.seek(to: curTime)
                        }
                        DispatchQueue.main.async {
                            guard self.isFeeding.withLock({ $0 }) else { return }
                            self.startFeedingVideo()
                        }
                    }
                }
            } else {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
        }
    }

    nonisolated private func displayLinkTick() {
        guard activeRenderMode == .metalToneMap else { return }
        let currentSyncTime = synchronizer.currentTime()
        guard currentSyncTime.isValid else { return }

        let start = CACurrentMediaTime()
        if let popped = frameQueue.popFrame(forSyncTime: currentSyncTime) {
            metalRenderer?.render(pixelBuffer: popped.pixelBuffer)
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            let qCount = frameQueue.count
            let isPaused = isVideoDrainPaused.withLock { $0 }
            let driftMs = popped.pts.isValid ? (popped.pts.seconds - currentSyncTime.seconds) * 1000.0 : 0.0
            let dropped = frameQueue.droppedFramesCount

            performanceMonitor.recordRenderedFrame(
                durationMs: durationMs,
                queueCount: qCount,
                renderModeName: "Metal SDR",
                isDrainPaused: isPaused,
                avSyncDriftMs: driftMs,
                droppedFrames: dropped
            )

            if !isMetalLayerVisibleLock.withLock({ $0 }) {
                isMetalLayerVisibleLock.withLock { $0 = true }
                DispatchQueue.main.async { [weak self] in
                    self?.isMetalLayerVisible = true
                }
            }
        }

        // Backpressure check: if feeding was paused due to full frame buffer, resume when queue drops to <= 25 frames
        if frameQueue.count <= 25 && isVideoDrainPaused.withLock({ $0 }) {
            checkBackpressureAndResumeIfNeeded()
        }
    }

    public func renderCurrentFrame() {
        let currentSyncTime = synchronizer.currentTime()
        if currentSyncTime.isValid, let buffer = frameQueue.getLatestFrame(forSyncTime: currentSyncTime) {
            metalRenderer?.render(pixelBuffer: buffer)
        } else if let lastBuffer = frameQueue.getLastRenderedBuffer() {
            metalRenderer?.render(pixelBuffer: lastBuffer)
        }
    }

    public func load(path: String) {
        print("[NativePlayerEngine] Loading:", path)
        guard let newDemuxer = MediaDemuxer(url: path) else {
            print("[NativePlayerEngine] Failed to open file with MediaDemuxer:", path)
            return
        }

        self.demuxer = newDemuxer
        self.duration = newDemuxer.durationSeconds
        self.videoWidth = newDemuxer.width
        self.videoHeight = newDemuxer.height
        self.mediaTitle = URL(fileURLWithPath: path).lastPathComponent
        self.audioTracks = newDemuxer.audioTracks
        self.selectedAudioTrackId = newDemuxer.selectedAudioTrackIndex
        self.isLoaded = true
        self.metalRenderer?.updateUniforms { uniforms in
            uniforms.sourcePeakNits = newDemuxer.maxPeakNits
            if newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                uniforms.colorPrimaries = 1
            } else if newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                || newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
            {
                uniforms.colorPrimaries = 2
            } else {
                uniforms.colorPrimaries = 0  // BT.2020
            }

            if newDemuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                || newDemuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
            {
                uniforms.transferFunction = 2  // SDR
            } else if newDemuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG {
                uniforms.transferFunction = 1  // HLG
            } else {
                uniforms.transferFunction = 0  // PQ
            }

            uniforms.bitDepth = UInt32(newDemuxer.bitDepth)
            uniforms.isFullRange = newDemuxer.isFullRange ? 1 : 0
            if newDemuxer.isDolbyVisionProfile5 {
                uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
            } else if newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                uniforms.colorSpaceMode = 1  // BT.709
            } else {
                uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
            }
        }
        // Update telemetry metadata
        let primariesStr: String = {
            if newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 { return "BT.709" }
            if newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                || newDemuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
            {
                return "DCI-P3"
            }
            return "BT.2020"
        }()
        let transferStr: String = {
            if newDemuxer.isDolbyVisionProfile5 { return "Dolby Vision (ICtCp)" }
            if newDemuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                || newDemuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
            {
                return "BT.709 / SDR"
            }
            if newDemuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG { return "HLG" }
            return "PQ (ST 2084)"
        }()
        performanceMonitor.updateStreamMetadata(
            resolution: "\(newDemuxer.width)x\(newDemuxer.height)",
            codecName: newDemuxer.codec == .hevc ? "HEVC" : "H.264",
            bitDepth: newDemuxer.bitDepth,
            colorPrimaries: primariesStr,
            transferFunction: transferStr,
            sourcePeakNits: newDemuxer.maxPeakNits,
            targetNits: 203.0
        )

        print(
            "[NativePlayerEngine] Loaded successfully. Duration: \(duration)s, peakNits: \(newDemuxer.maxPeakNits), formatDesc: \(String(describing: newDemuxer.formatDescription))"
        )

        // Initialize audio decoder if audio stream is present
        if newDemuxer.hasAudio, let audioParams = newDemuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: audioParams, timebase: newDemuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            print(
                "[NativePlayerEngine] Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(newDemuxer.audioChannels), rate: \(newDemuxer.audioSampleRate)"
            )
        } else {
            self.audioDecoder = nil
            print("[NativePlayerEngine] No audio track found or failed to get codec parameters")
        }

        isFeeding.withLock { $0 = false }
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        displayLayer.sampleBufferRenderer.flush()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioDecoder?.flush()

        let decoder = self.decoder
        feedQueue.async { [weak self] in
            decoder.flush()
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameQueue.clear(resetDroppedFrames: true)
                self.startFeeding()
                self.synchronizer.setRate(1.0, time: .zero)
                self.displayLink?.isPaused = false
                self.isPlaying = true
                self.performanceMonitor.handlePlaybackStateChange(isPlaying: true)
            }
        }
    }

    nonisolated private func checkBackpressureAndResumeIfNeeded() {
        let shouldResume = isVideoDrainPaused.withLock { isPaused -> Bool in
            if isPaused {
                isPaused = false
                return true
            }
            return false
        }
        guard shouldResume, isFeeding.withLock({ $0 }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFeeding.withLock({ $0 }) else { return }
            self.startFeedingVideo()
        }
    }

    private func startFeeding() {
        guard self.demuxer != nil else { return }
        isFeeding.withLock { $0 = true }
        isVideoDrainPaused.withLock { $0 = false }

        startFeedingVideo()
        startFeedingAudio()
    }

    private func startFeedingVideo() {
        guard let demuxer = self.demuxer else { return }
        let feedingLock = self.isFeeding
        let drainPausedLock = self.isVideoDrainPaused
        let modeLock = self.activeRenderModeLock
        nonisolated(unsafe) let renderer = self.displayLayer.sampleBufferRenderer

        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        let decoder = self.decoder
        let queue = self.frameQueue

        // Video feed loop
        renderer.requestMediaDataWhenReady(on: feedQueue) { [demuxer, queue] in
            while renderer.isReadyForMoreMediaData && feedingLock.withLock({ $0 }) {
                // Cooperative backpressure: If Metal tone mapping is active and frameQueue already has >=40 decoded frames (~1.6 seconds),
                // stop requesting media data from AVFoundation cleanly.
                // Do NOT break while isReadyForMoreMediaData is true, as AVFoundation will immediately re-invoke this block in a 100% CPU spin-loop!
                if modeLock.withLock({ $0 == .metalToneMap }) && queue.count >= 40 {
                    drainPausedLock.withLock { $0 = true }
                    renderer.stopRequestingMediaData()
                    break
                }

                if let sample = demuxer.nextVideoSample() {
                    nonisolated(unsafe) let sampleBuf = sample
                    let count = sampleCountLock.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    if count <= 5 || count % 200 == 0 {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuf)
                        print(
                            "[NativePlayerEngine] Enqueued sample #\(count), pts: \(CMTimeGetSeconds(pts))s, layer.status: \(renderer.status.rawValue)"
                        )
                    }

                    if modeLock.withLock({ $0 == .metalToneMap }) {
                        // Decode via VTVideoDecoder for Metal tone-mapping.
                        // Do NOT call renderer.enqueue(sampleBuf)! AVSampleBufferDisplayLayer decodes frames even when hidden,
                        // which causes 4K double-decoding and wastes 50-70% CPU.
                        let signpostID = PlayerPerformanceMonitor.shared.signposter.makeSignpostID()
                        let interval = PlayerPerformanceMonitor.shared.signposter.beginInterval(
                            "EnqueueDecodeFrame", id: signpostID)
                        decoder.decode(sampleBuffer: sampleBuf)
                        PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueDecodeFrame", interval)
                    } else {
                        // Native mode: Feed renderer directly
                        let signpostID = PlayerPerformanceMonitor.shared.signposter.makeSignpostID()
                        let interval = PlayerPerformanceMonitor.shared.signposter.beginInterval(
                            "EnqueueNativeSample", id: signpostID)
                        renderer.enqueue(sampleBuf)
                        PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueNativeSample", interval)
                        PlayerPerformanceMonitor.shared.recordNativeEnqueuedSample()
                    }
                } else {
                    print("[NativePlayerEngine] Demuxer returned nil.")
                    break
                }
            }
        }
    }

    private func startFeedingAudio() {
        guard let demuxer = self.demuxer else { return }
        let feedingLock = self.isFeeding
        nonisolated(unsafe) let aRenderer = self.audioRenderer

        // Audio feed loop
        // Let AVSampleBufferAudioRenderer manage its internal buffer backpressure via isReadyForMoreMediaData.
        // Artificial early breaking when isReadyForMoreMediaData is true causes AVFoundation to immediately
        // re-invoke this block in a 100% CPU busy-spin loop.
        if let aDecoder = self.audioDecoder {
            let audioTimebase = demuxer.audioTimebase
            audioRenderer.requestMediaDataWhenReady(on: audioFeedQueue) { [demuxer, aDecoder] in
                while aRenderer.isReadyForMoreMediaData && feedingLock.withLock({ $0 }) {
                    if let packet = demuxer.nextAudioPacket() {
                        let pcmBuffers = aDecoder.decode(
                            packetData: packet.data,
                            pts: packet.pts,
                            timebase: audioTimebase
                        )
                        for buf in pcmBuffers {
                            aRenderer.enqueue(buf)
                        }
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func selectAudioTrack(id: Int) {
        guard let demuxer = self.demuxer else { return }
        print("[NativePlayerEngine] Switching to audio track: \(id)")
        let wasPlaying = isPlaying
        pause()

        // Stop requesting data and flush renderers
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioDecoder?.flush()

        demuxer.selectAudioTrack(trackId: id)
        self.selectedAudioTrackId = id
        if let params = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        } else {
            self.audioDecoder = nil
        }

        if wasPlaying {
            play()
        }
    }

    public func play() {
        guard isLoaded else { return }
        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding()
        }
        synchronizer.setRate(1.0, time: synchronizer.currentTime())
        displayLink?.isPaused = false
        isPlaying = true
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        isPlaying = false
        performanceMonitor.handlePlaybackStateChange(isPlaying: false)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to seconds: Double) {
        print("[NativePlayerEngine] Seeking to seconds:", seconds)
        guard let demuxer = self.demuxer else { return }
        let wasPlaying = isPlaying
        pause()

        isFeeding.withLock { $0 = false }
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        displayLayer.sampleBufferRenderer.flush()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioDecoder?.flush()
        frameQueue.clear(resetDroppedFrames: true)

        currentTime = seconds
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 1000)

        let decoder = self.decoder
        nonisolated(unsafe) let renderer = self.displayLayer.sampleBufferRenderer
        feedQueue.async { [weak self, demuxer] in
            decoder.flush()
            demuxer.seek(to: seconds)

            guard let self else { return }

            if wasPlaying {
                DispatchQueue.main.async {
                    self.startFeeding()
                    self.synchronizer.setRate(1.0, time: targetTime)
                    self.displayLink?.isPaused = false
                    self.isPlaying = true
                }
            } else {
                let isMetalMode = self.activeRenderModeLock.withLock { $0 == .metalToneMap }
                var attempts = 0
                var foundTarget = false
                while attempts < 120 && !foundTarget {
                    if let sample = demuxer.nextVideoSample() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        if isMetalMode {
                            decoder.decode(sampleBuffer: sample)
                        } else {
                            renderer.enqueue(sample)
                        }
                        attempts += 1
                        if CMTimeGetSeconds(pts) >= seconds {
                            foundTarget = true
                        }
                    } else {
                        break
                    }
                }
                decoder.flush()
                DispatchQueue.main.async {
                    self.synchronizer.setRate(0.0, time: targetTime)
                    self.renderCurrentFrame()
                }
            }
        }
        print("[NativePlayerEngine] Seek initiated asynchronously to:", targetTime.seconds)
    }

    public func seekRelative(by seconds: Double) {
        let target = max(0, min(currentTime + seconds, duration))
        seek(to: target)
    }

    public func stepFrameForward() {
        if isPlaying { pause() }
        // Standard film frame step: 1/24 ≈ 0.04167s (or 1/23.976 ≈ 0.04171s)
        let frameDuration = 1.0 / 23.976
        seek(to: min(currentTime + frameDuration, duration))
    }

    public func stepFrameBackward() {
        if isPlaying { pause() }
        let frameDuration = 1.0 / 23.976
        seek(to: max(currentTime - frameDuration, 0))
    }

    isolated deinit {
        if let observer = timeObserver {
            synchronizer.removeTimeObserver(observer)
        }
        if let obs = audioConfigObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = audioAutoFlushObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        isFeeding.withLock { $0 = false }
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
    }
}
