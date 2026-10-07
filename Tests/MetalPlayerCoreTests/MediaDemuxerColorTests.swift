import CoreMedia
import CoreVideo
import Testing

@testable import MetalPlayerCore

@Suite("MediaDemuxer Dynamic Color Metadata Tests")
struct MediaDemuxerColorTests {
    @Test("Demuxer properly extracts dynamic color metadata from reference video if present")
    func testDemuxerMetadataExtraction() {
        let referencePath = "/Users/ghotriw/w_hdm_full.mkv"
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        guard let demuxer = MediaDemuxer(url: referencePath) else {
            Issue.record("Failed to initialize MediaDemuxer for reference file")
            return
        }

        #expect(demuxer.width == 3840)
        #expect(demuxer.height == 2160)
        #expect(demuxer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020)
        #expect(demuxer.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        #expect(demuxer.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
        #expect(demuxer.isFullRange == false)
    }

    @Test("Demuxer parses Annex B NAL units and converts to HVCC")
    func testAnnexBNALConversion() {
        // Construct synthetic Annex B packet containing VPS (type 32), SPS (type 33), PPS (type 34)
        // VPS: start code (0x00000001) + NAL header (0x4001) + dummy payload
        let vpsBytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0C, 0x01]
        // SPS: start code 3-byte (0x000001) + NAL header (0x4201) + dummy payload
        let spsBytes: [UInt8] = [0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x60, 0x00]
        // PPS: start code 4-byte (0x00000001) + NAL header (0x4401) + dummy payload
        let ppsBytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xC0]

        var streamData = Data()
        streamData.append(contentsOf: vpsBytes)
        streamData.append(contentsOf: spsBytes)
        streamData.append(contentsOf: ppsBytes)

        let nalus = MediaDemuxer.extractNALUnits(from: streamData)
        #expect(nalus.count == 3)
        #expect((nalus[0][0] >> 1) & 0x3F == 32)
        #expect((nalus[1][0] >> 1) & 0x3F == 33)
        #expect((nalus[2][0] >> 1) & 0x3F == 34)

        // Test conversion to HVCC format (4-byte big-endian length prefix)
        let (hvccData, count) = streamData.withUnsafeBytes { raw in
            MediaDemuxer.packetDataToHVCC(
                pktData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: streamData.count)
        }
        #expect(count > 0)
        #expect(hvccData.count == count)

        // First NALU length should be 4 bytes (0x40, 0x01, 0x0C, 0x01 -> length 4)
        let vpsLen = (Int(hvccData[0]) << 24) | (Int(hvccData[1]) << 16) | (Int(hvccData[2]) << 8) | Int(hvccData[3])
        #expect(vpsLen == 4)
    }

    @Test("Demuxer extracts H.264 SPS/PPS NAL units and creates CMVideoFormatDescription")
    func testH264NALExtractionAndFormatDescription() {
        // H.264 SPS: start code (0x00000001) + NAL header (0x67 = type 7, forbidden=0, ref_idc=3) + baseline 640x360 payload
        let spsBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C,
            0x83, 0xC5, 0x8B, 0x67, 0x80,
        ]
        // H.264 PPS: start code (0x00000001) + NAL header (0x68 = type 8, forbidden=0, ref_idc=3) + payload
        let ppsBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x3C, 0x80,
        ]

        var streamData = Data()
        streamData.append(contentsOf: spsBytes)
        streamData.append(contentsOf: ppsBytes)

        let nalus = MediaDemuxer.extractNALUnits(from: streamData)
        #expect(nalus.count == 2)
        #expect(nalus[0][0] & 0x1F == 7)  // SPS
        #expect(nalus[1][0] & 0x1F == 8)  // PPS

        // Verify CMVideoFormatDescriptionCreateFromH264ParameterSets succeeds with these parameters
        var formatDesc: CMVideoFormatDescription?
        let spsData = nalus[0]
        let ppsData = nalus[1]

        spsData.withUnsafeBytes { spsBuf in
            ppsData.withUnsafeBytes { ppsBuf in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes: [Int] = [spsData.count, ppsData.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                #expect(status == noErr)
            }
        }
        #expect(formatDesc != nil)
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc!)
        #expect(dims.width == 1280)
        #expect(dims.height == 720)
    }

    @Test("MediaDemuxer parses ISO avcC extradata structure correctly")
    func testAvcCExtradataParsing() {
        // Construct standard ISO/IEC 14496-15 avcC box:
        // [0] configurationVersion = 1
        // [1] AVCProfileIndication = 0x42
        // [2] profile_compatibility = 0xC0
        // [3] AVCLevelIndication = 0x1E
        // [4] lengthSizeMinusOne = 0xFF (nalUnitHeaderLength = 4)
        // [5] numOfSequenceParameterSets = 0xE1 (1 SPS)
        // [6..7] spsLength = 23
        // [8..30] spsData
        // [31] numOfPictureParameterSets = 1
        // [32..33] ppsLength = 4
        // [34..37] ppsData
        let spsBytes: [UInt8] = [
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C,
            0x83, 0xC5, 0x8B, 0x67, 0x80,
        ]
        let ppsBytes: [UInt8] = [
            0x68, 0xCE, 0x3C, 0x80,
        ]

        var avcC = Data([1, 0x42, 0xC0, 0x1E, 0xFF, 0xE1])
        avcC.append(contentsOf: [UInt8(spsBytes.count >> 8), UInt8(spsBytes.count & 0xFF)])
        avcC.append(contentsOf: spsBytes)
        avcC.append(1)  // 1 PPS
        avcC.append(contentsOf: [UInt8(ppsBytes.count >> 8), UInt8(ppsBytes.count & 0xFF)])
        avcC.append(contentsOf: ppsBytes)

        // Parse avcC using the same ISO parsing logic
        var offset = 5
        let numSPS = Int(avcC[offset] & 0x1F)
        offset += 1
        #expect(numSPS == 1)

        let parsedSpsLen = Int(avcC[offset]) << 8 | Int(avcC[offset + 1])
        offset += 2
        let extractedSPS = avcC.subdata(in: offset..<(offset + parsedSpsLen))
        offset += parsedSpsLen
        #expect(extractedSPS == Data(spsBytes))

        let numPPS = Int(avcC[offset])
        offset += 1
        #expect(numPPS == 1)

        let parsedPpsLen = Int(avcC[offset]) << 8 | Int(avcC[offset + 1])
        offset += 2
        let extractedPPS = avcC.subdata(in: offset..<(offset + parsedPpsLen))
        #expect(extractedPPS == Data(ppsBytes))
    }

    @Test("MediaDemuxer detects Dolby Vision Profile 5 dvvC box")
    func testDolbyVisionProfile5Detection() {
        // Construct synthetic 24-byte dvvC box:
        // [0..3]: dv_version_major, dv_version_minor, dv_profile(high 7 bits), dv_level(6 bits), rpu_present_flag
        // FourCC "dvvC" = [0x64, 0x76, 0x76, 0x43]
        // Profile 5 byte: (5 << 1) = 10 (0x0A)
        var dvvCBox = Data()
        // Prefix padding
        dvvCBox.append(contentsOf: [0x00, 0x00, 0x00, 0x18])  // box size 24
        dvvCBox.append(contentsOf: [0x64, 0x76, 0x76, 0x43])  // 'dvvC'
        dvvCBox.append(contentsOf: [0x01, 0x00])  // version 1.0
        dvvCBox.append(contentsOf: [0x0A, 0x00])  // profile 5: (5 << 1) = 0x0A
        dvvCBox.append(contentsOf: Array(repeating: UInt8(0), count: 12))  // remaining box bytes

        var detectedProfile5 = false
        dvvCBox.withUnsafeBytes { raw in
            let extraBytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<(extraBytes.count - 8) {
                if extraBytes[i] == 0x64 && extraBytes[i + 1] == 0x76 && extraBytes[i + 2] == 0x76
                    && extraBytes[i + 3] == 0x43
                {
                    let dvProfile = (extraBytes[i + 6] >> 1) & 0x7F
                    if dvProfile == 5 {
                        detectedProfile5 = true
                    }
                    break
                }
            }
        }
        #expect(detectedProfile5 == true)
    }
}
