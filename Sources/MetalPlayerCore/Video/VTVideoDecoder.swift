import Foundation
import CoreMedia
import VideoToolbox
import os

public final class VTVideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var currentFormatDescription: CMFormatDescription?

    public struct DecodedFrame: @unchecked Sendable {
        public let pixelBuffer: CVPixelBuffer
        public let pts: CMTime
        public let duration: CMTime
        public let doNotDisplay: Bool

        public init(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime, doNotDisplay: Bool = false) {
            self.pixelBuffer = pixelBuffer
            self.pts = pts
            self.duration = duration
            self.doNotDisplay = doNotDisplay
        }
    }

    public typealias OutputHandler = @Sendable (DecodedFrame) -> Void
    private var outputHandler: OutputHandler?

    public init() {}

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        self.outputHandler = handler
    }

    public func decode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        if session == nil || currentFormatDescription != formatDesc {
            createSession(formatDescription: formatDesc)
        }

        guard let session else { return }

        // Check if sample has kCMSampleAttachmentKey_DoNotDisplay
        var doNotDisplay = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
           let first = attachments.first {
            if let val = first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool {
                doNotDisplay = val
            }
        }

        let refCon = UnsafeMutableRawPointer(bitPattern: doNotDisplay ? 1 : 0)

        var infoFlags = VTDecodeInfoFlags()
        _ = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: refCon,
            infoFlagsOut: &infoFlags
        )
    }

    private func createSession(formatDescription: CMFormatDescription) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        self.currentFormatDescription = formatDescription

        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLCompatibilityKey as String: false
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                guard status == noErr, let imageBuffer else { return }
                guard let refCon = decompressionOutputRefCon else { return }
                let decoder = Unmanaged<VTVideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                let doNotDisplay = (Int(bitPattern: sourceFrameRefCon) == 1)
                let frame = DecodedFrame(
                    pixelBuffer: imageBuffer,
                    pts: presentationTimeStamp,
                    duration: presentationDuration,
                    doNotDisplay: doNotDisplay
                )
                decoder.outputHandler?(frame)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        if status == noErr {
            self.session = newSession
        } else {
            print("[VTVideoDecoder] VTDecompressionSessionCreate failed:", status)
        }
    }

    public func flush() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
