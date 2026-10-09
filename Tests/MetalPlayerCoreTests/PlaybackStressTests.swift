import AVFoundation
import CoreMedia
import Foundation
import Testing
import os

@testable import MetalPlayerCore

@Suite("Playback Stress & Reliability Tests", .serialized)
struct PlaybackStressTests {

    private static func findTestMedia() -> String? {
        return SyntheticTestMediaFactory.ensureMedia(preset: .multiTrackH264)
    }

    // MARK: - 1. Rapid Scrubbing Chaos Test
    @Test("Rapid scrub chaos test does not hang or deadlock the engine")
    @MainActor
    func testRapidScrubbingBurst() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = PlayerEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0.0)

        let duration = engine.duration
        let maxSeek = min(duration - 2.0, 120.0)
        guard maxSeek > 5.0 else {
            engine.stop()
            return
        }

        // Fire 15 rapid random seek calls with burst intervals between 10ms and 50ms
        var target: Double = 0.0
        for _ in 0..<15 {
            target = Double.random(in: 1.0...maxSeek)
            engine.seek(to: target)
            try? await Task.sleep(nanoseconds: UInt64.random(in: 10_000_000...50_000_000))
        }

        // Final settling seek
        let finalTarget = 15.0
        engine.seek(to: finalTarget)

        // Wait for asynchronous seek pipeline to settle
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2.0s

        print("[Test] Settled currentTime:", engine.currentTime, "expected:", finalTarget)
        #expect(engine.isLoaded == true)
        #expect(abs(engine.currentTime - finalTarget) <= 3.0)

        // Ensure engine is responsive and can resume playing cleanly after scrub burst
        engine.play()
        #expect(engine.isPlaying == true)
        #expect(engine.playbackState == .playing)

        try? await Task.sleep(nanoseconds: 200_000_000)
        engine.pause()
        #expect(engine.isPlaying == false)

        engine.stop()
    }

    // MARK: - 2. Continuous Decoding & Frame Variation Test (Freeze Detector)
    @Test("Continuous video decoding delivers unique changing frames without video freeze")
    func testContinuousVideoDecodingFrameVariation() {
        guard let path = Self.findTestMedia() else { return }
        guard let demuxer = MediaDemuxer(url: path), demuxer.hasVideo else { return }

        let decoder = VTVideoDecoder()
        let hashesLock = OSAllocatedUnfairLock(initialState: [UInt64]())

        decoder.setOutputHandler { frame in
            guard !frame.doNotDisplay else { return }
            let h = PixelBufferAnalyzer.computeSamplingHash(of: frame.pixelBuffer, sampleStep: 32)
            hashesLock.withLock { list in
                list.append(h)
            }
        }

        // Decode 35 non-preroll frames from demuxer
        var decodedSamples = 0
        while decodedSamples < 40 {
            guard let sample = demuxer.nextVideoSample() else { break }
            decoder.decode(sampleBuffer: sample)
            decodedSamples += 1
        }
        decoder.flush()

        let hashes = hashesLock.withLock { $0 }
        #expect(hashes.count >= 10, "Decoder must successfully decode at least 10 valid video frames")

        // In active video, distinct frames must exhibit variety (not 100% duplicates)
        let uniqueHashes = Set(hashes)
        #expect(
            uniqueHashes.count > 1, "Decoded stream must produce distinct visual frames rather than a frozen duplicate")
    }

    // MARK: - 3. Rapid Concurrent Play/Pause/Seek Race Conditions
    @Test("Rapid concurrent playback controls maintain state invariants")
    @MainActor
    func testConcurrentPlaybackControlsRace() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = PlayerEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        for i in 0..<10 {
            if i % 2 == 0 {
                engine.play()
            } else {
                engine.pause()
            }
            engine.seek(to: Double(i * 3))
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        engine.pause()
        #expect(engine.isPlaying == false)
        #expect(engine.playbackState == .paused)

        engine.stop()
        #expect(engine.isLoaded == false)
        #expect(engine.playbackState == .idle)
    }

    // MARK: - 4. Rapid Audio Track Switching Under Load
    @Test("Audio track switching under active playback does not hang engine")
    @MainActor
    func testAudioTrackSwitchingUnderPlayback() async {
        guard let path = Self.findTestMedia() else { return }

        let engine = PlayerEngine()
        engine.load(path: path)
        #expect(engine.isLoaded == true)

        let tracks = engine.audioTracks
        guard tracks.count > 1 else {
            engine.stop()
            return
        }

        engine.play()
        #expect(engine.isPlaying == true)

        // Switch tracks rapidly back and forth
        for _ in 0..<4 {
            for track in tracks {
                engine.selectAudioTrack(id: track.id)
                #expect(engine.selectedAudioTrackId == track.id)
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
        }

        #expect(engine.isPlaying == true)
        engine.pause()
        #expect(engine.isPlaying == false)
        engine.stop()
    }
}
