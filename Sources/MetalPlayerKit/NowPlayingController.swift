import AppKit
import Foundation
import MediaPlayer
import MetalPlayerCore
import Observation

#if canImport(NowPlaying)
    import NowPlaying
#endif

/// Common interface for coordinating media playback status with the system
/// (macOS Control Center / Menu Bar Now Playing and AirPods / Media Key controls).
@MainActor
public protocol NowPlayingController: AnyObject {
    var actions: (any PlayerActions)? { get set }
    var isKeyWindow: Bool { get set }
    func update(title: String, currentTime: Double, duration: Double, isPlaying: Bool)
    func clear()
}

/// Factory that selects the appropriate Now Playing implementation:
/// - macOS 27.0+: Modern Swift `NowPlaying` framework (`MediaSession`).
/// - Earlier macOS: Classic `MediaPlayer` framework (`MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`).
@MainActor
public enum NowPlayingControllerFactory {
    public static func makeController(
        engine: any PlayerEngineProtocol,
        actions: (any PlayerActions)? = nil
    ) -> any NowPlayingController {
        #if canImport(NowPlaying)
            if #available(macOS 27.0, *) {
                return ModernNowPlayingController(engine: engine, actions: actions)
            }
        #endif
        return LegacyMediaPlayerController(engine: engine, actions: actions)
    }
}

// MARK: - Throttler & Update Detection

/// Encapsulates throttling and update-detection logic for system Now Playing updates.
/// Filters out frequent 0.1s tick updates during normal 1x playback (allowing system timeline
/// extrapolation to run smoothly) while immediately forwarding play/pause state changes,
/// seek jumps (>1.5s difference from expected position), and periodic heartbeat refreshes (>=5s).
public struct NowPlayingThrottler: Sendable {
    public private(set) var lastReportedTime: Double = -1
    public private(set) var lastReportedTitle: String = ""
    public private(set) var lastReportedIsPlaying: Bool? = nil
    public private(set) var lastReportedDate: Date = .distantPast

    public init() {}

    /// Determines if an update should be dispatched to the system.
    /// If returning `true`, the internal state is updated to the provided values.
    public mutating func shouldUpdate(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !title.isEmpty else { return false }

        let isStateChange = (isPlaying != lastReportedIsPlaying) || (title != lastReportedTitle)
        let elapsed = now.timeIntervalSince(lastReportedDate)
        let expectedTime =
            lastReportedTime >= 0
            ? lastReportedTime + (lastReportedIsPlaying == true ? elapsed : 0)
            : currentTime
        let isSeeking = abs(currentTime - expectedTime) > 1.5
        let isHeartbeat = elapsed >= 5.0

        guard isStateChange || isSeeking || isHeartbeat else {
            return false
        }

        forceRecord(title: title, currentTime: currentTime, isPlaying: isPlaying, now: now)
        return true
    }

    /// Explicitly updates recorded state (e.g. following an immediate user seek command).
    public mutating func forceRecord(
        title: String,
        currentTime: Double,
        isPlaying: Bool,
        now: Date = Date()
    ) {
        lastReportedTitle = title
        lastReportedTime = currentTime
        lastReportedIsPlaying = isPlaying
        lastReportedDate = now
    }

    /// Resets all tracked state.
    public mutating func reset() {
        lastReportedTitle = ""
        lastReportedTime = -1
        lastReportedIsPlaying = nil
        lastReportedDate = .distantPast
    }
}

// MARK: - Modern Implementation (macOS 27.0+)

