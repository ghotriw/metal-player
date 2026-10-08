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

    nonisolated(unsafe) public let displayLayer = AVSampleBufferDisplayLayer()
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

    public init(configuration: PlayerConfiguration) {
        self.renderMode = configuration.defaultRenderMode
        self.isToneMappingPermitted = configuration.enableToneMapping
        self.metalTargetNits = configuration.targetNits
        self.metalSharpness = configuration.sharpness
        self.volume = configuration.initialVolume

        metalRenderer?.uniforms.targetNits = configuration.targetNits
        metalRenderer?.uniforms.outputSharpness = configuration.sharpness
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

        nonisolated(unsafe) let layer = self.displayLayer
        nonisolated(unsafe) let s = sample
        layer.enqueue(s)
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
        stopFeedingVideo()
        stopFeedingAudio()
        displayLayer.flush()
        audioReceiver.flush()
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
            var pcmBuffers = audioDecoder.decode(
                packetData: packet.data,
                pts: packet.pts,
                timebase: audioTimebase
            )
            while !pcmBuffers.isEmpty {
                if Task.isCancelled || !feedingLock.withLock({ $0 }) { break }
                let buf = pcmBuffers.removeFirst()
                let ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent> = CMReadySampleBuffer(unsafeBuffer: buf)
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
        displayLayer.flush()
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

    isolated deinit {
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
