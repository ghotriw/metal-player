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
public final class PlayerEngine: PlayerEngineProtocol {
    public var currentTime: Double = 0
    public var duration: Double = 0
    public var isPlaying: Bool = false
    public var isLoaded: Bool = false
    public var isLoading: Bool = false
    public var loadError: String? = nil
    public var playbackState: PlaybackState = .idle {
        didSet {
            if oldValue != playbackState {
                onPlaybackStateChanged?(playbackState)
            }
        }
    }

    /// Periodic time observer callback for external clients (e.g. Coordinator / Bridge)
    public var onTimeUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    /// State change callback for external clients
    public var onPlaybackStateChanged: ((_ state: PlaybackState) -> Void)?

    private var loadingTask: Task<Void, Never>?
    private var currentInterruptContext: MediaDemuxer.InterruptContext?
    private var currentLoadID = UUID()
    public var mediaTitle: String = ""
    public var artworkData: Data? = nil
    public var artworkURL: URL? = nil
    public var hasVideo: Bool = false
    public var videoWidth: Int = 0
    public var videoHeight: Int = 0
    public var isHDRContent: Bool = false {
        didSet {
            if oldValue != isHDRContent {
                updateEffectiveRenderMode()
            }
        }
    }
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
    private let activeRenderModeLock = OSAllocatedUnfairLock(initialState: RenderMode.system)
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
        self.subtitleFontSize = config.subtitleFontSize
        self.subtitleTextColorHex = config.subtitleTextColorHex
        self.subtitleBgColorHex = config.subtitleBgColorHex
        self.subtitleBgOpacity = config.subtitleBgOpacity
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

    public var subtitleTracks: [SubtitleTrack] = []
    public var selectedSubtitleTrackId: Int? = nil
    public var currentSubtitleCue: SubtitleCue? {
        currentSubtitleCues.first
    }
    public var currentSubtitleCues: [SubtitleCue] = []
    public var currentSubtitleText: String? {
        currentSubtitleCue?.text
    }
    public var subtitleFontSize: Double = 24.0
    public var subtitleTextColorHex: String = "#FFFFFF"
    public var subtitleBgColorHex: String = "#000000"
    public var subtitleBgOpacity: Double = 0.65
    private var activeSubtitleDocument: SubtitleDocument? = nil
    private var lastObservedLiveSubtitleVersion: Int = -1

    private func updateActiveSubtitles(at seconds: Double) {
        if let id = selectedSubtitleTrackId,
            let track = subtitleTracks.first(where: { $0.id == id }),
            !track.isExternal,
            let demuxer,
            let path = currentPath,
            MediaDemuxer.isNetworkURL(path)
        {
            // For live network streams, refresh the document only when in-band cues version changes
            let currentVersion = demuxer.liveSubtitleVersion
            if currentVersion != self.lastObservedLiveSubtitleVersion || self.activeSubtitleDocument == nil {
                self.lastObservedLiveSubtitleVersion = currentVersion
                self.activeSubtitleDocument = demuxer.getLiveSubtitleDocument()
            }
            if let doc = self.activeSubtitleDocument {
                self.currentSubtitleCues = doc.activeCues(at: seconds)
            } else {
                self.currentSubtitleCues = []
            }
            return
        }

        if let doc = self.activeSubtitleDocument {
            self.currentSubtitleCues = doc.activeCues(at: seconds)
        } else {
            self.currentSubtitleCues = []
        }
    }
    private var loadedSubtitleDocuments: [Int: SubtitleDocument] = [:]
    private var currentHeaders: [String: String] = [:]

    nonisolated private static let enqueueSampleBufferSelector = sel_registerName("enqueueSampleBuffer:")
    nonisolated private static let flushSelector = sel_registerName("flush")
    nonisolated private static let flushRemovingImageSelector = sel_registerName(
        "flushWithRemovalOfDisplayedImage:completionHandler:")

