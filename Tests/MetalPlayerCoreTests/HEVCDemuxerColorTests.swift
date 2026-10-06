import Testing
import CoreMedia
import CoreVideo
@testable import MetalPlayerCore

@Suite("HEVCDemuxer Dynamic Color Metadata Tests")
struct HEVCDemuxerColorTests {
    @Test("Demuxer properly extracts dynamic color metadata from reference video if present")
    func testDemuxerMetadataExtraction() {
        let referencePath = "/Users/ghotriw/w_hdm_full.mkv"
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        guard let demuxer = HEVCDemuxer(url: referencePath) else {
            Issue.record("Failed to initialize HEVCDemuxer for reference file")
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

        let nalus = HEVCDemuxer.extractNALUnits(from: streamData)
        #expect(nalus.count == 3)
        #expect((nalus[0][0] >> 1) & 0x3F == 32)
        #expect((nalus[1][0] >> 1) & 0x3F == 33)
        #expect((nalus[2][0] >> 1) & 0x3F == 34)

        // Test conversion to HVCC format (4-byte big-endian length prefix)
        let (hvccData, count) = streamData.withUnsafeBytes { raw in
            HEVCDemuxer.packetDataToHVCC(pktData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: streamData.count)
        }
        #expect(count > 0)
        #expect(hvccData.count == count)

        // First NALU length should be 4 bytes (0x40, 0x01, 0x0C, 0x01 -> length 4)
        let vpsLen = (Int(hvccData[0]) << 24) | (Int(hvccData[1]) << 16) | (Int(hvccData[2]) << 8) | Int(hvccData[3])
        #expect(vpsLen == 4)
    }
}
