import CoreMedia
import CoreVideo
import Foundation

public final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [VTVideoDecoder.DecodedFrame] = []
    private var lastRenderedBuffer: CVPixelBuffer?

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    public func push(_ frame: VTVideoDecoder.DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        let idx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: idx)
        // Keep up to 60 frames in buffer without ever discarding imminent head frames
        if frames.count > 60 {
            frames.removeLast()
        }
    }

    public func popFrame(forSyncTime syncTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }

        let maxLeadTime = CMTime(value: 50, timescale: 1000)
        var chosen: CVPixelBuffer?
        while !frames.isEmpty {
            let frame = frames[0]
            if frame.pts <= syncTime + maxLeadTime {
                if !frame.doNotDisplay {
                    chosen = frame.pixelBuffer
                }
                frames.removeFirst()
            } else {
                break
            }
        }
        if let chosen {
            lastRenderedBuffer = chosen
        }
        return chosen
    }

    public func getLatestFrame(forSyncTime syncTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let frame = frames.last(where: {
            !$0.doNotDisplay && $0.pts <= syncTime + CMTime(value: 100, timescale: 1000)
        }) {
            lastRenderedBuffer = frame.pixelBuffer
            return frame.pixelBuffer
        }
        if let firstDisplayable = frames.first(where: { !$0.doNotDisplay }) {
            lastRenderedBuffer = firstDisplayable.pixelBuffer
            return firstDisplayable.pixelBuffer
        }
        return lastRenderedBuffer
    }

    public func getLastRenderedBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedBuffer
    }

    public func clear() {
        lock.lock()
        frames.removeAll()
        lastRenderedBuffer = nil
        lock.unlock()
    }
}