    /// Calls `flush(removingDisplayedImage: true)` via the Objective-C runtime.
    /// The display layer is deliberately NOT attached to the render synchronizer (see video_architecture.md 3.1),
    /// so the receiver-based replacement API is unavailable; this avoids the deprecation warning.
    nonisolated private static func flushRemovingDisplayedImage(_ renderer: NSObject) {
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, @escaping @convention(block) () -> Void) -> Void
        guard renderer.responds(to: flushRemovingImageSelector),
            let imp = renderer.method(for: flushRemovingImageSelector)
        else {
            _ = renderer.perform(flushSelector)
            return
        }
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(renderer, flushRemovingImageSelector, true, {})
    }

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
    private let seekQueue = DispatchQueue(label: "com.nativeplayer.seek", qos: .userInteractive)
    private var currentSeekId: Int = 0
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
        private weak var engine: PlayerEngine?

        init(engine: PlayerEngine) {
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
        self.subtitleFontSize = configuration.subtitleFontSize
        self.subtitleTextColorHex = configuration.subtitleTextColorHex
        self.subtitleBgColorHex = configuration.subtitleBgColorHex
        self.subtitleBgOpacity = configuration.subtitleBgOpacity

        metalRenderer?.uniforms.targetNits = configuration.targetNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
        self.sampleBufferRenderer = displayLayer.sampleBufferRenderer
        // Synchronizer manages audio receiver and master clock timeline
        self.audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
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
                    self.onTimeUpdate?(seconds, self.duration)

                    // Update active subtitle cues
                    self.updateActiveSubtitles(at: seconds)

                    // Check if playback reached the end
                    if self.isPlaying && self.duration > 0 && seconds >= (self.duration - 0.25) {
                        self.stopPlaybackPipeline()
                        self.playbackState = .completed
                        self.saveCurrentPlaybackProgress()
                    }
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
        AppLog.info(
            .audio,
            "Audio configuration changed (Spatial Audio toggle or route change)"
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
            // Metal tone mapping is ONLY needed when video content is HDR and display is SDR
            if isHDRContent && !isHDRDisplay && isToneMappingPermitted {
                newMode = .metalToneMap
            } else {
                newMode = .system
            }
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

    /// Completely flushes and clears the video display layer and Metal canvas, removing any lingering video frame.
    public func clearVideoSurface() {
        frameQueue.clear(resetDroppedFrames: true)
        Self.flushRemovingDisplayedImage(sampleBufferRenderer)
        metalRenderer?.clear()
    }

    /// Resolves the user-facing media title from a file/stream path, falling back to
    /// URL host or file name if no explicit title is provided.
    nonisolated public static func resolveTitle(from path: String, explicitTitle: String? = nil) -> String {
        if let explicitTitle, !explicitTitle.isEmpty {
            return explicitTitle
        }
        if MediaDemuxer.isNetworkURL(path), let url = URL(string: path) {
            let last = url.lastPathComponent
            if last.isEmpty || last == "/" {
                return url.host ?? path
            }
            return last
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    public func load(path: String) {
        load(path: path, title: nil, headers: [:], startTime: nil)
    }

    public func load(path: String, title: String?) {
        load(path: path, title: title, headers: [:], startTime: nil)
    }

    public func load(path: String, headers: [String: String]) {
        load(path: path, title: nil, headers: headers, startTime: nil)
    }

    public func load(path: String, headers: [String: String], startTime: Double?) {
        load(path: path, title: nil, headers: headers, startTime: startTime)
    }

    public func load(
        path: String,
        title: String? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) {
        load(
            path: path,
            title: title,
            artworkData: nil,
            artworkURL: nil,
            headers: headers,
            startTime: startTime
        )
    }

    public func load(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) {
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        let isNetwork = MediaDemuxer.isNetworkURL(path)
        if isNetwork {
            loadingTask?.cancel()
            loadingTask = Task { @MainActor [weak self] in
                await self?.loadAsync(
                    path: path,
                    title: title,
                    artworkData: artworkData,
                    artworkURL: artworkURL,
                    headers: headers,
                    startTime: startTime
                )
            }
        } else {
            loadSync(
                path: path,
                title: title,
                artworkData: artworkData,
                artworkURL: artworkURL,
                headers: headers,
                startTime: startTime
            )
        }
    }

    public func loadAsync(path: String) async {
        await loadAsync(path: path, title: nil, headers: [:], startTime: nil)
    }

    public func loadAsync(path: String, title: String?) async {
        await loadAsync(path: path, title: title, headers: [:], startTime: nil)
    }

    public func loadAsync(path: String, headers: [String: String]) async {
        await loadAsync(path: path, title: nil, headers: headers, startTime: nil)
    }

    public func loadAsync(
        path: String,
        title: String? = nil,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) async {
        await loadAsync(
            path: path,
            title: title,
            artworkData: nil,
            artworkURL: nil,
            headers: headers,
            startTime: startTime
        )
    }

    public func loadAsync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String] = [:],
        startTime: Double? = nil
    ) async {
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        AppLog.info(
            .engine,
            "Loading async: \(path) title: \(self.mediaTitle) with headers count: \(headers.count) startTime: \(String(describing: startTime))"
        )

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
        clearVideoSurface()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        isLoaded = false
        isLoading = true
        loadError = nil
        playbackState = .loading

        let task = Task.detached(priority: .userInitiated) { () -> MediaDemuxer? in
            guard !Task.isCancelled, !interruptContext.isCancelled else { return nil }
            return MediaDemuxer(url: path, headers: headers, interruptContext: interruptContext)
        }

        let newDemuxer = await task.value

        // Prevent race condition: if another load started or task was cancelled, discard result
        if self.currentLoadID != loadID || Task.isCancelled || interruptContext.isCancelled {
            AppLog.warning(.engine, "Loading was superseded or cancelled for: \(path)")
            if self.currentLoadID == loadID {
                self.isLoading = false
                self.playbackState = .idle
            }
            return
        }

        guard let demuxer = newDemuxer else {
            AppLog.error(.engine, "Failed to open file or network stream: \(path)")
            self.isLoading = false
            let err = "Failed to open stream or media file."
            self.loadError = err
            self.playbackState = .failed(err)
            return
        }

        applyLoadedDemuxer(demuxer, path: path, headers: headers, requestedStartTime: startTime)
    }

    private func loadSync(
        path: String,
        title: String?,
        artworkData: Data?,
        artworkURL: URL?,
        headers: [String: String],
        startTime: Double?
    ) {
        self.mediaTitle = Self.resolveTitle(from: path, explicitTitle: title)
        self.artworkData = artworkData
        self.artworkURL = artworkURL
        AppLog.info(
            .engine,
            "Loading sync: \(path) title: \(self.mediaTitle) startTime: \(String(describing: startTime))"
        )

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
        clearVideoSurface()
        displayLink?.isPaused = true
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        isPlaying = false
        isLoaded = false
        isLoading = false
        loadError = nil
        playbackState = .loading

        guard let demuxer = MediaDemuxer(url: path, headers: headers) else {
            AppLog.error(.engine, "Failed to open file: \(path)")
            let err = "Failed to open media file."
            self.loadError = err
            self.playbackState = .failed(err)
            return
        }

        applyLoadedDemuxer(demuxer, path: path, headers: headers, requestedStartTime: startTime)
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
        clearVideoSurface()
        mediaTitle = ""
        artworkData = nil
        artworkURL = nil
        isLoaded = false
        currentTime = 0
        duration = 0
        playbackState = .idle
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

    private func applyLoadedDemuxer(
        _ demuxer: MediaDemuxer, path: String, headers: [String: String], requestedStartTime: Double?
    ) {
        self.demuxer = demuxer
        self.currentPath = path
        self.currentHeaders = headers
        self.hasVideo = demuxer.hasVideo
        self.duration = demuxer.durationSeconds
        self.videoWidth = demuxer.width
        self.videoHeight = demuxer.height
        self.isHDRContent = demuxer.isHDR
        if self.mediaTitle.isEmpty {
            self.mediaTitle = Self.resolveTitle(from: path)
        }
        // Fall back to embedded container artwork if no explicit artwork data was provided
        if self.artworkData == nil, let embedded = demuxer.embeddedArtworkData {
            self.artworkData = embedded
        }
        self.audioTracks = demuxer.audioTracks
        self.selectedAudioTrackId = demuxer.selectedAudioTrackIndex
        self.subtitleTracks = demuxer.subtitleTracks
        self.selectedSubtitleTrackId = nil
        self.activeSubtitleDocument = nil
        self.currentSubtitleCues.removeAll()
        self.loadedSubtitleDocuments.removeAll()
        self.lastObservedLiveSubtitleVersion = -1
        self.isLoading = false
        self.isLoaded = true
        self.loadError = nil

        if demuxer.hasVideo {
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
        }

        AppLog.info(
            .engine,
            "Loaded successfully. Duration: \(self.duration)s, peakNits: \(demuxer.maxPeakNits), formatDesc: \(String(describing: demuxer.formatDescription))"
        )

        // Initialize audio decoder if audio stream is present
        if demuxer.hasAudio, let audioParams = demuxer.getAudioCodecParameters() {
            let decoder = FFAudioDecoder(codecParameters: audioParams, timebase: demuxer.audioTimebase)
            self.audioDecoder = decoder
            self.audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            AppLog.info(
                .audio,
                "Audio decoder initialized: \(String(describing: self.audioDecoder != nil)), channels: \(demuxer.audioChannels), rate: \(demuxer.audioSampleRate)"
            )
        } else {
            self.audioDecoder = nil
            AppLog.warning(.audio, "No audio track found or failed to get codec parameters")
        }

        if !demuxer.hasVideo {
            clearVideoSurface()
        } else {
            _ = self.sampleBufferRenderer.perform(Self.flushSelector)
        }
        self.audioReceiver.flush()
        self.audioDecoder?.flush()

        // Determine effective start time using the priority chain:
        // 1. Explicit requestedStartTime (Emby, CLI, deep link)
        // 2. PlaybackHistoryStore saved position (if resume is enabled)
        // 3. Fallback to 0.0
        let effectiveStartTime: Double
        if let explicit = requestedStartTime, explicit > 0 {
            effectiveStartTime = min(explicit, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Using explicit start time: \(effectiveStartTime)s (ignoring history)")
        } else if configuration.resumePlayback,
            let saved = historyStore.savedPosition(
                for: path,
                startThreshold: configuration.resumeStartThreshold,
                endThresholdRatio: configuration.resumeEndThresholdRatio
            )
        {
            effectiveStartTime = min(saved, max(0.0, self.duration - 1.0))
            AppLog.info(.engine, "Resuming playback from saved history: \(effectiveStartTime)s")
        } else {
            effectiveStartTime = 0.0
        }

        if effectiveStartTime > 0 {
            demuxer.seek(to: effectiveStartTime)
        }

        let decoder = self.decoder
        let hasVideo = demuxer.hasVideo
        self.feedQueue.async { [weak self] in
            if hasVideo {
                decoder.flush()
            }
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameQueue.clear(resetDroppedFrames: true)
                self.startFeeding()
                let targetCMTime = CMTime(seconds: effectiveStartTime, preferredTimescale: 60000)
                self.currentTime = effectiveStartTime
                self.synchronizer.setRate(1.0, time: targetCMTime)
                self.displayLink?.isPaused = !hasVideo
                self.isPlaying = true
                self.playbackState = .playing
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
        guard let demuxer = self.demuxer else { return }
        isFeeding.withLock { $0 = true }
        isVideoDrainPaused.withLock { $0 = false }

        if demuxer.hasVideo {
            startFeedingVideo()
        }
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
                    AppLog.debug(.engine, "Demuxer reached EOF for video.")
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
                AppLog.debug(
                    .video,
                    "Decoding video sample #\(count), pts: \(CMTimeGetSeconds(pts))s, queueCount: \(queue.count)"
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
        AppLog.info(.audio, "Switching to audio track: \(id)")
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

    public func selectSubtitleTrack(id: Int?) {
        guard let id else {
            // Disable subtitles
            self.selectedSubtitleTrackId = nil
            self.activeSubtitleDocument = nil
            self.currentSubtitleCues.removeAll()
            self.lastObservedLiveSubtitleVersion = -1
            demuxer?.selectSubtitleTrack(trackId: nil)
            return
        }

        guard let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        self.selectedSubtitleTrackId = id
        demuxer?.selectSubtitleTrack(trackId: id)

        if track.isExternal {
            self.activeSubtitleDocument = loadedSubtitleDocuments[id]
            self.updateActiveSubtitles(at: currentTime)
        } else if let path = currentPath {
            if MediaDemuxer.isNetworkURL(path) {
                // For network streams: bind immediately to in-band demuxed cues.
                // Do NOT launch a background secondary demuxer that hangs trying to reach EOF or fails on single-token URLs.
                let liveDoc = demuxer?.getLiveSubtitleDocument() ?? SubtitleDocument(cues: [])
                self.lastObservedLiveSubtitleVersion = demuxer?.liveSubtitleVersion ?? -1
                self.activeSubtitleDocument = liveDoc
                self.updateActiveSubtitles(at: currentTime)
                AppLog.info(
                    .subtitles,
                    "Selected network subtitle track id=\(id) ('\(track.title)'). Active in-band streaming."
                )
            } else if let cached = loadedSubtitleDocuments[id] {
                self.activeSubtitleDocument = cached
                self.updateActiveSubtitles(at: currentTime)
            } else {
                let headers = self.currentHeaders
                let demuxer = self.demuxer
                Task.detached(priority: .userInitiated) { [weak self, demuxer, path, headers] in
                    let doc = demuxer?.loadSubtitleDocument(for: id, url: path, headers: headers)
                    await MainActor.run {
                        guard let self, self.selectedSubtitleTrackId == id else { return }
                        if let doc {
                            self.loadedSubtitleDocuments[id] = doc
                            self.activeSubtitleDocument = doc
                            self.updateActiveSubtitles(at: self.currentTime)
                        } else {
                            AppLog.warning(
                                .subtitles,
                                "Warning: Failed to extract embedded subtitle document for track id=\(id)"
                            )
                        }
                    }
                }
            }
        }
    }

    public func loadExternalSubtitle(url: URL) {
        var content: String? = nil
        let encodings: [String.Encoding] = [.utf8, .windowsCP1251, .windowsCP1252, .isoLatin1, .utf16]
        for enc in encodings {
            if let str = try? String(contentsOf: url, encoding: enc) {
                content = str
                break
            }
        }

        guard let validContent = content else {
            AppLog.error(.subtitles, "Unable to decode subtitle file with supported encodings: \(url)")
            return
        }

        let isVTT = url.pathExtension.lowercased() == "vtt" || validContent.hasPrefix("WEBVTT")
        let document = isVTT ? SubtitleDocument.parseWebVTT(validContent) : SubtitleDocument.parseSRT(validContent)

        let trackId = 1000 + subtitleTracks.count
        let trackName = url.deletingPathExtension().lastPathComponent
        let track = SubtitleTrack(
            id: trackId,
            streamIndex: -1,
            title: "\(trackName) (External)",
            language: "und",
            isExternal: true
        )
        subtitleTracks.append(track)
        loadedSubtitleDocuments[trackId] = document
        selectSubtitleTrack(id: trackId)
    }

    public func play() {
        guard isLoaded else { return }

        // If video reached the end or is in completed state, restart from the beginning
        if playbackState == .completed || (duration > 0 && currentTime >= (duration - 0.25)) {
            seek(to: 0.0)
        }

        let feedingActive = isFeeding.withLock { $0 }
        if !feedingActive {
            startFeeding()
        }
        synchronizer.setRate(1.0, time: synchronizer.currentTime())
        displayLink?.isPaused = !hasVideo
        isPlaying = true
        playbackState = .playing
        performanceMonitor.handlePlaybackStateChange(isPlaying: true)
    }

    public func pause() {
        stopPlaybackPipeline()
        playbackState = .paused
        saveCurrentPlaybackProgress()
    }

    /// Stops audio/video feeding and halts the clock without altering playbackState or saving progress.
    private func stopPlaybackPipeline() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        displayLink?.isPaused = true
        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        seekTask?.cancel()
        seekTask = nil
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
        AppLog.info(.engine, "Seeking to seconds: \(seconds)")
        guard let demuxer = self.demuxer else { return }
        let wasPlaying = isPlaying
        pause()

        seekTask?.cancel()
        seekTask = nil

        isFeeding.withLock { $0 = false }
        stopFeedingVideo()
        stopFeedingAudio()
        _ = sampleBufferRenderer.perform(Self.flushSelector)
        audioReceiver.flush()
        audioDecoder?.flush()
        frameQueue.clear(resetDroppedFrames: true)

        currentTime = seconds
        updateActiveSubtitles(at: seconds)
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 1000)

        currentSeekId += 1
        let seekId = currentSeekId

        let decoder = self.decoder
        let hasVideo = self.hasVideo

        seekQueue.async { [weak self, demuxer, decoder] in
            guard let self else { return }

            // Early check: if a newer seek was scheduled, drop this one before touching decoder or demuxer
            let isCurrentSeek = { @MainActor in
                self.currentSeekId == seekId
            }

            if DispatchQueue.main.sync(execute: isCurrentSeek) == false {
                return
            }

            if hasVideo {
                decoder.flush()
            }
            demuxer.seek(to: seconds)

            if DispatchQueue.main.sync(execute: isCurrentSeek) == false {
                return
            }

            if wasPlaying {
                DispatchQueue.main.async {
                    guard self.currentSeekId == seekId else { return }
                    self.startFeeding()
                    self.synchronizer.setRate(1.0, time: targetTime)
                    self.displayLink?.isPaused = !hasVideo
                    self.isPlaying = true
                    self.playbackState = .playing
                }
            } else {
                if hasVideo {
                    Self.seekPreview(
                        demuxer: demuxer,
                        decoder: decoder,
                        seconds: seconds,
                        isCurrent: { [weak self] in
                            guard let self else { return false }
                            return DispatchQueue.main.sync { self.currentSeekId == seekId }
                        }
                    )
                }
                DispatchQueue.main.async {
                    guard self.currentSeekId == seekId else { return }
                    self.currentTime = seconds
                    self.synchronizer.setRate(0.0, time: targetTime)
                    if hasVideo {
                        self.renderCurrentFrame()
                    }
                }
            }
        }
        AppLog.debug(.engine, "Seek initiated asynchronously to: \(targetTime.seconds)")
    }

    private nonisolated static func seekPreview(
        demuxer: MediaDemuxer,
        decoder: VTVideoDecoder,
        seconds: Double,
        isCurrent: () -> Bool
    ) {
        var attempts = 0
        var foundTarget = false
        while attempts < 120 && !foundTarget && isCurrent() {
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
        let stepDuration = hasVideo ? (1.0 / 23.976) : 1.0
        seek(to: min(currentTime + stepDuration, duration))
    }

    public func stepFrameBackward() {
        if isPlaying { pause() }
        let stepDuration = hasVideo ? (1.0 / 23.976) : 1.0
        seek(to: max(currentTime - stepDuration, 0))
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
