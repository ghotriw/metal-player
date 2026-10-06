import Foundation
import AVFoundation
import CoreMedia
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

    public let displayLayer = AVSampleBufferDisplayLayer()
    public let metalRenderer = MetalVideoRenderer()
    private let decoder = VTVideoDecoder()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var demuxer: HEVCDemuxer?
    private let feedQueue = DispatchQueue(label: "com.nativeplayer.feed", qos: .userInteractive)
    private var timeObserver: Any?
    @ObservationIgnored
    private let isFeeding = OSAllocatedUnfairLock(initialState: false)

    private let frameQueue = FrameQueue()
    private var displayLink: CVDisplayLink?

    public init() {
        synchronizer.addRenderer(displayLayer)
        displayLayer.videoGravity = .resizeAspect

        let queue = self.frameQueue
        decoder.setOutputHandler { frame in
            queue.push(frame)
        }

        setupDisplayLink()

        timeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            if !seconds.isNaN && !seconds.isInfinite && seconds >= 0 {
                MainActor.assumeIsolated {
                    self.currentTime = seconds
                }
            }
        }
    }

    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let link = dl else { return }
        self.displayLink = link

        let callback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
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
        guard let newDemuxer = HEVCDemuxer(url: path) else {
            print("[NativePlayerEngine] Failed to open file with HEVCDemuxer:", path)
            return
        }

        self.demuxer = newDemuxer
        self.duration = newDemuxer.durationSeconds
        self.videoWidth = newDemuxer.width
        self.videoHeight = newDemuxer.height
        self.mediaTitle = URL(fileURLWithPath: path).lastPathComponent
        self.isLoaded = true
        self.metalRenderer?.uniforms.sourcePeakNits = newDemuxer.maxPeakNits
        print("[NativePlayerEngine] Loaded successfully. Duration: \(duration)s, peakNits: \(newDemuxer.maxPeakNits), formatDesc: \(String(describing: newDemuxer.formatDescription))")

        isFeeding.withLock { $0 = false }
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
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

        let sampleCountLock = OSAllocatedUnfairLock(initialState: 0)
        let decoder = self.decoder
        let queue = self.frameQueue

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
                        print("[NativePlayerEngine] Enqueued sample #\(count), pts: \(CMTimeGetSeconds(pts))s, layer.status: \(layer.status.rawValue)")
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
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            CVDisplayLinkSetOutputCallback(displayLink, nil, nil)
        }
        isFeeding.withLock { $0 = false }
        displayLayer.stopRequestingMediaData()
    }
}
