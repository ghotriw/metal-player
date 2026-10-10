import Foundation
import Observation

@Observable
@MainActor
public final class PlayerUIState {
    public var isFullscreen: Bool
    public var controlsVisibilityTrigger: Int = 0
    public let osd: OSDManager

    public init(isFullscreen: Bool = false, osd: OSDManager = OSDManager()) {
        self.isFullscreen = isFullscreen
        self.osd = osd
    }

    public func showControlsTemporarily() {
        controlsVisibilityTrigger &+= 1
    }
}
