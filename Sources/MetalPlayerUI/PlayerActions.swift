import Foundation
import MetalPlayerCore
import SwiftUI

@MainActor
public protocol PlayerActions: AnyObject {
    var renderMode: RenderMode { get set }
    var metalSharpness: Float { get set }
    var isMuted: Bool { get }
    var showDebugHUD: Bool { get }

    func togglePlayPause()
    func stepFrameForward()
    func stepFrameBackward()
    func seekRelative(by seconds: Double)
    func stepVolume(by delta: Float)
    func toggleMute()
    func toggleDebugHUD()
    func toggleFullscreen()
    func exitFullscreen()
}

public struct PlayerActionsKey: FocusedValueKey {
    public typealias Value = any PlayerActions
}

extension FocusedValues {
    public var playerActions: (any PlayerActions)? {
        get { self[PlayerActionsKey.self] }
        set { self[PlayerActionsKey.self] = newValue }
    }
}
