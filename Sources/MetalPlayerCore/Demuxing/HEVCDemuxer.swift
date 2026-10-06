import Foundation
import CoreMedia
import VideoToolbox
import CFFmpeg

public final class HEVCDemuxer: @unchecked Sendable {
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var timebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var durationSeconds: Double = 0
    public private(set) var width: Int = 0
    public private(set) var height: Int = 0
    public private(set) var maxPeakNits: Float = 1000.0
    public private(set) var colorPrimaries: CFString = kCVImageBufferColorPrimaries_ITU_R_2020
    public private(set) var transferFunction: CFString = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    public private(set) var yCbCrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_2020
    public private(set) var isFullRange: Bool = false
    private var masteringDisplay: Data?
    private var contentLightLevel: Data?

    private let lock = NSLock()

    public init?(url: String) {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        let ret = avformat_open_input(&ctx, url, nil, nil)
        guard ret >= 0, let formatCtx = ctx else { return nil }
        self.formatCtx = formatCtx

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            avformat_close_input(&self.formatCtx)
            return nil
        }

        for i in 0..<Int(formatCtx.pointee.nb_streams) {
            let stream = formatCtx.pointee.streams[i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO &&
               stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                self.videoStreamIndex = i
                self.timebase = stream.pointee.time_base
                self.width = Int(stream.pointee.codecpar.pointee.width)
                self.height = Int(stream.pointee.codecpar.pointee.height)
                if stream.pointee.duration > 0 {
                    self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
                } else if formatCtx.pointee.duration > 0 {
                    self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
                }

                // Dynamically map color primaries
                if let primaries = CVColorPrimariesGetStringForIntegerCodePoint(Int32(stream.pointee.codecpar.pointee.color_primaries.rawValue)) {
                    self.colorPrimaries = primaries.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_primaries {
                    case AVCOL_PRI_BT709:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
                    case AVCOL_PRI_BT2020:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
                    case AVCOL_PRI_SMPTE431:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_DCI_P3
                    case AVCOL_PRI_SMPTE432:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_P3_D65
                    default:
                        self.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020
                    }
                }

                // Dynamically map transfer characteristics (TRC)
                if let trc = CVTransferFunctionGetStringForIntegerCodePoint(Int32(stream.pointee.codecpar.pointee.color_trc.rawValue)) {
                    self.transferFunction = trc.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_trc {
                    case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_SMPTE240M:
                        self.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
                    case AVCOL_TRC_SMPTE2084:
                        self.transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    case AVCOL_TRC_ARIB_STD_B67:
                        self.transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
                    case AVCOL_TRC_GAMMA22:
                        self.transferFunction = kCVImageBufferTransferFunction_UseGamma
                    case AVCOL_TRC_LINEAR:
                        self.transferFunction = kCVImageBufferTransferFunction_Linear
                    default:
                        self.transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                    }
                }

                // Dynamically map YCbCr color matrix / colorspace
                if let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(stream.pointee.codecpar.pointee.color_space.rawValue)) {
                    self.yCbCrMatrix = matrix.takeUnretainedValue()
                } else {
                    switch stream.pointee.codecpar.pointee.color_space {
                    case AVCOL_SPC_BT709:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
                    case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
                    case AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
                    default:
                        self.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
                    }
                }

                // Range
                if stream.pointee.codecpar.pointee.color_range == AVCOL_RANGE_JPEG {
                    self.isFullRange = true
                } else {
                    self.isFullRange = false
                }

                break
            }
        }

        guard videoStreamIndex >= 0 else {
            avformat_close_input(&self.formatCtx)
            return nil
        }

        self.formatDescription = extractHEVCFormatDescription()
    }

    private func extractHEVCFormatDescription() -> CMVideoFormatDescription? {
        guard let ctx = formatCtx else { return nil }
        var pkt = AVPacket()
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var masteringDisplay: Data?
        var contentLightLevel: Data?

        var packetsScanned = 0
        let maxPacketsToScan = 120

        while packetsScanned < maxPacketsToScan && av_read_frame(ctx, &pkt) >= 0 {
            packetsScanned += 1
            if pkt.stream_index == videoStreamIndex {
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let nalus = Self.extractNALUnits(from: data)
                for naluData in nalus {
                    guard !naluData.isEmpty else { continue }
                    let nalType = (naluData[0] >> 1) & 0x3F

                    if nalType == 32 { vps = naluData }
                    else if nalType == 33 { sps = naluData }
                    else if nalType == 34 { pps = naluData }
                    else if nalType == 39 {
                        // Parse Prefix SEI messages
                        var p = 2
                        while p < naluData.count {
                            var payloadType = 0
                            while p < naluData.count && naluData[p] == 0xFF {
                                payloadType += 255
                                p += 1
                            }
                            if p < naluData.count {
                                payloadType += Int(naluData[p])
                                p += 1
                            }

                            var payloadSize = 0
                            while p < naluData.count && naluData[p] == 0xFF {
                                payloadSize += 255
                                p += 1
                            }
                            if p < naluData.count {
                                payloadSize += Int(naluData[p])
                                p += 1
                            }

                            guard p + payloadSize <= naluData.count else { break }
                            let rawPayload = naluData.subdata(in: p..<(p + payloadSize))

                            // Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00)
                            var unescaped: [UInt8] = []
                            unescaped.reserveCapacity(rawPayload.count)
                            var u = 0
                            let rawBytes = [UInt8](rawPayload)
                            while u < rawBytes.count {
                                if u + 2 < rawBytes.count && rawBytes[u] == 0 && rawBytes[u+1] == 0 && rawBytes[u+2] == 3 {
                                    unescaped.append(0)
                                    unescaped.append(0)
                                    u += 3
                                } else {
                                    unescaped.append(rawBytes[u])
                                    u += 1
                                }
                            }

                            // SEI 137: Mastering display colour volume (24 bytes)
                            if payloadType == 137 && unescaped.count >= 24 {
                                masteringDisplay = Data(unescaped[0..<24])
                            }
                            // SEI 144: Content light level info (4 bytes: maxCLL 2 bytes, maxFALL 2 bytes)
                            else if payloadType == 144 && unescaped.count >= 4 {
                                contentLightLevel = Data(unescaped[0..<4])
                                let maxCLL = (Int(unescaped[0]) << 8) | Int(unescaped[1])
                                if maxCLL > 0 {
                                    self.maxPeakNits = Float(maxCLL)
                                }
                            }

                            p += payloadSize
                        }
                    }
                }
                av_packet_unref(&pkt)
                if vps != nil && sps != nil && pps != nil && (masteringDisplay != nil || packetsScanned > 30) {
                    break
                }
            } else {
                av_packet_unref(&pkt)
            }
        }

        // Rewind to beginning of stream
        av_seek_frame(ctx, Int32(videoStreamIndex), 0, AVSEEK_FLAG_BACKWARD)

        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel

        guard let vpsData = vps, let spsData = sps, let ppsData = pps else { return nil }

        var extensionsDict: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: colorPrimaries as String,
            kCVImageBufferTransferFunctionKey as String: transferFunction as String,
            kCVImageBufferYCbCrMatrixKey as String: yCbCrMatrix as String,
            kCMFormatDescriptionExtension_FullRangeVideo as String: isFullRange,
            kCVImageBufferChromaLocationTopFieldKey as String: kCVImageBufferChromaLocation_Left as String,
            kCVImageBufferChromaLocationBottomFieldKey as String: kCVImageBufferChromaLocation_Left as String
        ]

        if let masteringDisplay {
            extensionsDict[kCVImageBufferMasteringDisplayColorVolumeKey as String] = masteringDisplay
        }
        if let contentLightLevel {
            extensionsDict[kCVImageBufferContentLightLevelInfoKey as String] = contentLightLevel
        }

        // Note: Do NOT inject synthetic dvvC atom into standard HEVC decoder.
        // On macOS VideoToolbox, hvc1 with dvvC atom expects specific DV profile decoders.
        // Profile 8.1 is cross-compatible HDR10/PQ; standard HEVC decodes it natively.

        var formatDesc: CMVideoFormatDescription?
        vpsData.withUnsafeBytes { vpsBytes in
            spsData.withUnsafeBytes { spsBytes in
                ppsData.withUnsafeBytes { ppsBytes in
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    let sizes: [Int] = [vpsData.count, spsData.count, ppsData.count]

                    _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: extensionsDict as CFDictionary,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        return formatDesc
    }

    private var targetPts: Int64 = -1

    public func nextVideoSample() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, let formatDesc = formatDescription else { return nil }

        var pkt = AVPacket()
        while av_read_frame(ctx, &pkt) >= 0 {
            if pkt.stream_index == videoStreamIndex {
                let (hvccData, hvccSize) = Self.packetDataToHVCC(pktData: pkt.data, count: Int(pkt.size))
                guard hvccSize > 0, let mem = malloc(hvccSize) else {
                    av_packet_unref(&pkt)
                    continue
                }
                _ = hvccData.withUnsafeBytes { rawBytes in
                    memcpy(mem, rawBytes.baseAddress!, hvccSize)
                }

                var blockBuffer: CMBlockBuffer?
                let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: mem,
                    blockLength: hvccSize,
                    blockAllocator: kCFAllocatorMalloc,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: hvccSize,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )

                if blockStatus != kCMBlockBufferNoErr {
                    free(mem)
                    av_packet_unref(&pkt)
                    continue
                }

                let noPtsValue = Int64.min
                let ptsVal = pkt.pts != noPtsValue ? pkt.pts : pkt.dts
                let dtsVal = pkt.dts != noPtsValue ? pkt.dts : ptsVal

                let timebaseDen = timebase.den
                let timebaseNum = Int64(timebase.num)
                var timing = CMSampleTimingInfo(
                    duration: pkt.duration > 0 ? CMTime(value: pkt.duration * timebaseNum, timescale: timebaseDen) : .invalid,
                    presentationTimeStamp: CMTime(value: ptsVal * timebaseNum, timescale: timebaseDen),
                    decodeTimeStamp: CMTime(value: dtsVal * timebaseNum, timescale: timebaseDen)
                )

                var sampleBuffer: CMSampleBuffer?
                var sampleSize = hvccSize
                let status = CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: blockBuffer,
                    formatDescription: formatDesc,
                    sampleCount: 1,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleSizeEntryCount: 1,
                    sampleSizeArray: &sampleSize,
                    sampleBufferOut: &sampleBuffer
                )

                let isBeforeTarget = targetPts >= 0 && ptsVal < targetPts
                if targetPts >= 0 && ptsVal >= targetPts {
                    targetPts = -1
                }

                av_packet_unref(&pkt)
                if status == noErr, let sb = sampleBuffer {
                    // Propagate HDR / SDR color metadata attachments
                    CMSetAttachment(sb, key: kCVImageBufferColorPrimariesKey, value: colorPrimaries, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    CMSetAttachment(sb, key: kCVImageBufferTransferFunctionKey, value: transferFunction, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    CMSetAttachment(sb, key: kCVImageBufferYCbCrMatrixKey, value: yCbCrMatrix, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    if let masteringDisplay {
                        CMSetAttachment(sb, key: kCVImageBufferMasteringDisplayColorVolumeKey, value: masteringDisplay as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    }
                    if let contentLightLevel {
                        CMSetAttachment(sb, key: kCVImageBufferContentLightLevelInfoKey, value: contentLightLevel as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    }

                    if isBeforeTarget {
                        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
                            first[kCMSampleAttachmentKey_DoNotDisplay] = true
                        }
                    }
                    return sb
                }
            } else {
                av_packet_unref(&pkt)
            }
        }
        return nil
    }

    public func seek(to seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx else { return }
        let target = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        self.targetPts = target
        let ret = av_seek_frame(ctx, Int32(videoStreamIndex), target, AVSEEK_FLAG_BACKWARD)
        print("[HEVCDemuxer] av_seek_frame to targetPts: \(target) (seconds: \(seconds)), ret: \(ret)")
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
    }

    // MARK: - Annex B / HVCC Utilities

    /// Parses NAL units from either Annex B byte stream (0x000001 or 0x00000001 start codes)
    /// or MP4/hvcC format (4-byte big endian length prefixed).
    static func extractNALUnits(from data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        let count = bytes.count

        // Check if stream begins with an Annex B start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
        let isAnnexB = (bytes[0] == 0 && bytes[1] == 0 && (bytes[2] == 1 || (count > 3 && bytes[2] == 0 && bytes[3] == 1)))

        if isAnnexB {
            var nalus: [Data] = []
            var starts: [(offset: Int, prefixLen: Int)] = []

            var i = 0
            while i + 2 < count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 {
                        starts.append((offset: i, prefixLen: 3))
                        i += 3
                        continue
                    } else if i + 3 < count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        starts.append((offset: i, prefixLen: 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            for (idx, start) in starts.enumerated() {
                let nalStart = start.offset + start.prefixLen
                let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
                if nalEnd > nalStart {
                    nalus.append(data.subdata(in: nalStart..<nalEnd))
                }
            }
            return nalus
        } else {
            // Standard MP4 length-prefixed format
            var nalus: [Data] = []
            var offset = 0
            while offset + 4 <= count {
                let naluLen = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard naluLen > 0, offset + naluLen <= count else { break }
                nalus.append(data.subdata(in: offset..<(offset + naluLen)))
                offset += naluLen
            }
            return nalus
        }
    }

    /// Converts an input packet to HVCC format expected by VideoToolbox (4-byte length prefix).
    /// If packet is already in length-prefixed format, it returns the raw packet bytes directly.
    static func packetDataToHVCC(pktData: UnsafePointer<UInt8>?, count: Int) -> (Data, Int) {
        guard let pktData, count >= 4 else {
            return (Data(), 0)
        }

        let isAnnexB = (pktData[0] == 0 && pktData[1] == 0 && (pktData[2] == 1 || (count > 3 && pktData[2] == 0 && pktData[3] == 1)))

        if !isAnnexB {
            let data = Data(bytes: pktData, count: count)
            return (data, count)
        }

        // Convert Annex B to 4-byte length prefix
        var starts: [(offset: Int, prefixLen: Int)] = []
        var i = 0
        while i + 2 < count {
            if pktData[i] == 0 && pktData[i + 1] == 0 {
                if pktData[i + 2] == 1 {
                    starts.append((offset: i, prefixLen: 3))
                    i += 3
                    continue
                } else if i + 3 < count && pktData[i + 2] == 0 && pktData[i + 3] == 1 {
                    starts.append((offset: i, prefixLen: 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        var hvccData = Data()
        hvccData.reserveCapacity(count + 32)

        for (idx, start) in starts.enumerated() {
            let nalStart = start.offset + start.prefixLen
            let nalEnd = (idx + 1 < starts.count) ? starts[idx + 1].offset : count
            let nalSize = nalEnd - nalStart
            guard nalSize > 0 else { continue }

            var bigEndianLength = UInt32(nalSize).bigEndian
            withUnsafeBytes(of: &bigEndianLength) { lenBytes in
                hvccData.append(contentsOf: lenBytes)
            }
            let nalPtr = pktData.advanced(by: nalStart)
            hvccData.append(nalPtr, count: nalSize)
        }

        let finalCount = hvccData.count
        return (hvccData, finalCount)
    }
}
