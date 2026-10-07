import CoreMedia
import CoreVideo
import Testing

@testable import MetalPlayerCore

@Suite("FrameQueue Invariant Tests")
struct FrameQueueTests {
    private func createDummyPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        precondition(status == kCVReturnSuccess && pixelBuffer != nil)
        return pixelBuffer!
    }

    @Test("Frames are sorted by presentation timestamp (PTS) regardless of push order")
    func testPTSSorting() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()
        let buf3 = createDummyPixelBuffer()

        // Push B-frames out of order: 2.0s, 1.0s, 3.0s
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(seconds: 2.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf3, pts: CMTime(seconds: 3.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))

        #expect(queue.count == 3)

        // Popping at 1.0s should yield buf1 first
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped === buf1)
        #expect(queue.count == 2)
    }

    @Test("DoNotDisplay frames are discarded and never returned to the renderer")
    func testDoNotDisplayDiscarded() {
        let queue = FrameQueue()
        let buf1 = createDummyPixelBuffer()
        let buf2 = createDummyPixelBuffer()

        // Frame 1 marked as doNotDisplay
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf1, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000), doNotDisplay: true))
        // Frame 2 is displayable
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf2, pts: CMTime(seconds: 1.04, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000), doNotDisplay: false))

        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.05, preferredTimescale: 1000))
        #expect(popped === buf2)
    }

    @Test("Future frames exceeding lead time are held in the queue")
    func testFutureFramesHeld() {
        let queue = FrameQueue()
        let buf = createDummyPixelBuffer()

        // Frame is at 5.0 seconds
        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf, pts: CMTime(seconds: 5.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))

        // Querying at 1.0s should return nil and preserve the frame
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped == nil)
        #expect(queue.count == 1)
    }

    @Test("Clear discards all frames and last rendered buffer")
    func testQueueClear() {
        let queue = FrameQueue()
        let buf = createDummyPixelBuffer()

        queue.push(
            VTVideoDecoder.DecodedFrame(
                pixelBuffer: buf, pts: CMTime(seconds: 1.0, preferredTimescale: 1000),
                duration: CMTime(value: 41, timescale: 1000)))
        _ = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(queue.getLastRenderedBuffer() === buf)

        queue.clear()
        #expect(queue.count == 0)
        #expect(queue.getLastRenderedBuffer() == nil)
    }

    @Test("Queue overflow preserves imminent head frames and discards furthest future frames")
    func testQueueOverflowPreservesHeadFrames() {
        let queue = FrameQueue()
        var firstBuffer: CVPixelBuffer?

        for i in 1...65 {
            let buf = createDummyPixelBuffer()
            if i == 1 { firstBuffer = buf }
            let pts = CMTime(seconds: Double(i), preferredTimescale: 1000)
            queue.push(
                VTVideoDecoder.DecodedFrame(pixelBuffer: buf, pts: pts, duration: CMTime(value: 41, timescale: 1000)))
        }

        #expect(queue.count == 60)
        // Earliest frame (PTS 1.0) must still be at the head of the queue!
        let popped = queue.popFrame(forSyncTime: CMTime(seconds: 1.0, preferredTimescale: 1000))
        #expect(popped === firstBuffer)
    }

    @Test("Ring buffer handles wrap-around cycles and complex B-frame out-of-order bursts")
    func testRingBufferWrapAroundAndBFrames() {
        let queue = FrameQueue(capacity: 10)

        // Run multiple cycles to force head/tail index wrap-around past capacity
        for cycle in 0..<5 {
            let baseSeconds = Double(cycle * 10)
            // Push frames: [base + 0, base + 2 (P-frame), base + 1 (B-frame), base + 4 (P-frame), base + 3 (B-frame)]
            let ptsOrder = [0.0, 2.0, 1.0, 4.0, 3.0]
            var buffers: [Double: CVPixelBuffer] = [:]

            for offset in ptsOrder {
                let buf = createDummyPixelBuffer()
                let ptsSec = baseSeconds + offset
                buffers[ptsSec] = buf
                queue.push(
                    VTVideoDecoder.DecodedFrame(
                        pixelBuffer: buf,
                        pts: CMTime(seconds: ptsSec, preferredTimescale: 1000),
                        duration: CMTime(value: 41, timescale: 1000)
                    )
                )
            }

            #expect(queue.count == 5)

            // Verify popped sequence is strictly sorted: 0.0, 1.0, 2.0, 3.0, 4.0
            let expectedOffsets = [0.0, 1.0, 2.0, 3.0, 4.0]
            for offset in expectedOffsets {
                let ptsSec = baseSeconds + offset
                let popped = queue.popFrame(forSyncTime: CMTime(seconds: ptsSec, preferredTimescale: 1000))
                #expect(popped === buffers[ptsSec])
            }
            #expect(queue.count == 0)
        }
    }
}
