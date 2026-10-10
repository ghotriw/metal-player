import Foundation

/// Fast parser for Dolby Vision RPU payloads (NAL unit 62).
public enum DolbyVisionRPUParser {
    /// SMPTE ST 2084 PQ to Linear optical nits conversion.
    public static func pqToNits(_ pq: Float) -> Float {
        guard pq > 0.0 else { return 0.0 }
        let c1: Float = 0.8359375
        let c2: Float = 18.8515625
        let c3: Float = 18.6875
        let m1: Float = 0.1593017578125
        let m2: Float = 78.84375

        let p = pow(max(pq, 0.0), 1.0 / m2)
        let num = max(p - c1, 0.0)
        let den = max(c2 - c3 * p, 1e-6)
        let l = pow(num / den, 1.0 / m1)
        return l * 10000.0
    }

    private final class BitReader {
        private let data: [UInt8]
        private(set) var bitPos: Int = 0

        init(data: [UInt8]) {
            self.data = data
        }

        var isEOF: Bool {
            (bitPos >> 3) >= data.count
        }

        func getBits(_ n: Int) -> UInt32? {
            guard n > 0 else { return 0 }
            var res: UInt32 = 0
            for _ in 0..<n {
                let byteIdx = bitPos >> 3
                guard byteIdx < data.count else { return nil }
                let bitIdx = 7 - (bitPos & 7)
                let bit = UInt32((data[byteIdx] >> bitIdx) & 1)
                res = (res << 1) | bit
                bitPos += 1
            }
            return res
        }

        func getBits1() -> UInt32? {
            let byteIdx = bitPos >> 3
            guard byteIdx < data.count else { return nil }
            let bitIdx = 7 - (bitPos & 7)
            let bit = UInt32((data[byteIdx] >> bitIdx) & 1)
            bitPos += 1
            return bit
        }

        func getSBits(_ n: Int) -> Int32? {
            guard let v = getBits(n) else { return nil }
            if (v & (1 << (n - 1))) != 0 {
                return Int32(v) - (1 << n)
            }
            return Int32(v)
        }

        func getUE() -> UInt32? {
            var zeros = 0
            while zeros < 32 {
                guard let b = getBits1() else { return nil }
                if b != 0 { break }
                zeros += 1
            }
            if zeros == 0 { return 0 }
            if zeros >= 32 { return nil }
            guard let suffix = getBits(zeros) else { return nil }
            return (UInt32(1) << zeros) - 1 + suffix
        }

        func getSE() -> Int32? {
            guard let ue = getUE() else { return nil }
            if (ue & 1) != 0 {
                return Int32((ue + 1) >> 1)
            } else {
                return -Int32(ue >> 1)
            }
        }

        func align() {
            let rem = bitPos & 7
            if rem != 0 {
                bitPos += (8 - rem)
            }
        }
    }

    /// Unescapes 3-byte emulation prevention sequences (0x00, 0x00, 0x03 -> 0x00, 0x00).
    public static func unescapeRPU(from raw: Data) -> [UInt8] {
        var unescaped = [UInt8]()
        unescaped.reserveCapacity(raw.count)
        var i = 0
        raw.withUnsafeBytes { ptr in
            guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            while i < count {
                if i + 2 < count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 3 {
                    unescaped.append(0)
                    unescaped.append(0)
                    i += 3
                } else {
                    unescaped.append(bytes[i])
                    i += 1
                }
            }
        }
        return unescaped
    }

