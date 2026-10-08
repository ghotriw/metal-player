import CFFmpeg
import CoreMedia
import Foundation
import VideoToolbox

public final class MediaDemuxer: @unchecked Sendable {
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var audioStreamIndex: Int = -1
    private var timebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var audioTimebase: AVRational = AVRational(num: 1, den: 1000)
    public private(set) var codec: VideoCodec = .hevc
    public private(set) var hasAudio: Bool = false
    public private(set) var audioCodecId: AVCodecID = AV_CODEC_ID_NONE
    public private(set) var audioChannels: Int = 0
    public private(set) var audioSampleRate: Int = 0
    public struct AudioTrack: Sendable, Identifiable {
        public let id: Int
        public let streamIndex: Int
        public let title: String
        public let language: String
        public let codecName: String
        public let channels: Int
        public let sampleRate: Int
    }

    public private(set) var audioTracks: [AudioTrack] = []
    public private(set) var selectedAudioTrackIndex: Int = -1
    public private(set) var audioExtraData: Data? = nil
    private var lastAudioPts: Int64 = -1
    public var currentAudioPtsSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastAudioPts >= 0 && audioTimebase.den > 0 else { return 0 }
        return Double(lastAudioPts) * Double(audioTimebase.num) / Double(audioTimebase.den)
    }

    public func getAudioCodecParameters() -> UnsafePointer<AVCodecParameters>? {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, audioStreamIndex >= 0 else { return nil }
        return UnsafePointer(ctx.pointee.streams[audioStreamIndex]!.pointee.codecpar)
    }

    public func selectAudioTrack(trackId: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx, let track = audioTracks.first(where: { $0.id == trackId }) else { return }
        self.audioStreamIndex = track.streamIndex
        self.selectedAudioTrackIndex = track.id
        let stream = ctx.pointee.streams[track.streamIndex]!
        self.audioTimebase = stream.pointee.time_base
        self.audioCodecId = stream.pointee.codecpar.pointee.codec_id
        self.audioChannels = Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels)
        self.audioSampleRate = Int(stream.pointee.codecpar.pointee.sample_rate)
        if let ed = stream.pointee.codecpar.pointee.extradata, stream.pointee.codecpar.pointee.extradata_size > 0 {
            self.audioExtraData = Data(bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
        } else {
            self.audioExtraData = nil
        }
        self.audioQueue.removeAll()
    }

    // Packet queue for demuxed audio packets
    public struct DemuxedAudioPacket: Sendable {
        public let data: Data
        public let pts: Int64
        public let dts: Int64
        public let duration: Int64
        public let isKeyFrame: Bool
    }

    // Packet queue for demuxed video packets (preserves video if audio pump reads ahead)
    private struct DemuxedVideoPacket: Sendable {
        let data: Data
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let flags: Int32
    }

    private var audioQueue: [DemuxedAudioPacket] = []
    private var videoQueue: [DemuxedVideoPacket] = []
    private let maxAudioQueueCount = 500
    private let maxVideoQueueCount = 180
    public private(set) var formatDescription: CMVideoFormatDescription?
    public private(set) var durationSeconds: Double = 0
    public private(set) var width: Int = 0
    public private(set) var height: Int = 0
    public private(set) var maxPeakNits: Float = 1000.0
    public private(set) var colorPrimaries: CFString = kCVImageBufferColorPrimaries_ITU_R_2020
    public private(set) var transferFunction: CFString = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    public private(set) var yCbCrMatrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_2020
    public private(set) var isFullRange: Bool = false
    public private(set) var bitDepth: Int = 8
    public private(set) var isDolbyVisionProfile5: Bool = false
    private var masteringDisplay: Data?
    private var contentLightLevel: Data?

    public final class InterruptContext: @unchecked Sendable {
        private let lock = NSLock()
        private var _isCancelled = false

        public init() {}

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }

        public func cancel() {
            lock.lock()
            _isCancelled = true
            lock.unlock()
        }
    }

    private let interruptContext: InterruptContext
    private let ownsInterruptContext: Bool
    private let lock = NSLock()
    private var isEOFInternal: Bool = false
    public var isEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEOFInternal
    }

    public static func isNetworkURL(_ path: String) -> Bool {
        guard let url = URL(string: path), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public convenience init?(url: String) {
        self.init(url: url, headers: [:], interruptContext: nil)
    }

    public init?(
        url: String,
        headers: [String: String] = [:],
        interruptContext: InterruptContext? = nil
    ) {
        let ctxContext = interruptContext ?? InterruptContext()
        self.interruptContext = ctxContext
        self.ownsInterruptContext = (interruptContext == nil)

        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocatedCtx = ctx else { return nil }

        // Setup interrupt callback to abort hung network requests cleanly.
        // `self.interruptContext` keeps a strong reference to `ctxContext` across the lifetime of MediaDemuxer.
        allocatedCtx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(ctxContext).toOpaque()
        allocatedCtx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            let unmanagedContext = Unmanaged<InterruptContext>.fromOpaque(opaque)
            let instance = unmanagedContext.takeUnretainedValue()
            return instance.isCancelled ? 1 : 0
        }

        var avOptions: OpaquePointer? = nil
        defer {
            if avOptions != nil {
                av_dict_free(&avOptions)
            }
        }

        let isNetworkURL = Self.isNetworkURL(url)
        if isNetworkURL {
            // Configure custom HTTP headers if present
            if !headers.isEmpty {
                var headerString = ""
                for (key, value) in headers {
                    // Sanitize against CRLF injection
                    let cleanKey = key.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    let cleanVal = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(
                        of: "\n", with: "")
                    guard !cleanKey.isEmpty else { continue }

                    if cleanKey.lowercased() == "user-agent" {
                        _ = av_dict_set(&avOptions, "user_agent", cleanVal, 0)
                    } else {
                        headerString += "\(cleanKey): \(cleanVal)\r\n"
                    }
                }
                if !headerString.isEmpty {
                    _ = av_dict_set(&avOptions, "headers", headerString, 0)
                }
            }

            // Network reconnect and timeout settings
            _ = av_dict_set(&avOptions, "reconnect", "1", 0)
            _ = av_dict_set(&avOptions, "reconnect_streamed", "1", 0)
            _ = av_dict_set(&avOptions, "reconnect_delay_max", "5", 0)
            // 10-second timeout in microseconds for network I/O
            _ = av_dict_set(&avOptions, "rw_timeout", "10000000", 0)
            _ = av_dict_set(&avOptions, "timeout", "10000000", 0)
        }

        let ret = avformat_open_input(&ctx, url, nil, &avOptions)
        guard ret >= 0, let formatCtx = ctx else {
            // Per FFmpeg avformat_open_input contract: user-allocated AVFormatContext is automatically freed on failure.
            return nil
        }
        self.formatCtx = formatCtx

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            avformat_close_input(&self.formatCtx)
            return nil
        }

        for i in 0..<Int(formatCtx.pointee.nb_streams) {
            let stream = formatCtx.pointee.streams[i]!
            let codecId = stream.pointee.codecpar.pointee.codec_id
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && (codecId == AV_CODEC_ID_HEVC || codecId == AV_CODEC_ID_H264)
            {
                self.videoStreamIndex = i
                self.timebase = stream.pointee.time_base
                self.codec = (codecId == AV_CODEC_ID_HEVC) ? .hevc : .h264
                self.width = Int(stream.pointee.codecpar.pointee.width)
                self.height = Int(stream.pointee.codecpar.pointee.height)
                if stream.pointee.duration > 0 {
                    self.durationSeconds = Double(stream.pointee.duration) * Double(timebase.num) / Double(timebase.den)
                } else if formatCtx.pointee.duration > 0 {
                    self.durationSeconds = Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)
                }

                // Dynamically map color primaries
                if let primaries = CVColorPrimariesGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_primaries.rawValue))
                {
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
                if let trc = CVTransferFunctionGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_trc.rawValue))
                {
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
                if let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(
                    Int32(stream.pointee.codecpar.pointee.color_space.rawValue))
                {
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

                // Bit depth detection
                let pixFmt = stream.pointee.codecpar.pointee.format
                if pixFmt == AV_PIX_FMT_YUV420P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV420P10BE.rawValue
                    || pixFmt == AV_PIX_FMT_YUV422P10LE.rawValue || pixFmt == AV_PIX_FMT_YUV444P10LE.rawValue
                    || (codecId == AV_CODEC_ID_HEVC
                        && (self.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                            || self.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG))
                {
                    self.bitDepth = 10
                } else {
                    self.bitDepth = 8
                }

                // Dolby Vision Profile 5 detection:
                // Profile 5 uses IPTc2 color space with PQ transfer function.
                // In MP4/MKV it is identified by dvvC/dvcC box (dv_profile == 5)
                // or DOVI side data in stream.
                if let extradata = stream.pointee.codecpar.pointee.extradata,
                    stream.pointee.codecpar.pointee.extradata_size >= 24
                {
                    let extraDataSize = Int(stream.pointee.codecpar.pointee.extradata_size)
                    let extraBytes = UnsafeBufferPointer(start: extradata, count: extraDataSize)
                    for k in 0..<(extraDataSize - 8) {
                        // Check for 'dvcC' or 'dvvC' fourcc
                        if (extraBytes[k] == 0x64 && extraBytes[k + 1] == 0x76 && extraBytes[k + 2] == 0x63
                            && extraBytes[k + 3] == 0x43)
                            || (extraBytes[k] == 0x64 && extraBytes[k + 1] == 0x76 && extraBytes[k + 2] == 0x76
                                && extraBytes[k + 3] == 0x43)
                        {
                            // dv_profile is in the high 7 bits of byte at offset + 6
                            let dvProfile = (extraBytes[k + 6] >> 1) & 0x7F
                            if dvProfile == 5 {
                                self.isDolbyVisionProfile5 = true
                                self.bitDepth = 10
                            }
                            break
                        }
                    }
                }
            } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                // Read track metadata (title, language)
                var title = ""
                var lang = ""
                if let titleTag = av_dict_get(stream.pointee.metadata, "title", nil, 0) {
                    title = String(cString: titleTag.pointee.value)
                }
                if let langTag = av_dict_get(stream.pointee.metadata, "language", nil, 0) {
                    lang = String(cString: langTag.pointee.value)
                }
                let codecNameStr: String
                if let codecDesc = avcodec_descriptor_get(codecId), let name = codecDesc.pointee.name {
                    codecNameStr = String(cString: name)
                } else {
                    codecNameStr = "audio"
                }

                let track = AudioTrack(
                    id: self.audioTracks.count,
                    streamIndex: i,
                    title: title,
                    language: lang,
                    codecName: codecNameStr,
                    channels: Int(stream.pointee.codecpar.pointee.ch_layout.nb_channels),
                    sampleRate: Int(stream.pointee.codecpar.pointee.sample_rate)
                )
                self.audioTracks.append(track)

                if self.audioStreamIndex < 0 {
                    // First audio stream found - select as default
                    self.audioStreamIndex = i
                    self.selectedAudioTrackIndex = track.id
                    self.audioTimebase = stream.pointee.time_base
                    self.audioCodecId = codecId
                    self.hasAudio = true
                    self.audioChannels = track.channels
                    self.audioSampleRate = track.sampleRate
                    if let ed = stream.pointee.codecpar.pointee.extradata,
                        stream.pointee.codecpar.pointee.extradata_size > 0
                    {
                        self.audioExtraData = Data(
                            bytes: ed, count: Int(stream.pointee.codecpar.pointee.extradata_size))
                    }
                }
            }
        }

        guard videoStreamIndex >= 0 else {
            avformat_close_input(&self.formatCtx)
            return nil
        }

        self.formatDescription = extractVideoFormatDescription()
    }

    private func parseExtradata() -> (vps: Data?, sps: Data?, pps: Data?) {
        guard let ctx = formatCtx, videoStreamIndex >= 0 else { return (nil, nil, nil) }
        let stream = ctx.pointee.streams[videoStreamIndex]!
        guard let extradata = stream.pointee.codecpar.pointee.extradata,
            stream.pointee.codecpar.pointee.extradata_size > 0
        else {
            return (nil, nil, nil)
        }
        let size = Int(stream.pointee.codecpar.pointee.extradata_size)
        let data = Data(bytes: extradata, count: size)

        // Case 1: Raw Annex B in extradata (starts with 0x00 0x00 0x01 or 0x00 0x00 0x00 0x01)
        if size >= 3 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (size > 3 && data[2] == 0 && data[3] == 1)) {
            let nalus = Self.extractNALUnits(from: data)
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for nalu in nalus {
                if codec == .hevc {
                    let nalType = (nalu[0] >> 1) & 0x3F
                    if nalType == 32 {
                        vps = nalu
                    } else if nalType == 33 {
                        sps = nalu
                    } else if nalType == 34 {
                        pps = nalu
                    }
                } else if codec == .h264 {
                    let nalType = nalu[0] & 0x1F
                    if nalType == 7 { sps = nalu } else if nalType == 8 { pps = nalu }
                }
            }
            return (vps, sps, pps)
        }

        // Case 2: H.264 avcC format (ISO/IEC 14496-15)
        if codec == .h264 && size >= 7 && data[0] == 1 {
            var offset = 5
            let numSPS = Int(data[offset] & 0x1F)
            offset += 1
            var sps: Data?
            for _ in 0..<numSPS {
                guard offset + 2 <= size else { break }
                let spsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + spsLen <= size else { break }
                sps = data.subdata(in: offset..<(offset + spsLen))
                offset += spsLen
                break  // first SPS is sufficient
            }
            guard offset < size else { return (nil, sps, nil) }
            let numPPS = Int(data[offset])
            offset += 1
            var pps: Data?
            for _ in 0..<numPPS {
                guard offset + 2 <= size else { break }
                let ppsLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + ppsLen <= size else { break }
                pps = data.subdata(in: offset..<(offset + ppsLen))
                offset += ppsLen
                break  // first PPS
            }
            return (nil, sps, pps)
        }

        // Case 3: HEVC hvcC format (ISO/IEC 14496-15)
        if codec == .hevc && size >= 23 && data[0] == 1 {
            var vps: Data?
            var sps: Data?
            var pps: Data?
            var offset = 22
            let numOfArrays = Int(data[offset])
            offset += 1

            for _ in 0..<numOfArrays {
                guard offset + 3 <= size else { break }
                let nalType = data[offset] & 0x3F
                let numNalus = Int(data[offset + 1]) << 8 | Int(data[offset + 2])
                offset += 3

                for _ in 0..<numNalus {
                    guard offset + 2 <= size else { break }
                    let nalLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                    offset += 2
                    guard offset + nalLen <= size else { break }
                    let naluData = data.subdata(in: offset..<(offset + nalLen))
                    offset += nalLen

                    if nalType == 32 {
                        vps = naluData
                    } else if nalType == 33 {
                        sps = naluData
                    } else if nalType == 34 {
                        pps = naluData
                    }
                }
            }
            return (vps, sps, pps)
        }

        return (nil, nil, nil)
    }

    private func extractVideoFormatDescription() -> CMVideoFormatDescription? {
        guard let ctx = formatCtx else { return nil }

        // Step 1: Try parsing from container extradata (avcC / hvcC / Annex B header)
        var (vps, sps, pps) = parseExtradata()
        var masteringDisplay: Data?
        var contentLightLevel: Data?

        let hasExtradataParams: Bool
        if codec == .hevc {
            hasExtradataParams = (vps != nil && sps != nil && pps != nil)
        } else {
            hasExtradataParams = (sps != nil && pps != nil)
        }

        // Step 2: Fallback to scanning packets if extradata is missing or for SEI mastering info
        var packetsScanned = 0
        let maxPacketsToScan = hasExtradataParams ? 30 : 120
        var pkt = AVPacket()

        while packetsScanned < maxPacketsToScan && av_read_frame(ctx, &pkt) >= 0 {
            packetsScanned += 1
            if pkt.stream_index == videoStreamIndex {
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let nalus = Self.extractNALUnits(from: data)
                for naluData in nalus {
                    guard !naluData.isEmpty else { continue }
                    if codec == .hevc {
                        let nalType = (naluData[0] >> 1) & 0x3F
                        if vps == nil && nalType == 32 {
                            vps = naluData
                        } else if sps == nil && nalType == 33 {
                            sps = naluData
                        } else if pps == nil && nalType == 34 {
                            pps = naluData
                        } else if nalType == 39 {
                            parsePrefixSEI(
                                naluData: naluData, masteringDisplay: &masteringDisplay,
                                contentLightLevel: &contentLightLevel)
                        }
                    } else if codec == .h264 {
                        let nalType = naluData[0] & 0x1F
                        if sps == nil && nalType == 7 {
                            sps = naluData
                        } else if pps == nil && nalType == 8 {
                            pps = naluData
                        }
                    }
                }
                av_packet_unref(&pkt)

                let hasParameters: Bool
                if codec == .hevc {
                    hasParameters = (vps != nil && sps != nil && pps != nil)
                } else {
                    hasParameters = (sps != nil && pps != nil)
                }

                if hasParameters && (masteringDisplay != nil || packetsScanned > 20) {
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

        guard let spsData = sps, let ppsData = pps else { return nil }

        var extensionsDict: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: colorPrimaries as String,
            kCVImageBufferTransferFunctionKey as String: transferFunction as String,
            kCVImageBufferYCbCrMatrixKey as String: yCbCrMatrix as String,
            kCMFormatDescriptionExtension_FullRangeVideo as String: isFullRange,
            kCVImageBufferChromaLocationTopFieldKey as String: kCVImageBufferChromaLocation_Left as String,
            kCVImageBufferChromaLocationBottomFieldKey as String: kCVImageBufferChromaLocation_Left as String,
        ]

        if let masteringDisplay {
            extensionsDict[kCVImageBufferMasteringDisplayColorVolumeKey as String] = masteringDisplay
        }
        if let contentLightLevel {
            extensionsDict[kCVImageBufferContentLightLevelInfoKey as String] = contentLightLevel
        }

        var formatDesc: CMVideoFormatDescription?
        if codec == .hevc, let vpsData = vps {
            vpsData.withUnsafeBytes { vpsBytes in
                spsData.withUnsafeBytes { spsBytes in
                    ppsData.withUnsafeBytes { ppsBytes in
                        let pointers: [UnsafePointer<UInt8>] = [
                            vpsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
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
        } else if codec == .h264 {
            spsData.withUnsafeBytes { spsBytes in
                ppsData.withUnsafeBytes { ppsBytes in
                    let pointers: [UnsafePointer<UInt8>] = [
                        spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes: [Int] = [spsData.count, ppsData.count]

                    _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        return formatDesc
    }

    private func parsePrefixSEI(naluData: Data, masteringDisplay: inout Data?, contentLightLevel: inout Data?) {
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
                if u + 2 < rawBytes.count && rawBytes[u] == 0 && rawBytes[u + 1] == 0 && rawBytes[u + 2] == 3 {
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

    private var targetPts: Int64 = -1

    private func createVideoSample(from rawData: Data, pts: Int64, dts: Int64, duration: Int64) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { return nil }

        let (hvccData, hvccSize) = rawData.withUnsafeBytes { raw in
            Self.packetDataToHVCC(pktData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: rawData.count)
        }
        guard hvccSize > 0, let mem = malloc(hvccSize) else {
            return nil
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
            return nil
        }

        let noPtsValue = Int64.min
        let ptsVal = pts != noPtsValue ? pts : dts
        let dtsVal = dts != noPtsValue ? dts : ptsVal

        let timebaseDen = timebase.den
        let timebaseNum = Int64(timebase.num)
        var timing = CMSampleTimingInfo(
            duration: duration > 0 ? CMTime(value: duration * timebaseNum, timescale: timebaseDen) : .invalid,
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

        if status == noErr, let sb = sampleBuffer {
            CMSetAttachment(
                sb, key: kCVImageBufferColorPrimariesKey, value: colorPrimaries,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            CMSetAttachment(
                sb, key: kCVImageBufferTransferFunctionKey, value: transferFunction,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            CMSetAttachment(
                sb, key: kCVImageBufferYCbCrMatrixKey, value: yCbCrMatrix,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            if let masteringDisplay {
                CMSetAttachment(
                    sb, key: kCVImageBufferMasteringDisplayColorVolumeKey, value: masteringDisplay as CFData,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            if let contentLightLevel {
                CMSetAttachment(
                    sb, key: kCVImageBufferContentLightLevelInfoKey, value: contentLightLevel as CFData,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }

            if isBeforeTarget {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
                    as? [NSMutableDictionary], let first = attachments.first
                {
                    first[kCMSampleAttachmentKey_DoNotDisplay] = true
                }
            }
            return sb
        }
        return nil
    }

    public func nextVideoSample() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        // Drain videoQueue first if audio reading buffered video packets
        while !videoQueue.isEmpty {
            let vp = videoQueue.removeFirst()
            if let sample = createVideoSample(from: vp.data, pts: vp.pts, dts: vp.dts, duration: vp.duration) {
                return sample
            }
        }

        guard let ctx = formatCtx, formatDescription != nil else { return nil }

        var pkt = AVPacket()
        while av_read_frame(ctx, &pkt) >= 0 {
            if pkt.stream_index == videoStreamIndex {
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let sample = createVideoSample(from: data, pts: pkt.pts, dts: pkt.dts, duration: pkt.duration)
                av_packet_unref(&pkt)
                if let sample {
                    return sample
                }
            } else if pkt.stream_index == audioStreamIndex {
                // Buffer audio packet for Stage 2 audio pipeline
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let isKey = (pkt.flags & AV_PKT_FLAG_KEY) != 0
                let audioPacket = DemuxedAudioPacket(
                    data: data,
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration,
                    isKeyFrame: isKey
                )
                audioQueue.append(audioPacket)
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        if videoQueue.isEmpty && audioQueue.isEmpty {
            self.isEOFInternal = true
        }
        return nil
    }

    /// Retrieves next queued audio packet if available, or pumps stream until one arrives
    public func nextAudioPacket() -> DemuxedAudioPacket? {
        lock.lock()
        defer { lock.unlock() }

        if !audioQueue.isEmpty {
            let p = audioQueue.removeFirst()
            self.lastAudioPts = p.pts
            return p
        }

        // If audio queue is empty, pump demuxer to find the next audio packet
        guard let ctx = formatCtx, audioStreamIndex >= 0 else { return nil }

        // Backpressure check: if videoQueue is already large, don't read endlessly ahead
        if videoQueue.count >= maxVideoQueueCount {
            return nil
        }

        var pkt = AVPacket()
        while av_read_frame(ctx, &pkt) >= 0 {
            if pkt.stream_index == audioStreamIndex {
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let isKey = (pkt.flags & AV_PKT_FLAG_KEY) != 0
                let audioPacket = DemuxedAudioPacket(
                    data: data,
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration,
                    isKeyFrame: isKey
                )
                self.lastAudioPts = pkt.pts
                av_packet_unref(&pkt)
                return audioPacket
            } else if pkt.stream_index == videoStreamIndex {
                // Symmetric buffering: preserve ALL video packets without dropping GOP frames!
                let data = Data(bytes: pkt.data, count: Int(pkt.size))
                let videoPacket = DemuxedVideoPacket(
                    data: data,
                    pts: pkt.pts,
                    dts: pkt.dts,
                    duration: pkt.duration,
                    flags: pkt.flags
                )
                videoQueue.append(videoPacket)
                av_packet_unref(&pkt)
            } else {
                av_packet_unref(&pkt)
            }
        }
        if videoQueue.isEmpty && audioQueue.isEmpty {
            self.isEOFInternal = true
        }
        return nil
    }

    public func seek(to seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = formatCtx else { return }
        audioQueue.removeAll()
        videoQueue.removeAll()
        lastAudioPts = -1
        isEOFInternal = false
        let target = Int64(seconds * Double(timebase.den) / Double(timebase.num))
        self.targetPts = target
        let ret = av_seek_frame(ctx, Int32(videoStreamIndex), target, AVSEEK_FLAG_BACKWARD)
        print("[MediaDemuxer] av_seek_frame to targetPts: \(target) (seconds: \(seconds)), ret: \(ret)")
    }

    public func cancel() {
        interruptContext.cancel()
    }

    deinit {
        if ownsInterruptContext {
            interruptContext.cancel()
        }
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
        let isAnnexB =
            (bytes[0] == 0 && bytes[1] == 0 && (bytes[2] == 1 || (count > 3 && bytes[2] == 0 && bytes[3] == 1)))

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
                let naluLen =
                    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3])
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

        let isAnnexB =
            (pktData[0] == 0 && pktData[1] == 0
                && (pktData[2] == 1 || (count > 3 && pktData[2] == 0 && pktData[3] == 1)))

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
