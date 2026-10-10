import CoreMedia
import Foundation

public enum VideoCodec: String, Sendable {
    case hevc = "HEVC / H.265"
    case h264 = "AVC / H.264"
    case av1 = "AV1"
    case unknown = "Unknown"

    public var cmVideoCodecType: CMVideoCodecType {
        switch self {
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .h264:
            return kCMVideoCodecType_H264
        case .av1:
            return kCMVideoCodecType_AV1
        case .unknown:
            return kCMVideoCodecType_HEVC
        }
    }
}
