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
                var offset = 0
                while offset + 4 <= data.count {
                    let naluLen = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                    offset += 4
                    guard naluLen > 0, offset + naluLen <= data.count else { break }
                    let naluData = data.subdata(in: offset..<(offset + naluLen))
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

                    offset += naluLen
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
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            kCMFormatDescriptionExtension_FullRangeVideo as String: false,
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
                let size = Int(pkt.size)
                let mem = malloc(size)!
                memcpy(mem, pkt.data, size)

                var blockBuffer: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: mem,
                    blockLength: size,
                    blockAllocator: kCFAllocatorMalloc,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: size,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )

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
                var sampleSize = size
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
                    // Propagate HDR color metadata attachments
                    CMSetAttachment(sb, key: kCVImageBufferColorPrimariesKey, value: kCVImageBufferColorPrimaries_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    CMSetAttachment(sb, key: kCVImageBufferTransferFunctionKey, value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                    CMSetAttachment(sb, key: kCVImageBufferYCbCrMatrixKey, value: kCVImageBufferYCbCrMatrix_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
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
}
