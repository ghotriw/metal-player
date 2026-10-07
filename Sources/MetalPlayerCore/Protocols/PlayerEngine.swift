import AppKit
import CoreMedia
import Foundation

public enum RenderMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "Auto (Display Adaptive)"
    case system = "System (Apple DisplayLayer)"
    case metalToneMap = "Custom Metal Tone-Mapping"

    public var id: String { rawValue }
}

public protocol PlayerEngine: AnyObject, Sendable {
    @MainActor var currentTime: Double { get }
    @MainActor var duration: Double { get }
    @MainActor var isPlaying: Bool { get }
    @MainActor var isLoaded: Bool { get }
    @MainActor var mediaTitle: String { get }
    @MainActor var videoWidth: Int { get }
    @MainActor var videoHeight: Int { get }

    @MainActor var renderMode: RenderMode { get set }
    @MainActor var isHDRDisplay: Bool { get set }
    @MainActor var isToneMappingPermitted: Bool { get set }
    nonisolated var activeRenderMode: RenderMode { get }

    @MainActor var metalExposure: Float { get set }
    @MainActor var metalShadowLift: Float { get set }
    @MainActor var metalTargetNits: Float { get set }
    @MainActor var metalSharpness: Float { get set }

    @MainActor var volume: Float { get set }
    @MainActor var isMuted: Bool { get set }
    @MainActor var audioTracks: [MediaDemuxer.AudioTrack] { get }
    @MainActor var selectedAudioTrackId: Int { get }

    @MainActor func load(path: String)
    @MainActor func play()
    @MainActor func pause()
    @MainActor func seek(to seconds: Double)
    @MainActor func stepFrameForward()
    @MainActor func stepFrameBackward()
    @MainActor func renderCurrentFrame()
    @MainActor func selectAudioTrack(id: Int)
}
