@preconcurrency import AVFoundation
import AppKit
import CFFmpeg
@preconcurrency import CoreMedia
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
    public var isLoading: Bool = false
    public var loadError: String? = nil
    private var loadingTask: Task<Void, Never>?
    private var currentInterruptContext: MediaDemuxer.InterruptContext?
    private var currentLoadID = UUID()
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

    public func applyConfiguration(_ config: PlayerConfiguration) {
        self.configuration = config
        self.isToneMappingPermitted = config.enableToneMapping
        self.metalTargetNits = config.targetNits
        self.metalSharpness = config.sharpness
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

    nonisolated private static let enqueueSampleBufferSelector = sel_registerName("enqueueSampleBuffer:")
    nonisolated private static let flushSelector = sel_registerName("flush")

    nonisolated(unsafe) public let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated(unsafe) private let sampleBufferRenderer: AVSampleBufferVideoRenderer
    public let metalRenderer = MetalVideoRenderer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    public let audioReceiver: AVSampleBufferAudioRenderer.Receiver
    private var videoFeedingTask: Task<Void, Never>?
    private var audioFeedingTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?

    private let decoder = VTVideoDecoder()
    private var audioDecoder: FFAudioDecoder?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var demuxer: MediaDemuxer?
    private let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    private let audioFeedQueue = DispatchQueue(label: "com.nativeplayer.audiofeed", qos: .userInteractive)
    private var audioConfigObserver: (any NSObjectProtocol)?
    private var audioAutoFlushObserver: (any NSObjectProtocol)?
    private var timeObserver: Any?
    private var lastSavedProgressSeconds: Double = 0.0
    private var configuration: PlayerConfiguration
    private var currentPath: String?
    public let historyStore: PlaybackHistoryStore
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
    private var metricsTimer: (any DispatchSourceTimer)?

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

    public init(configuration: PlayerConfiguration, historyStore: PlaybackHistoryStore = .shared) {
        self.configuration = configuration
        self.historyStore = historyStore
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        self.metalTargetNits = configuration.targetNits
        self.metalSharpness = configuration.sharpness
        self.volume = configuration.initialVolume

        metalRenderer?.uniforms.targetNits = configuration.targetNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
        self.sampleBufferRenderer = displayLayer.sampleBufferRenderer
        // Synchronizer manages audio receiver and master clock timeline
        self.audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        displayLayer.videoGravity = .resizeAspect

        // Configure displayLayer with independent host timebase matching KSPlayer
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &controlTimebase
        )
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }

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
                    // Throttled periodic progress auto-save every 15 seconds
                    if abs(seconds - self.lastSavedProgressSeconds) >= 15.0 {
                        self.lastSavedProgressSeconds = seconds
                        self.saveCurrentPlaybackProgress()
                    }
                }
            }
        }
    }

    private func setupAudioObservers() {
        // macOS 27.0+: Spatial Audio reconfiguration and route changes are signaled
        // via AVSampleBufferAudioRenderer.Receiver enqueue(_:) result (.enqueuedWithSuggestedFlush),
        // which automatically triggers flush and reload where needed.
    }

    private func handleAudioConfigurationChange() {
        guard isPlaying else { return }
        print(
            "[NativePlayerEngine] Audio configuration changed (Spatial Audio toggle or route change)"
        )
        audioReceiver.flush()
        audioDecoder?.flush()
    }

    private func setupMetricsMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.showDebugHUD else { return }
            let statusDesc = self.isPlaying ? "Rendering" : "Paused"
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
            isMetalLayerVisible = false
            if !isPlaying {
                renderCurrentFrame()
            }
        } else {
            if !isPlaying {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
        }
    }

    nonisolated private func presentToDisplayLayer(pixelBuffer: CVPixelBuffer) {
        var formatDescription: CMVideoFormatDescription?
        let err = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard err == noErr, let formatDesc = formatDescription else { return }

        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: [timing],
            sampleBufferOut: &sampleBuffer
        )
        guard let sample = sampleBuffer else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary],
            let dic = attachmentsArray.first
        {
            dic[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        _ = sampleBufferRenderer.perform(Self.enqueueSampleBufferSelector, with: sample)
    }

    nonisolated private func displayLinkTick() {
        let currentSyncTime = synchronizer.currentTime()
        guard currentSyncTime.isValid else { return }

        let start = CACurrentMediaTime()
        if let popped = frameQueue.popFrame(forSyncTime: currentSyncTime) {
            let durationMs = (CACurrentMediaTime() - start) * 1000.0
            let qCount = frameQueue.count
            let isPaused = isVideoDrainPaused.withLock { $0 }
            let driftMs = popped.pts.isValid ? (popped.pts.seconds - currentSyncTime.seconds) * 1000.0 : 0.0
            let dropped = frameQueue.droppedFramesCount

            let mode = activeRenderMode
            if mode == .metalToneMap {
                metalRenderer?.render(pixelBuffer: popped.pixelBuffer)
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
            } else {
                presentToDisplayLayer(pixelBuffer: popped.pixelBuffer)
                performanceMonitor.recordRenderedFrame(
                    durationMs: durationMs,
                    queueCount: qCount,
                    renderModeName: "Apple HDR (AVSBDL)",
                    isDrainPaused: isPaused,
                    avSyncDriftMs: driftMs,
                    droppedFrames: dropped
                )

                if isMetalLayerVisibleLock.withLock({ $0 }) {
                    isMetalLayerVisibleLock.withLock { $0 = false }
                    DispatchQueue.main.async { [weak self] in
                        self?.isMetalLayerVisible = false
                    }
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
        let buffer: CVPixelBuffer?
        if currentSyncTime.isValid, let b = frameQueue.getLatestFrame(forSyncTime: currentSyncTime) {
            buffer = b
        } else {
            buffer = frameQueue.getLastRenderedBuffer()
        }

        guard let buffer else { return }
        if activeRenderMode == .metalToneMap {
            metalRenderer?.render(pixelBuffer: buffer)
        } else {
            presentToDisplayLayer(pixelBuffer: buffer)
        }
    }

    public func load(path: String) {
        load(path: path, headers: [:], startTime: nil)
    }

    public func load(path: String, headers: [String: String]) {
        load(path: path, headers: headers, startTime: nil)
    }

    public func load(path: String, headers: [String: String], startTime: Double?) {
        let isNetwork = MediaDemuxer.isNetworkURL(path)
        if isNetwork {
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsync(path: path, headers: headers, startTime: startTime)
            }
        } else {
            loadSync(path: path, headers: headers, startTime: startTime)
        }
    }

    public func loadAsync(path: String) async {
        await loadAsync(path: path, headers: [:], startTime: nil)
    }

    public func loadAsync(path: String, headers: [String: String]) async {
        await loadAsync(path: path, headers: headers, startTime: nil)
    }

    public func loadAsync(path: String, headers: [String: String], startTime: Double?) async {
        print(
            "[NativePlayerEngine] Loading async:", path, "with headers count:", headers.count, "startTime:",
            String(describing: startTime))

        // Save progress for previously active media if present
        saveCurrentPlaybackProgress()

        // Generate a new load ID and cancel any in-flight requests immediately
        let loadID = UUID()
        self.currentLoadID = loadID

        currentInterruptContext?.cancel()
        demuxer?.cancel()
        demuxer = nil

        let interruptContext = MediaDemuxer.InterruptContext()
        self.currentInterruptContext = interruptContext

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        isLoaded = false
        isLoading = true
        loadError = nil

        let task = Task.detached(priority: .userInitiated) { () -> MediaDemuxer? in
            guard !Task.isCancelled, !interruptContext.isCancelled else { return nil }
            return MediaDemuxer(url: path, headers: headers, interruptContext: interruptContext)
        }

        let newDemuxer = await task.value

        // Prevent race condition: if another load started or task was cancelled, discard result
        guard self.currentLoadID == loadID, !Task.isCancelled, !interruptContext.isCancelled else {
            print("[NativePlayerEngine] Loading was superseded or cancelled for:", path)
            return
        }

        guard let demuxer = newDemuxer else {
            print("[NativePlayerEngine] Failed to open file or network stream:", path)
            self.isLoading = false
            self.loadError = "Failed to open stream or media file."
            return
        }

        applyLoadedDemuxer(demuxer, path: path, requestedStartTime: startTime)
    }

    private func loadSync(path: String, headers: [String: String], startTime: Double?) {
        print("[NativePlayerEngine] Loading sync:", path, "startTime:", String(describing: startTime))

        // Save progress for previously active media if present
        saveCurrentPlaybackProgress()

        let loadID = UUID()
        self.currentLoadID = loadID

        loadingTask?.cancel()
        loadingTask = nil
        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        isLoaded = false
        isLoading = false
        loadError = nil

        guard let demuxer = MediaDemuxer(url: path, headers: headers) else {
            print("[NativePlayerEngine] Failed to open file:", path)
            self.loadError = "Failed to open media file."
            return
        }

        applyLoadedDemuxer(demuxer, path: path, requestedStartTime: startTime)
    }

    public func stop() {
        saveCurrentPlaybackProgress()
        loadingTask?.cancel()
        loadingTask = nil
        currentInterruptContext?.cancel()
        currentInterruptContext = nil
        demuxer?.cancel()
        demuxer = nil
        pause()
    }

    public func saveCurrentPlaybackProgress() {
        guard let path = currentPath, duration > 0, currentTime > 0 else { return }
        historyStore.savePosition(
            for: path,
            position: currentTime,
            duration: duration,
            startThreshold: configuration.resumeStartThreshold,
            endThresholdRatio: configuration.resumeEndThresholdRatio
        )
    }

    private func applyLoadedDemuxer(_ demuxer: MediaDemuxer, path: String, requestedStartTime: Double?) {
        self.demuxer = demuxer
        self.currentPath = path
        self.duration = demuxer.durationSeconds
        self.videoWidth = demuxer.width
        self.videoHeight = demuxer.height
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if let url = URL(string: path) {
                self.mediaTitle = url.lastPathComponent.isEmpty ? url.host ?? path : url.lastPathComponent
            } else {
                self.mediaTitle = path
            }
        } else {
            self.mediaTitle = URL(fileURLWithPath: path).lastPathComponent
        }
        self.audioTracks = demuxer.audioTracks
        self.selectedAudioTrackId = demuxer.selectedAudioTrackIndex
        self.isLoading = false
        self.isLoaded = true
        self.loadError = nil

        self.metalRenderer?.updateUniforms { uniforms in
            uniforms.sourcePeakNits = demuxer.maxPeakNits
            if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                uniforms.colorPrimaries = 1
            } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
            {
                uniforms.colorPrimaries = 2
            } else {
                uniforms.colorPrimaries = 0  // BT.2020
            }

            if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
            {
                uniforms.transferFunction = 2  // SDR
            } else if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG {
                uniforms.transferFunction = 1  // HLG
            } else {
                uniforms.transferFunction = 0  // PQ
            }

            uniforms.bitDepth = UInt32(demuxer.bitDepth)
            uniforms.isFullRange = demuxer.isFullRange ? 1 : 0
            if demuxer.isDolbyVisionProfile5 {
                uniforms.colorSpaceMode = 2  // Dolby Vision IPT / ICtCp
            } else if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 {
                uniforms.colorSpaceMode = 1  // BT.709
            } else {
                uniforms.colorSpaceMode = 0  // Standard BT.2020 YCbCr
            }
        }

        // Update telemetry metadata
        let primariesStr: String = {
            if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 { return "BT.709" }
            if demuxer.colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3
                || demuxer.colorPrimaries == kCVImageBufferColorPrimaries_P3_D65
            {
                return "DCI-P3"
            }
            return "BT.2020"
        }()
        let transferStr: String = {
            if demuxer.isDolbyVisionProfile5 { return "Dolby Vision (ICtCp)" }
            if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2
                || demuxer.transferFunction == kCVImageBufferTransferFunction_UseGamma
            {
                return "BT.709 / SDR"
            }
            if demuxer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG { return "HLG" }
            return "PQ (ST 2084)"
        }()
        self.performanceMonitor.updateStreamMetadata(
            resolution: "\(demuxer.width)x\(demuxer.height)",
            codecName: demuxer.codec == .hevc ? "HEVC" : "H.264",
            bitDepth: demuxer.bitDepth,
            colorPrimaries: primariesStr,
            transferFunction: transferStr,
            sourcePeakNits: demuxer.maxPeakNits,
            targetNits: 203.0
        )

        print(
            "[NativePlayerEngine] Loaded successfully. Duration: \(self.duration)s, peakNits: \(demuxer.maxPeakNits), formatDesc: \(String(describing: demuxer.formatDescription))"
        )

        // Initialize audio decoder if audio stream is present
        if demuxer.hasAudio, let audioParams = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: audioParams, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            print(
                "[NativePlayerEngine] Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(demuxer.audioChannels), rate: \(demuxer.audioSampleRate)"
            )
        } else {
            self.audioDecoder = nil
            print("[NativePlayerEngine] No audio track found or failed to get codec parameters")
        }

        _ = self.sampleBufferRenderer.perform(Self.flushSelector)
        self.audioReceiver.flush()
        self.audioDecoder?.flush()

        // Determine effective start time using the priority chain:
        // 1. Explicit requestedStartTime (Emby, CLI, deep link)
        // 2. PlaybackHistoryStore saved position (if resume is enabled)
        // 3. Fallback to 0.0
        let effectiveStartTime: Double
        if let explicit = requestedStartTime, explicit > 0 {
            effectiveStartTime = min(explicit, max(0.0, self.duration - 1.0))
            print("[NativePlayerEngine] Using explicit start time: \(effectiveStartTime)s (ignoring history)")
        } else if configuration.resumePlayback,
            let saved = historyStore.savedPosition(
                for: path,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.duration - 1.0))
            print("[NativePlayerEngine] Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        if effectiveStartTime > 0 {
            demuxer.seek(to: effectiveStartTime)
        }

        let decoder = self.decoder
        self.feedQueue.async { [weak self] in
            decoder.flush()
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameQueue.clear(resetDroppedFrames: true)
                self.startFeeding()
                let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
                self.currentTime = effectiveStartTime
                self.synchronizer.setRate(1.0, time: targetCMTime)
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

    private func stopFeedingVideo() {
        videoFeedingTask?.cancel()
        videoFeedingTask = nil
    }

    private func stopFeedingAudio() {
        audioFeedingTask?.cancel()
        audioFeedingTask = nil
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
        stopFeedingVideo()

        let feedingLock = self.isFeeding
        let drainPausedLock = self.isVideoDrainPaused
        let decoder = self.decoder
        let queue = self.frameQueue

        videoFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runVideoFeeding(
                demuxer: demuxer,
                decoder: decoder,
                queue: queue,
                feedingLock: feedingLock,
                drainPausedLock: drainPausedLock
            )
        }
    }

    private nonisolated static func runVideoFeeding(
        demuxer: MediaDemuxer,
        decoder: VTVideoDecoder,
        queue: FrameQueue,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        drainPausedLock: OSAllocatedUnfairLock<Bool>
    ) async {
        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            // Cooperative backpressure: pause decoding when queue has >= 40 frames
            if queue.count >= 40 {
                drainPausedLock.withLock { $0 = true }
                while !Task.isCancelled && queue.count > 25 && feedingLock.withLock({ $0 }) {
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                }
                drainPausedLock.withLock { $0 = false }
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
            }

            guard let sample = demuxer.nextVideoSample() else {
                if demuxer.isEOF {
                    print("[NativePlayerEngine] Demuxer reached EOF for video.")
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }

            let count = sampleCountLock.withLock { count -> Int in
                count += 1
                return count
            }
            if count <= 5 || count % 200 == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                print(
                    "[NativePlayerEngine] Decoding video sample #\(count), pts: \(CMTimeGetSeconds(pts))s, queueCount: \(queue.count)"
                )
            }

            let signpostID = PlayerPerformanceMonitor.shared.signposter.makeSignpostID()
            let interval = PlayerPerformanceMonitor.shared.signposter.beginInterval(
                "EnqueueDecodeFrame", id: signpostID)
            decoder.decode(sampleBuffer: sample)
            PlayerPerformanceMonitor.shared.signposter.endInterval("EnqueueDecodeFrame", interval)
        }
    }

    private func startFeedingAudio() {
        guard let demuxer = self.demuxer, let aDecoder = self.audioDecoder else { return }
        stopFeedingAudio()

        let feedingLock = self.isFeeding
        let receiver = self.audioReceiver
        let audioTimebase = demuxer.audioTimebase

        audioFeedingTask = Task.detached(priority: .userInitiated) {
            await Self.runAudioFeeding(
                demuxer: demuxer,
                audioDecoder: aDecoder,
                receiver: receiver,
                feedingLock: feedingLock,
                audioTimebase: audioTimebase
            )
        }
    }

    private nonisolated static func runAudioFeeding(
        demuxer: MediaDemuxer,
        audioDecoder: FFAudioDecoder,
        receiver: AVSampleBufferAudioRenderer.Receiver,
        feedingLock: OSAllocatedUnfairLock<Bool>,
        audioTimebase: AVRational
    ) async {
        while !Task.isCancelled && feedingLock.withLock({ $0 }) {
            guard let packet = demuxer.nextAudioPacket() else {
                if demuxer.isEOF {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            let pcmBuffers = audioDecoder.decode(
                packetData: packet.data,
                pts: packet.pts,
                timebase: audioTimebase
            )
            for buf in pcmBuffers {
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
                nonisolated(unsafe) let sBuf = buf
                let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: sBuf)
                _ = try? await receiver.enqueue(ready)
            }
        }
    }

    public func selectAudioTrack(id: Int) {
        guard let demuxer = self.demuxer else { return }
        print("[NativePlayerEngine] Switching to audio track: \(id)")
        let wasPlaying = isPlaying
        pause()

        // Stop requesting data and flush renderers
        stopFeedingAudio()
        audioReceiver.flush()
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
        stopFeedingVideo()
        stopFeedingAudio()
        seekTask?.cancel()
        seekTask = nil
        isPlaying = false
        performanceMonitor.handlePlaybackStateChange(isPlaying: false)
        saveCurrentPlaybackProgress()
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
        stopFeedingVideo()
        stopFeedingAudio()
        _ = sampleBufferRenderer.perform(Self.flushSelector)
        audioReceiver.flush()
        audioDecoder?.flush()
        frameQueue.clear(resetDroppedFrames: true)

        currentTime = seconds
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 1000)

        let decoder = self.decoder

        seekTask = Task.detached(priority: .userInitiated) { [weak self, demuxer, decoder] in
            decoder.flush()
            demuxer.seek(to: seconds)

            guard !Task.isCancelled else { return }

            if wasPlaying {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.startFeeding()
                    self.synchronizer.setRate(1.0, time: targetTime)
                    self.displayLink?.isPaused = false
                    self.isPlaying = true
                }
            } else {
                Self.seekPreview(
                    demuxer: demuxer,
                    decoder: decoder,
                    seconds: seconds
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.synchronizer.setRate(0.0, time: targetTime)
                    self.renderCurrentFrame()
                }
            }
        }
        print("[NativePlayerEngine] Seek initiated asynchronously to:", targetTime.seconds)
    }

    private nonisolated static func seekPreview(
        demuxer: MediaDemuxer,
        decoder: VTVideoDecoder,
        seconds: Double
    ) {
        var attempts = 0
        var foundTarget = false
        while attempts < 120 && !foundTarget && !Task.isCancelled {
            if let sample = demuxer.nextVideoSample() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                decoder.decode(sampleBuffer: sample)
                attempts += 1
                if CMTimeGetSeconds(pts) >= seconds {
                    foundTarget = true
                }
            } else {
                break
            }
        }
        decoder.flush()
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

    public func stepVolume(by delta: Float) {
        volume = max(0.0, min(1.0, volume + delta))
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    public func toggleDebugHUD() {
        showDebugHUD.toggle()
    }

    isolated deinit {
        stop()
        seekTask?.cancel()
        seekTask = nil
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
        stopFeedingVideo()
        stopFeedingAudio()
    }
}