    /// Parses a raw NAL unit 62 (Dolby Vision RPU) and extracts L1 and L2 metadata.
    public static func parse(naluData: Data) -> DolbyVisionFrameMetadata? {
        guard naluData.count >= 6 else { return nil }
        let unescaped = unescapeRPU(from: naluData)
        guard unescaped.count >= 4 else { return nil }

        // Skip 2-byte NAL header if present (type 62 has nal_unit_type = 62)
        var payloadOffset = 0
        let firstNalType = (unescaped[0] >> 1) & 0x3F
        if firstNalType == 62 {
            payloadOffset = 2
        }

        guard payloadOffset < unescaped.count else { return nil }
        let payloadBytes: [UInt8]
        if unescaped[payloadOffset] == 25 {
            // NAL prefix byte 0x19 per SMPTE RPU spec
            payloadBytes = Array(unescaped[(payloadOffset + 1)...])
        } else {
            payloadBytes = Array(unescaped[payloadOffset...])
        }

        let br = BitReader(data: payloadBytes)
        guard let rpuType = br.getBits(6), rpuType == 2 else { return nil }

        guard let rpuFormat = br.getBits(11),
            br.getBits(4) != nil,  // vdr_rpu_profile
            br.getBits(4) != nil,  // vdr_rpu_level
            let vdrSeqInfoPresentBit = br.getBits1()
        else { return nil }
        let vdrSeqInfoPresent = vdrSeqInfoPresentBit != 0

        var coefDataType: UInt32 = 0
        var blBitDepth: Int = 10
        var disableResidual: UInt32 = 1

        if vdrSeqInfoPresent {
            guard br.getBits1() != nil,  // chroma_resampling_explicit_filter_flag
                let cdt = br.getBits(2),
                br.getUE() != nil,  // coef_log2_denom
                br.getBits(2) != nil,  // vdr_rpu_normalized_idc
                br.getBits1() != nil  // bl_video_full_range_flag
            else { return nil }
            coefDataType = cdt

            if (rpuFormat & 0x700) == 0 {
                guard let blMinus8 = br.getUE(),
                    br.getUE() != nil,  // elMinus8
                    br.getUE() != nil,  // vdrMinus8
                    br.getBits1() != nil,  // spatial_resampling_filter_flag
                    br.getBits(3) != nil,  // dm_compression
                    br.getBits1() != nil,  // el_spatial_resampling_filter_flag
                    let disRes = br.getBits1()
                else { return nil }
                blBitDepth = Int(blMinus8) + 8
                disableResidual = disRes
            } else {
                return nil
            }
        }

        // For Profile 7 with Enhancement Layer (EL), residual mapping is required.
        // We reject streams with disableResidual == 0 to prevent desynchronization.
        guard disableResidual == 1 else { return nil }

        guard let vdrDmMetadataPresentBit = br.getBits1(),
            let usePrevVdrRpuBit = br.getBits1()
        else { return nil }
        let vdrDmMetadataPresent = vdrDmMetadataPresentBit != 0
        let usePrevVdrRpu = usePrevVdrRpuBit != 0

        if !usePrevVdrRpu {
            guard br.getUE() != nil,  // vdr_rpu_id
                br.getUE() != nil,  // mapping_color_space
                br.getUE() != nil  // mapping_chroma_format_idc
            else { return nil }

            var curvesPivots = [Int]()
            for _ in 0..<3 {
                guard let numPivotsUE = br.getUE(), numPivotsUE <= 7 else { return nil }
                let numPivots = Int(numPivotsUE) + 2
                curvesPivots.append(numPivots)
                for _ in 0..<numPivots {
                    guard br.getBits(blBitDepth) != nil else { return nil }
                }
            }

            guard br.getUE() != nil,  // num_x_partitions
                br.getUE() != nil  // num_y_partitions
            else { return nil }

            func readSECoef() -> Bool {
                if coefDataType == 0 {
                    return br.getSE() != nil
                } else {
                    return br.getBits(32) != nil
                }
            }

            for c in 0..<3 {
                let numP = curvesPivots[c]
                for _ in 0..<(numP - 1) {
                    guard let mappingIdc = br.getUE() else { return nil }
                    if mappingIdc == 0 {
                        guard let polyOrderMinus1 = br.getUE(), polyOrderMinus1 <= 2 else { return nil }
                        if polyOrderMinus1 == 0 {
                            guard br.getBits1() != nil else { return nil }
                        }
                        for _ in 0..<(polyOrderMinus1 + 2) {
                            guard readSECoef() else { return nil }
                        }
                    } else if mappingIdc == 1 {
                        guard let mmrOrderMinus1 = br.getBits(2), mmrOrderMinus1 <= 2 else { return nil }
                        guard readSECoef() else { return nil }  // mmr_constant
                        for _ in 0..<(mmrOrderMinus1 + 1) {
                            for _ in 0..<7 {
                                guard readSECoef() else { return nil }
                            }
                        }
                    } else {
                        return nil
                    }
                }
            }
        } else {
            guard br.getUE() != nil else { return nil }  // prev_vdr_rpu_id
        }

        guard vdrDmMetadataPresent else { return nil }

        guard br.getUE() != nil,  // affected_dm_id
            br.getUE() != nil,  // current_dm_id
            let sceneRefreshUE = br.getUE()
        else { return nil }
        let sceneRefresh = sceneRefreshUE != 0

        // Skip color matrices
        for _ in 0..<9 { guard br.getBits(16) != nil else { return nil } }  // ycc_to_rgb_matrix
        for _ in 0..<3 { guard br.getBits(32) != nil else { return nil } }  // ycc_to_rgb_offset
        for _ in 0..<9 { guard br.getBits(16) != nil else { return nil } }  // rgb_to_lms_matrix

        guard br.getBits(16) != nil,  // signal_eotf
            br.getBits(16) != nil,  // signal_eotf_param0
            br.getBits(16) != nil,  // signal_eotf_param1
            br.getBits(32) != nil,  // signal_eotf_param2
            br.getBits(5) != nil,  // signal_bit_depth
            br.getBits(2) != nil,  // signal_color_space
            br.getBits(2) != nil,  // signal_chroma_format
            br.getBits(2) != nil,  // signal_full_range_flag
            br.getBits(12) != nil,  // source_min_pq
            br.getBits(12) != nil,  // source_max_pq
            br.getBits(10) != nil  // source_diagonal
        else { return nil }

        guard let numExtBlocksUE = br.getUE(), numExtBlocksUE <= 32 else { return nil }
        let numExtBlocks = Int(numExtBlocksUE)
        br.align()

        var l1: DolbyVisionFrameMetadata.Level1? = nil
        var l2Trims = [DolbyVisionFrameMetadata.Level2Trim]()

        for _ in 0..<numExtBlocks {
            guard let extLenUE = br.getUE(),
                let levelU32 = br.getBits(8)
            else { return nil }
            let extLen = Int(extLenUE)
            let level = Int(levelU32)
            let startBit = br.bitPos

            if level == 1 && extLen >= 5 {
                guard let minPQ = br.getBits(12),
                    let maxPQ = br.getBits(12),
                    let avgPQ = br.getBits(12)
                else { return nil }
                l1 = DolbyVisionFrameMetadata.Level1(
                    minPQ: UInt16(minPQ),
                    maxPQ: UInt16(maxPQ),
                    avgPQ: UInt16(avgPQ)
                )
            } else if level == 2 && extLen >= 11 {
                guard let targetMaxPQ = br.getBits(12),
                    let slope = br.getBits(12),
                    let offset = br.getBits(12),
                    let power = br.getBits(12),
                    let chromaWeight = br.getBits(12),
                    let satGain = br.getBits(12),
                    br.getSBits(13) != nil  // ms_weight
                else { return nil }
                let trim = DolbyVisionFrameMetadata.Level2Trim(
                    targetMaxPQ: UInt16(targetMaxPQ),
                    trimSlope: UInt16(slope),
                    trimOffset: UInt16(offset),
                    trimPower: UInt16(power),
                    trimChromaWeight: UInt16(chromaWeight),
                    trimSaturationGain: UInt16(satGain)
                )
                l2Trims.append(trim)
            }

            let bitsRead = br.bitPos - startBit
            let totalBits = extLen * 8
            if totalBits > bitsRead {
                guard br.getBits(totalBits - bitsRead) != nil else { return nil }
            }
        }

        return DolbyVisionFrameMetadata(sceneRefresh: sceneRefresh, l1: l1, l2Trims: l2Trims)
    }
}
