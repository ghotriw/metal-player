import Foundation
import IOKit.pwr_mgt
import os

/// Prevents the display from dimming/sleeping and screen saver from activating
/// while video playback is actively in progress.
public final class DisplaySleepManager: Sendable {
    private let assertionID = OSAllocatedUnfairLock<IOPMAssertionID>(initialState: 0)
    private let reason: String

    public init(reason: String = "Nits Video Playback") {
        self.reason = reason
    }

    deinit {
        assertionID.withLock { id in
            if id != 0 {
                IOPMAssertionRelease(id)
                id = 0
            }
        }
    }

    /// Whether display sleep and screen saver are currently disabled.
    public var isSleepDisabled: Bool {
        assertionID.withLock { $0 != 0 }
    }

    /// Disables display sleep and screen saver if not already disabled.
    public func disableDisplaySleep() {
        assertionID.withLock { id in
            guard id == 0 else { return }
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            if result == kIOReturnSuccess {
                id = newID
                AppLog.debug(.engine, "Display sleep disabled (assertionID: \(newID))")
            } else {
                AppLog.error(.engine, "Failed to create display sleep assertion: \(result)")
            }
        }
    }

    /// Enables display sleep and screen saver if currently disabled.
    public func enableDisplaySleep() {
        assertionID.withLock { id in
            guard id != 0 else { return }
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess {
                AppLog.error(.engine, "Failed to release display sleep assertion: \(result)")
            } else {
                AppLog.debug(.engine, "Display sleep re-enabled")
            }
            id = 0
        }
    }

    /// Updates display sleep state based on active video playback.
    /// Display sleep is only prevented when actively playing video.
    /// For audio-only playback, display sleep is permitted to preserve power.
    public func update(isPlaying: Bool, hasVideo: Bool) {
        if isPlaying && hasVideo {
            disableDisplaySleep()
        } else {
            enableDisplaySleep()
        }
    }
}
