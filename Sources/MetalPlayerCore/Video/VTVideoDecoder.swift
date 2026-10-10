import CoreMedia
import Foundation
import VideoToolbox
import os

public final class VTVideoDecoder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var session: VTDecompressionSession?
    private var currentFormatDescription: CMFormatDescription?
    private var lastCreationStatus: OSStatus = noErr
    private var _lastDecodeStatus: OSStatus = noErr
    private var _lastCallbackStatus: OSStatus = noErr

    public var lastDecodeStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return _lastDecodeStatus
    }

    public var lastCallbackStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return _lastCallbackStatus
    }

    public var hasActiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    public var sessionStatus: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return lastCreationStatus
    }

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
        lock.lock()
        defer { lock.unlock() }
        self.outputHandler = handler
    }

    public func decode(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        lock.lock()
        if session == nil || currentFormatDescription != formatDesc {
            createSession(formatDescription: formatDesc)
        }
        guard let activeSession = session else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Check if sample has kCMSampleAttachmentKey_DoNotDisplay
        var doNotDisplay = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [NSDictionary],
            let first = attachments.first
        {
            if let val = first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool {
                doNotDisplay = val
            }
        }

        let refCon = UnsafeMutableRawPointer(bitPattern: doNotDisplay ? 1 : 0)

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            activeSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: refCon,
            infoFlagsOut: &infoFlags
        )
        lock.lock()
        self._lastDecodeStatus = status
        lock.unlock()
    }

    private func createSession(formatDescription: CMFormatDescription) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        self.currentFormatDescription = formatDescription

        // Determine bit depth and range from formatDescription extensions
        var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any]
        let isFullRange = (extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) ?? false

        // Check if format is 10-bit:
        // CoreMedia format descriptions for 10-bit H.264/HEVC specify depth or contain 10-bit transfer/primaries/sub-types
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let depth = (extensions?[kCMFormatDescriptionExtension_Depth as String] as? NSNumber)?.intValue ?? 24
        let transfer = extensions?[kCVImageBufferTransferFunctionKey as String] as? String

        let is10Bit =
            depth > 24 || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || mediaSubType == kCMVideoCodecType_HEVC || mediaSubType == kCMVideoCodecType_HEVCWithAlpha
            || mediaSubType == kCMVideoCodecType_DolbyVisionHEVC

        if is10Bit {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat =
                isFullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLCompatibilityKey as String: false,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: {
                (
                    decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp,
                    presentationDuration
                ) in
                guard let refCon = decompressionOutputRefCon else { return }
                let decoder = Unmanaged<VTVideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.lock.lock()
                decoder._lastCallbackStatus = status
                decoder.lock.unlock()
                guard status == noErr, let imageBuffer else { return }
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

        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        self.lastCreationStatus = status
        if status == noErr {
            self.session = newSession
        } else {
            AppLog.error(.video, "VTDecompressionSessionCreate failed: \(status)")
        }
    }

    public func flush() {
        lock.lock()
        let s = session
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
        }
    }

    /// Explicitly resets and invalidates the decompression session.
    /// Next decode call will create a fresh session, preventing hardware decoder deadlocks.
    public func resetSession() {
        lock.lock()
        let oldSession = self.session
        self.session = nil
        self.currentFormatDescription = nil
        lock.unlock()

        if let oldSession {
            VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
            VTDecompressionSessionInvalidate(oldSession)
        }
    }

    deinit {
        lock.lock()
        outputHandler = nil
        let s = session
        self.session = nil
        lock.unlock()
        if let s {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
    }
}