#if canImport(NowPlaying)
    /// Data model conforming to `MediaSessionRepresentable`.
    /// Separated from `ModernNowPlayingController` to avoid strong retain cycles with `MediaSession`.
    @available(macOS 27.0, *)
    @Observable
    @MainActor
    public final class ModernNowPlayingModel: MediaSessionRepresentable {
        public let id: String
        public var title: String = ""
        public var currentTime: Double = 0
        public var duration: Double = 0
        public var isPlaying: Bool = false

        public var onTogglePlayPause: (() -> Void)?
        public var onPlay: (() -> Void)?
        public var onPause: (() -> Void)?
        public var onSeekToPosition: ((Double) -> Void)?
        public var onSkip: ((Double) -> Void)?

        public init(id: String = UUID().uuidString) {
            self.id = id
        }

        public var content: (any MediaContentRepresentable)? {
            guard !title.isEmpty else { return nil }
            return MovieContent(
                id: title,
                title: title,
                duration: duration > 0 ? .finite(duration) : nil,
                artwork: nil
            )
        }

        public var playbackSnapshot: MediaPlaybackSnapshot? {
            guard !title.isEmpty else { return nil }
            return MediaPlaybackSnapshot(
                state: isPlaying ? .playing(rate: 1.0) : .paused,
                elapsedTime: max(0, currentTime),
                timestamp: .now
            )
        }

        public var commands: [MediaCommand] {
            [
                .togglePlayPause { [weak self] in
                    self?.onTogglePlayPause?()
                },
                .play { [weak self] in
                    self?.onPlay?()
                },
                .pause { [weak self] in
                    self?.onPause?()
                },
                .seekToPosition { [weak self] seconds in
                    self?.onSeekToPosition?(seconds)
                },
                .skipForward(preferredIntervals: [10]) { [weak self] interval in
                    let delta = interval > 0 ? interval : 10
                    self?.onSkip?(delta)
                },
                .skipBackward(preferredIntervals: [10]) { [weak self] interval in
                    let delta = interval > 0 ? interval : 10
                    self?.onSkip?(-delta)
                },
            ]
        }
    }

    @available(macOS 27.0, *)
    @MainActor
    public final class ModernNowPlayingController: NowPlayingController {
        public let model: ModernNowPlayingModel
        public weak var actions: (any PlayerActions)?
        public var isKeyWindow: Bool = true

        private weak var engine: (any PlayerEngineProtocol)?
        private var session: MediaSession<ModernNowPlayingModel>?
        private var activationTask: Task<Void, Never>?
        private var throttler = NowPlayingThrottler()

        public init(
            engine: any PlayerEngineProtocol,
            actions: (any PlayerActions)? = nil,
            id: String = UUID().uuidString
        ) {
            self.engine = engine
            self.actions = actions
            let model = ModernNowPlayingModel(id: id)
            self.model = model

            model.onTogglePlayPause = { [weak self] in
                guard let self else { return }
                if let actions = self.actions {
                    actions.togglePlayPause()
                } else {
                    self.engine?.togglePlayPause()
                }
            }

            model.onPlay = { [weak self] in
                guard let self else { return }
                self.engine?.play()
            }

            model.onPause = { [weak self] in
                guard let self else { return }
                self.engine?.pause()
            }

            model.onSeekToPosition = { [weak self] seconds in
                guard let self else { return }
                self.engine?.seek(to: seconds)
                // Immediately sync model currentTime so the scrubber doesn't snap back when paused
                self.model.currentTime = seconds
                self.throttler.forceRecord(
                    title: self.throttler.lastReportedTitle,
                    currentTime: seconds,
                    isPlaying: self.model.isPlaying
                )
            }

            model.onSkip = { [weak self] delta in
                guard let self else { return }
                if let actions = self.actions {
                    actions.seekRelative(by: delta)
                } else {
                    self.engine?.seekRelative(by: delta)
                }
                if let engine = self.engine {
                    self.model.currentTime = engine.currentTime
                    self.throttler.forceRecord(
                        title: self.throttler.lastReportedTitle,
                        currentTime: engine.currentTime,
                        isPlaying: self.model.isPlaying
                    )
                }
            }
        }

        public func update(title: String, currentTime: Double, duration: Double, isPlaying: Bool) {
            guard !title.isEmpty else {
                clear()
                return
            }

            guard
                throttler.shouldUpdate(
                    title: title,
                    currentTime: currentTime,
                    duration: duration,
                    isPlaying: isPlaying
                )
            else {
                return
            }

            model.title = title
            model.currentTime = currentTime
            model.duration = duration
            model.isPlaying = isPlaying

            ensureActiveSession()
        }

        private func ensureActiveSession() {
            if session == nil {
                let newSession = MediaSession(model)
                self.session = newSession
                activationTask?.cancel()
                activationTask = Task { [weak self] in
                    try? await self?.session?.requestToBecomeApplicationPrimary()
                    self?.activationTask = nil
                }
            } else if let session, !session.isApplicationPrimary {
                guard activationTask == nil else { return }
                activationTask = Task { [weak self] in
                    try? await self?.session?.requestToBecomeApplicationPrimary()
                    self?.activationTask = nil
                }
            }
        }

        public func clear() {
            activationTask?.cancel()
            activationTask = nil

            model.title = ""
            model.isPlaying = false
            throttler.reset()

            // Removing reference deactivates the session from system Control Center
            session = nil
        }
    }
