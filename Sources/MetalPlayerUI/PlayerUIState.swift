import Foundation
import Observation

@Observable
@MainActor
public final class PlayerUIState {
    public var isFullscreen: Bool

    public init(isFullscreen: Bool = false) {
        self.isFullscreen = isFullscreen
    }
}
