import CFFmpeg
import CoreMedia
import Foundation
import Testing

@testable import MetalPlayerCore

/// Compares the player's decoder output against an independent FFmpeg CLI decode of the same track.
/// Every channel carries a distinct tone, so channel swaps, wrong layouts, resampling errors and
/// distortion show up as low per-channel correlation. Also checks seek joints for clicks.
@Suite("Audio Codec Matrix: Reference Comparison & Seek Joints", .serialized)
struct AudioReferenceComparisonTests {

    /// Decodes `seconds` of a track with the player's decoder. Returns interleaved Float32 and channel count.
    static func decodeOurs(path: String, trackId: Int, seconds: Double) -> (samples: [Float], channels: Int)? {
        guard let demuxer = MediaDemuxer(url: path) else { return nil }
        demuxer.selectAudioTrack(trackId: trackId)
        guard let params = demuxer.getAudioCodecParameters(),
            let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
        else { return nil }

        var out: [Float] = []
        var channels = 0
        let limit = Int(seconds * 48000)
        while channels == 0 || out.count / channels < limit {
            guard let pkt = demuxer.nextAudioPacket() else { break }
            for sb in decoder.decode(packetData: pkt.data, pts: pkt.pts, timebase: demuxer.audioTimebase) {
                let n = CMSampleBufferGetNumSamples(sb)
                guard n > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                channels = length / n / 4
                var chunk = [Float](repeating: 0, count: length / 4)
                chunk.withUnsafeMutableBytes {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                out.append(contentsOf: chunk)
            }
        }
        return channels > 0 ? (out, channels) : nil
    }

    /// Reference decode through the ffmpeg CLI to raw f32le at 48 kHz with the given channel count.
    static func decodeReference(path: String, audioIndex: Int, channels: Int, seconds: Double) -> [Float]? {
        guard let ffmpeg = SyntheticTestMediaFactory.ffmpegBinaryPath() else { return nil }
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ref_\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-v", "error", "-y", "-i", path, "-map", "0:a:\(audioIndex)", "-t", "\(seconds)",
            "-ac", "\(channels)", "-ar", "48000", "-f", "f32le", outURL.path,
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: outURL) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Best normalized cross-correlation of one channel over a lag range (handles codec/resampler delay).
    static func bestCorrelation(
        ours: [Float], ref: [Float], channels: Int, channel: Int, start: Int, window: Int, maxLag: Int
    ) -> Float {
        func ch(_ a: [Float], _ i: Int) -> Float { a[i * channels + channel] }
        let oursFrames = ours.count / channels
        let refFrames = ref.count / channels
        guard start + window + maxLag < min(oursFrames, refFrames), start - maxLag >= 0 else { return 0 }
        var best: Float = -1
        for lag in -maxLag...maxLag {
            var dot: Float = 0
            var eo: Float = 0
            var er: Float = 0
            for i in start..<(start + window) {
                let a = ch(ours, i)
                let b = ch(ref, i + lag)
                dot += a * b
                eo += a * a
                er += b * b
            }
            let denom = (eo * er).squareRoot()
            if denom > 1e-9 { best = max(best, dot / denom) }
        }
        return best
    }

    @Test("Every codec/layout decodes to the same per-channel signal as the FFmpeg reference")
    func testCodecMatrixMatchesReference() {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .audioCodecMatrix),
            let demuxer = MediaDemuxer(url: path)
        else { return }
        #expect(demuxer.audioTracks.count == SyntheticTestMediaFactory.audioMatrixTracks.count)

        for (idx, spec) in SyntheticTestMediaFactory.audioMatrixTracks.enumerated() {
            guard let ours = Self.decodeOurs(path: path, trackId: idx, seconds: 3.0) else {
                Issue.record("\(spec.name): decoder produced no output")
                continue
            }
            // Player output channel count: 8 for >=8, 6 for >=6, else 2.
            let expectedChannels = spec.channels >= 8 ? 8 : (spec.channels >= 6 ? 6 : 2)
            #expect(ours.channels == expectedChannels, "\(spec.name): channels \(ours.channels)")

            guard let ref = Self.decodeReference(path: path, audioIndex: idx, channels: expectedChannels, seconds: 3.0)
            else {
                Issue.record("\(spec.name): reference decode failed")
                continue
            }
            var report: [String] = []
            for c in 0..<expectedChannels {
                let corr = Self.bestCorrelation(
                    ours: ours.samples, ref: ref, channels: expectedChannels, channel: c,
                    start: 24000, window: 2048, maxLag: 768)
                report.append(String(format: "%.3f", corr))
                #expect(corr > 0.98, "\(spec.name) channel \(c) correlation \(corr)")
            }
            print("[Reference] \(spec.name): correlation per channel = \(report)")
        }
    }

    @Test("Seek joints are click-free and timestamp-continuous for every codec in the matrix")
    func testSeekJointsAcrossCodecs() {
        guard let path = SyntheticTestMediaFactory.ensureMedia(preset: .audioCodecMatrix) else { return }
        for (idx, spec) in SyntheticTestMediaFactory.audioMatrixTracks.enumerated() {
            guard let demuxer = MediaDemuxer(url: path) else { return }
            demuxer.selectAudioTrack(trackId: idx)
            guard let params = demuxer.getAudioCodecParameters(),
                let decoder = FFAudioDecoder(codecParameters: params, timebase: demuxer.audioTimebase)
            else { continue }

            for target in [1.0, 4.0, 2.0] {
                decoder.flush()
                demuxer.seek(to: target)
                var expectedPts: Double?
                var last: [Float] = []
                var clicks = 0
                var gaps = 0
                var decoded = 0
                while decoded < 40, let pkt = demuxer.nextAudioPacket() {
                    for sb in decoder.decode(packetData: pkt.data, pts: pkt.pts, timebase: demuxer.audioTimebase) {
                        decoded += 1
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        let n = CMSampleBufferGetNumSamples(sb)
                        if let e = expectedPts, abs(pts - e) * 48000 > 1.5 { gaps += 1 }
                        expectedPts = pts + Double(n) / 48000
                        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                        let length = CMBlockBufferGetDataLength(block)
                        let channels = max(1, length / max(1, n) / 4)
                        var chunk = [Float](repeating: 0, count: length / 4)
                        chunk.withUnsafeMutableBytes {
                            _ = CMBlockBufferCopyDataBytes(
                                block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                        }
                        if last.count != channels { last = [Float](repeating: 0, count: channels) }
                        for i in 0..<n {
                            for c in 0..<channels {
                                let v = chunk[i * channels + c]
                                if !v.isFinite || abs(v - last[c]) > 0.5 { clicks += 1 }
                                last[c] = v
                            }
                        }
                    }
                }
                #expect(decoded > 0, "\(spec.name): no audio after seek to \(target)")
                #expect(gaps == 0, "\(spec.name): \(gaps) PTS gaps after seek to \(target)")
                #expect(clicks == 0, "\(spec.name): \(clicks) clicks after seek to \(target)")
            }
        }
    }
}
