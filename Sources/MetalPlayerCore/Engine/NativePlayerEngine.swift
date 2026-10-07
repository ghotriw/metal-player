import AVFoundation
import CoreMedia
import Foundation
import Observation
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
    private let activeRenderModeLock = OSAllocatedUnfairLock(initialState: RenderMode.system)
    nonisolated public var activeRenderMode: RenderMode {
        activeRenderModeLock.withLock { $0 }
    }
    public var isMetalLayerVisible: Bool = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalRenderer?.metalLayer.isHidden = !isMetalLayerVisible
            displayLayer.isHidden = isMetalLayerVisible
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

    private let frameQueue = FrameQueue()
    private var displayLink: CVDisplayLink?

    public init() {
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

    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let link = dl else { return }
        self.displayLink = link

        let callback: CVDisplayLinkOutputCallback = {
            (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            guard let context = displayLinkContext else { return kCVReturnSuccess }
            let engine = Unmanaged<NativePlayerEngine>.fromOpaque(context).takeUnretainedValue()
            engine.displayLinkTick()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func updateEffectiveRenderMode() {
        let newMode: RenderMode
        switch renderMode {
        case .auto:
            newMode = isHDRDisplay ? .system : .metalToneMap
        case .system:
            newMode = .system
        case .metalToneMap:
            newMode = .metalToneMap
        }
        activeRenderModeLock.withLock { $0 = newMode }

        if newMode == .system {
            // Instant handover to Apple HDR: hide Metal layer immediately
            isMetalLayerVisible = false
            // Clear frameQueue and flush decoder so obsolete frames are not left behind
            frameQueue.clear()
            let decoder = self.decoder
            feedQueue.async {
                decoder.flush()
            }
        } else {
            // Switching to Metal: clean up any stale frames before receiving new ones
            frameQueue.clear()
            // If paused, immediately render current frozen frame
            if !isPlaying {
                renderCurrentFrame()
                isMetalLayerVisible = true
            }
            // If playing, keep displayLayer visible until first fresh frame pops in displayLinkTick
        }
    }

    nonisolated private func displayLinkTick() {
        guard activeRenderMode == .metalToneMap else { return }
        let currentSyncTime = synchronizer.currentTime()
        guard currentSyncTime.isValid else { return }

        if let buffer = frameQueue.popFrame(forSyncTime: currentSyncTime) {
            metalRenderer?.render(pixelBuffer: buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isMetalLayerVisible {
                    self.isMetalLayerVisible = true
                }
            }
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
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioDecoder?.flush()

        let decoder = self.decoder
        feedQueue.async { [weak self] in
            decoder.flush()
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameQueue.clear()
                self.startFeeding()
                self.synchronizer.setRate(1.0, time: .zero)
                if let displayLink = self.displayLink {
                    CVDisplayLinkStart(displayLink)
                }
                self.isPlaying = true
            }
        }
    }

    private func startFeeding() {
        guard let demuxer = self.demuxer else { return }
        isFeeding.withLock { $0 = true }

        let feedingLock = self.isFeeding
        let modeLock = self.activeRenderModeLock
        nonisolated(unsafe) let layer = self.displayLayer
        nonisolated(unsafe) let aRenderer = self.audioRenderer

        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        let decoder = self.decoder
        let queue = self.frameQueue

        // Video feed loop
        displayLayer.requestMediaDataWhenReady(on: feedQueue) { [demuxer] in
            while layer.isReadyForMoreMediaData && feedingLock.withLock({ $0 }) {
                // Backpressure: If Metal tone mapping is active and frameQueue already has >45 decoded frames (~1.8 seconds),
                // yield feedQueue briefly to let CVDisplayLink drain the queue and prevent buffer exhaustion.
                if modeLock.withLock({ $0 == .metalToneMap }) && queue.count >= 45 {
                    Thread.sleep(forTimeInterval: 0.010)
                    if !feedingLock.withLock({ $0 }) { break }
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
                            "[NativePlayerEngine] Enqueued sample #\(count), pts: \(CMTimeGetSeconds(pts))s, layer.status: \(layer.status.rawValue)"
                        )
                    }

                    // Feed hardware decoder only if Metal tone mapping is active
                    if modeLock.withLock({ $0 == .metalToneMap }) {
                        decoder.decode(sampleBuffer: sampleBuf)
                    }

                    // Feed displayLayer for timing/AVSampleBufferRenderSynchronizer
                    layer.enqueue(sampleBuf)
                } else {
                    print("[NativePlayerEngine] Demuxer returned nil.")
                    break
                }
            }
        }

        // Audio feed loop with backpressure to keep CoreAudio buffer tight (~0.4s lead time)
        // This prevents CoreAudio Spatializer DSP stalls when toggling Spatial Audio in Control Center.
        if let aDecoder = self.audioDecoder {
            let audioTimebase = demuxer.audioTimebase
            let sync = self.synchronizer
            audioRenderer.requestMediaDataWhenReady(on: audioFeedQueue) { [demuxer, aDecoder] in
                while aRenderer.isReadyForMoreMediaData && feedingLock.withLock({ $0 }) {
                    // Check audio buffer lead time relative to current playback time
                    let currentPlaybackSeconds = CMTimeGetSeconds(sync.currentTime())
                    if currentPlaybackSeconds >= 0 {
                        let audioTimeSeconds = demuxer.currentAudioPtsSeconds
                        if audioTimeSeconds > 0 && (audioTimeSeconds - currentPlaybackSeconds) > 0.300 {
                            // Yield from the block without blocking the thread.
                            // The system will invoke the block again when ready.
                            break
                        }
                    }

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

        // Stop requesting data and wait for audioFeedQueue to finish executing any in-flight block
        audioRenderer.stopRequestingMediaData()
        audioFeedQueue.sync {}

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
        if let displayLink {
            CVDisplayLinkStart(displayLink)
        }
        isPlaying = true
    }

    public func pause() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        isFeeding.withLock { $0 = false }
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        isPlaying = false
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
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        audioDecoder?.flush()
        frameQueue.clear()

        currentTime = seconds
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 1000)

        let decoder = self.decoder
        nonisolated(unsafe) let layer = self.displayLayer
        feedQueue.async { [weak self, demuxer] in
            decoder.flush()
            demuxer.seek(to: seconds)

            guard let self else { return }

            if wasPlaying {
                DispatchQueue.main.async {
                    self.startFeeding()
                    self.synchronizer.setRate(1.0, time: targetTime)
                    if let displayLink = self.displayLink {
                        CVDisplayLinkStart(displayLink)
                    }
                    self.isPlaying = true
                }
            } else {
                var attempts = 0
                var foundTarget = false
                while attempts < 120 && !foundTarget {
                    if let sample = demuxer.nextVideoSample() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        decoder.decode(sampleBuffer: sample)
                        layer.enqueue(sample)
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
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        isFeeding.withLock { $0 = false }
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
    }
}
