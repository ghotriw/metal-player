import CoreVideo
import Foundation

/// Fast analyzer for CVPixelBuffer to detect frame changes, stutters, and freezes without external dependencies.
public enum PixelBufferAnalyzer {

    /// Computes a lightweight 64-bit sampling hash of the pixel buffer's first plane (Y or BGRA).
    /// Samples a grid of pixels to be extremely fast (< 0.1ms per frame).
    public static func computeSamplingHash(of pixelBuffer: CVPixelBuffer, sampleStep: Int = 16) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let bufferPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // FNV-1a 64-bit hash
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        let stepY = max(1, sampleStep)
        let stepX = max(1, sampleStep)

        for y in stride(from: 0, to: height, by: stepY) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: stepX) {
                let byte = bufferPtr[rowOffset + x]
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }

        return hash
    }

    /// Computes normalized Mean Absolute Difference (MAD) between two pixel buffers.
    /// Returns a value in [0.0, 1.0], where 0.0 means identical frames.
    public static func computeNormalizedMAD(
        _ bufA: CVPixelBuffer,
        _ bufB: CVPixelBuffer,
        sampleStep: Int = 16
    ) -> Double {
        let widthA = CVPixelBufferGetWidth(bufA)
        let heightA = CVPixelBufferGetHeight(bufA)
        let widthB = CVPixelBufferGetWidth(bufB)
        let heightB = CVPixelBufferGetHeight(bufB)

        guard widthA == widthB && heightA == heightB else { return 1.0 }

        CVPixelBufferLockBaseAddress(bufA, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bufA, .readOnly) }

        CVPixelBufferLockBaseAddress(bufB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bufB, .readOnly) }

        guard let ptrA = CVPixelBufferGetBaseAddress(bufA)?.assumingMemoryBound(to: UInt8.self),
            let ptrB = CVPixelBufferGetBaseAddress(bufB)?.assumingMemoryBound(to: UInt8.self)
        else {
            return 1.0
        }

        let bprA = CVPixelBufferGetBytesPerRow(bufA)
        let bprB = CVPixelBufferGetBytesPerRow(bufB)

        var totalDiff: UInt64 = 0
        var samplesCount: UInt64 = 0

        for y in stride(from: 0, to: heightA, by: sampleStep) {
            let offsetA = y * bprA
            let offsetB = y * bprB
            for x in stride(from: 0, to: widthA, by: sampleStep) {
                let valA = Int32(ptrA[offsetA + x])
                let valB = Int32(ptrB[offsetB + x])
                totalDiff += UInt64(abs(valA - valB))
                samplesCount += 1
            }
        }

        guard samplesCount > 0 else { return 0.0 }
        return Double(totalDiff) / Double(samplesCount * 255)
    }
}
