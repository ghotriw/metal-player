import CoreMedia
import CoreVideo
import Foundation
import os

/// A high-performance, PTS-sorted ring buffer for decoded video frames.
///
/// Designed specifically for VSYNC deadlines up to 120Hz (ProMotion):
/// - **Zero Allocation:** Backed by a fixed-capacity ring buffer (`[DecodedFrame?]`), avoiding memory reallocations.
/// - **O(1) Pop & Instant Surface Release:** Fast head pointer advancement and immediate `nil` clearing of popped slots,
///   promptly returning `IOSurface` backing memory to the `VTDecompressionSession` hardware pool.
/// - **PTS Sorting with Fast-Path Append & Binary Search:** Preserves strict PTS ordering across B-frames.
///   95% of frames (in-order PTS) append at `tail` in O(1); out-of-order B-frames (1–3 slots backward) use O(log N)
///   binary search and minimal slot shifting within the ring.
public final class FrameQueue: @unchecked Sendable {
    public static let defaultCapacity: Int = 60

    private let lock = OSAllocatedUnfairLock()
    private let capacity: Int
    private var buffer: [VTVideoDecoder.DecodedFrame?]
    private var head: Int = 0
    private var countInternal: Int = 0
    private var lastRenderedBuffer: CVPixelBuffer?

    public init(capacity: Int = defaultCapacity) {
        precondition(capacity > 0, "Capacity must be positive")
        self.capacity = capacity
        self.buffer = [VTVideoDecoder.DecodedFrame?](repeating: nil, count: capacity)
    }

    /// The number of decoded frames currently held in the buffer.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countInternal
    }

    /// Pushes a decoded frame into the queue, maintaining strict ascending PTS order.
    /// If the buffer is full, the furthest future frame at the tail is discarded to preserve imminent playback frames.
    public func push(_ frame: VTVideoDecoder.DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }

        if countInternal == 0 {
            buffer[head] = frame
            countInternal = 1
            return
        }

        // Fast path (95%+ of video playback): Monotonically increasing PTS appends directly to tail in O(1)
        let lastPhysicalIdx = (head + countInternal - 1) % capacity
        if let lastFrame = buffer[lastPhysicalIdx], frame.pts >= lastFrame.pts {
            if countInternal < capacity {
                let nextTail = (head + countInternal) % capacity
                buffer[nextTail] = frame
                countInternal += 1
            } else {
                // Buffer is full: discard furthest future frame at tail, keep imminent head frames
                buffer[lastPhysicalIdx] = frame
            }
            return
        }

        // B-frame out-of-order path: Find insertion point relative to logical queue [0 ..< countInternal]
        // Binary search in O(log N)
        var low = 0
        var high = countInternal
        while low < high {
            let mid = low + (high - low) / 2
            let physicalMid = (head + mid) % capacity
            if let midFrame = buffer[physicalMid], midFrame.pts <= frame.pts {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let insertIndex = low  // logical index in [0 ... countInternal]

        if countInternal < capacity {
            // Shift elements right starting from insertIndex up to countInternal - 1
            var i = countInternal
            while i > insertIndex {
                let fromIdx = (head + i - 1) % capacity
                let toIdx = (head + i) % capacity
                buffer[toIdx] = buffer[fromIdx]
                i -= 1
            }
            let targetIdx = (head + insertIndex) % capacity
            buffer[targetIdx] = frame
            countInternal += 1
        } else {
            // Buffer is full and insertIndex is within existing frames:
            // Drop furthest future frame at tail and shift elements right from insertIndex to capacity - 2
            if insertIndex < capacity {
                var i = capacity - 1
                while i > insertIndex {
                    let fromIdx = (head + i - 1) % capacity
                    let toIdx = (head + i) % capacity
                    buffer[toIdx] = buffer[fromIdx]
                    i -= 1
                }
                let targetIdx = (head + insertIndex) % capacity
                buffer[targetIdx] = frame
            }
        }
    }

    /// Pops the next frame whose PTS matches or precedes `syncTime + maxLeadTime`.
    /// Immediately releases the internal `DecodedFrame` reference and returns its `CVPixelBuffer`.
    public func popFrame(forSyncTime syncTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard countInternal > 0 else { return nil }

        let maxLeadTime = CMTime(value: 50, timescale: 1000)
        var chosen: CVPixelBuffer?

        while countInternal > 0 {
            guard let frame = buffer[head] else {
                // Inconsistent slot guard
                head = (head + 1) % capacity
                countInternal -= 1
                continue
            }

            if frame.pts <= syncTime + maxLeadTime {
                if !frame.doNotDisplay {
                    chosen = frame.pixelBuffer
                }
                // Zero out reference immediately to return IOSurface to hardware pool
                buffer[head] = nil
                head = (head + 1) % capacity
                countInternal -= 1
            } else {
                break
            }
        }

        if let chosen {
            lastRenderedBuffer = chosen
        }
        return chosen
    }

    /// Retrieves the latest displayable frame matching `syncTime + leadTime`, without popping from the queue.
    public func getLatestFrame(forSyncTime syncTime: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard countInternal > 0 else { return lastRenderedBuffer }

        let leadThreshold = syncTime + CMTime(value: 100, timescale: 1000)
        var latestMatching: CVPixelBuffer?

        // Scan backward from newest frame
        for i in stride(from: countInternal - 1, through: 0, by: -1) {
            let physicalIdx = (head + i) % capacity
            if let frame = buffer[physicalIdx], !frame.doNotDisplay, frame.pts <= leadThreshold {
                latestMatching = frame.pixelBuffer
                break
            }
        }

        if let latestMatching {
            lastRenderedBuffer = latestMatching
            return latestMatching
        }

        // Fallback: first displayable frame
        for i in 0..<countInternal {
            let physicalIdx = (head + i) % capacity
            if let frame = buffer[physicalIdx], !frame.doNotDisplay {
                lastRenderedBuffer = frame.pixelBuffer
                return frame.pixelBuffer
            }
        }

        return lastRenderedBuffer
    }

    /// Returns the most recently rendered `CVPixelBuffer` for freeze-frame display parity during pause.
    public func getLastRenderedBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedBuffer
    }

    /// Clears all frames and releases all `IOSurface` backing buffers immediately.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<capacity {
            buffer[i] = nil
        }
        head = 0
        countInternal = 0
        lastRenderedBuffer = nil
    }
}
