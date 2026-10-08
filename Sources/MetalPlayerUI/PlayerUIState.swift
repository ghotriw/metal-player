import Foundation
import Observation

@Observable
@MainActor
public final class PlayerUIState {
    public var isFullscreen: Bool
    public var controlsVisibilityTrigger: Int = 0

    public init(isFullscreen: Bool = false) {
        self.isFullscreen = isFullscreen
    }

    public func showControlsTemporarily() {
        controlsVisibilityTrigger &+= 1
    }
}
