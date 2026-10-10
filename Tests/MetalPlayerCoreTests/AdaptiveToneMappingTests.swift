import Foundation
import Testing

@testable import MetalPlayerCore

@Suite("Adaptive Target White Tone Mapping Tests")
struct AdaptiveToneMappingTests {
    @Test("High-peak HDR10 content maintains standard 203 nits ITU reference")
    func testHighPeakHDR10TargetNits() {
        // High peak (1000 nits) and normal/high FALL (161 nits, like His Dark Materials)
        let target1 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 161.0
        )
        #expect(target1 == 203.0)

        // High peak (1000 nits) without explicit FALL metadata (like Ms. Marvel)
        let target2 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 1000.0,
            maxFallNits: 0.0
        )
        #expect(target2 == 203.0)

        // 997 nits (w_hdm_full)
        let target3 = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 997.0,
            maxFallNits: 161.0
        )
        #expect(target3 == 203.0)
    }

    @Test("Low-peak and low-FALL content dynamically scales target white to prevent darkness")
    func testLowPeakAndLowFallTargetNits() {
        // The Agency (451 nits peak, 68 nits FALL)
        let agencyTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 451.0,
            maxFallNits: 68.0
        )
        // Expected range: ~110...125 nits
        #expect(agencyTarget >= 110.0 && agencyTarget <= 125.0)

        // House of the Dragon (699 nits peak, 94 nits FALL)
        let hotdTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 699.0,
            maxFallNits: 94.0
        )
        // Expected range: ~150...165 nits
        #expect(hotdTarget >= 150.0 && hotdTarget <= 165.0)
    }

    @Test("Adaptive target white clamps cleanly between 100 and base target nits")
    func testBoundaryClamping() {
        // Ultra-low peak (e.g. 250 nits)
        let minTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 250.0,
            maxFallNits: 40.0
        )
        #expect(minTarget >= 100.0)

        // Ultra-high peak (e.g. 4000 nits mastering)
        let maxTarget = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 203.0,
            maxPeakNits: 4000.0,
            maxFallNits: 250.0
        )
        #expect(maxTarget == 203.0)
    }

    @Test("Explicit custom baseTargetNits is respected as maximum bound")
    func testCustomBaseTargetNits() {
        // User explicitly set 150 nits as base target
        let target = PlayerEngine.computeAdaptiveTargetNits(
            baseTargetNits: 150.0,
            maxPeakNits: 451.0,
            maxFallNits: 68.0
        )
        #expect(target >= 100.0 && target <= 150.0)
    }

    @Test("targetNitsScale scales content-adaptive target white dynamically while preserving adaptation")
    @MainActor
    func testTargetNitsScaleMultiplier() {
        let engine = PlayerEngine()

        // 1.0x default
        #expect(engine.targetNitsScale == 1.0)
        #expect(engine.baseAdaptiveTargetNits == 203.0)
        #expect(engine.metalTargetNits == 203.0)

        // Adjust scale knob to 0.8x (20% brighter midtones/shadows for all content)
        engine.targetNitsScale = 0.8
        #expect(abs(engine.metalTargetNits - (203.0 * 0.8)) < 0.01)

        // Adjust scale knob to 1.5x (higher contrast)
        engine.targetNitsScale = 1.5
        #expect(abs(engine.metalTargetNits - (203.0 * 1.5)) < 0.01)
    }
}