#endif

// MARK: - Legacy Fallback Implementation (macOS < 27.0 using MediaPlayer)

@MainActor
public final class LegacyMediaPlayerController: NowPlayingController {
    public weak var actions: (any PlayerActions)?
    public var isKeyWindow: Bool = true

    public private(set) var isActive: Bool = false {
        didSet {
            updateCommandsEnabledState()
        }
    }

    private weak var engine: (any PlayerEngineProtocol)?
    private var targets: [(command: MPRemoteCommand, target: Any)] = []
    private var throttler = NowPlayingThrottler()

    public init(
        engine: any PlayerEngineProtocol,
        actions: (any PlayerActions)? = nil
    ) {
        self.engine = engine
        self.actions = actions
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // 1. AirPods stem press & hardware media keys
        center.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            if let actions = self.actions {
                actions.togglePlayPause()
            } else if let engine = self.engine {
                engine.togglePlayPause()
            } else {
                return .noActionableNowPlayingItem
            }
            return .success
        }
        targets.append((center.togglePlayPauseCommand, toggleTarget))

        // 2. Play command
        center.playCommand.isEnabled = true
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isActive, let engine = self.engine else { return .noActionableNowPlayingItem }
            engine.play()
            return .success
        }
        targets.append((center.playCommand, playTarget))

        // 3. Pause command
        center.pauseCommand.isEnabled = true
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isActive, let engine = self.engine else { return .noActionableNowPlayingItem }
            engine.pause()
            return .success
        }
        targets.append((center.pauseCommand, pauseTarget))

        // 4. Scrubber in macOS Control Center
        center.changePlaybackPositionCommand.isEnabled = true
        let posTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.isActive,
                let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                let engine = self.engine
            else {
                return .commandFailed
            }
            let targetSeconds = positionEvent.positionTime
            engine.seek(to: targetSeconds)
            // Immediately sync so scrubber position doesn't bounce back on pause
            self.forceUpdateNowPlayingInfo(
                title: self.throttler.lastReportedTitle,
                currentTime: targetSeconds,
                duration: engine.duration,
                isPlaying: engine.isPlaying
            )
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, posTarget))

        // 5. Skip forward
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        let skipFwdTarget = center.skipForwardCommand.addTarget { [weak self] event in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            let step = interval > 0 ? interval : 10
            if let actions = self.actions {
                actions.seekRelative(by: step)
            } else if let engine = self.engine {
                engine.seekRelative(by: step)
            }
            return .success
        }
        targets.append((center.skipForwardCommand, skipFwdTarget))

        // 6. Skip backward
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        let skipBwdTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, self.isActive else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            let step = interval > 0 ? interval : 10
            if let actions = self.actions {
                actions.seekRelative(by: -step)
            } else if let engine = self.engine {
                engine.seekRelative(by: -step)
            }
            return .success
        }
        targets.append((center.skipBackwardCommand, skipBwdTarget))
    }

    private func updateCommandsEnabledState() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = isActive
        center.playCommand.isEnabled = isActive
        center.pauseCommand.isEnabled = isActive
        center.changePlaybackPositionCommand.isEnabled = isActive
        center.skipForwardCommand.isEnabled = isActive
        center.skipBackwardCommand.isEnabled = isActive
    }

    public func update(title: String, currentTime: Double, duration: Double, isPlaying: Bool) {
        guard !title.isEmpty else {
            clear()
            return
        }

        guard
            throttler.shouldUpdate(
                title: title,
                currentTime: currentTime,
                duration: duration,
                isPlaying: isPlaying
            )
        else {
            return
        }

        forceUpdateNowPlayingInfo(
            title: title,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func forceUpdateNowPlayingInfo(
        title: String,
        currentTime: Double,
        duration: Double,
        isPlaying: Bool
    ) {
        isActive = true
        throttler.forceRecord(
            title: title,
            currentTime: currentTime,
            isPlaying: isPlaying
        )

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info

        // macOS requirement: explicit playbackState is required for Control Center to sync correctly
        center.playbackState = isPlaying ? .playing : .paused
    }

    public func clear() {
        isActive = false
        throttler.reset()

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    isolated deinit {
        for item in targets {
            item.command.removeTarget(item.target)
        }
    }
}
