import Foundation
import CoreMedia
import AudioToolbox
import CFFmpeg
import os

/// Decodes audio packets using FFmpeg libavcodec and resamples via libswresample
/// to 48kHz Multi-channel (5.1 / 7.1) or Stereo Float32 Linear PCM wrapped in CoreMedia CMSampleBuffers
/// with explicit AudioChannelLayout for Apple Spatial Audio and Dynamic Head Tracking.
public final class FFAudioDecoder: @unchecked Sendable {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var audioFormatDescription: CMAudioFormatDescription?

    public let targetSampleRate: Int32 = 48000
    public let targetChannels: Int32
    public let channelLayoutTag: AudioChannelLayoutTag

    private let lock = NSLock()

    public init?(codecParameters: UnsafePointer<AVCodecParameters>, timebase: AVRational) {
        let codecId = codecParameters.pointee.codec_id
        guard let codec = avcodec_find_decoder(codecId) else {
            print("[FFAudioDecoder] Codec not found for id: \(codecId.rawValue)")
            return nil
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            print("[FFAudioDecoder] Failed to allocate AVCodecContext")
            return nil
        }
        self.codecCtx = ctx

        if avcodec_parameters_to_context(ctx, codecParameters) < 0 {
            print("[FFAudioDecoder] Failed to copy codec parameters to context")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        ctx.pointee.pkt_timebase = timebase

        if avcodec_open2(ctx, codec, nil) < 0 {
            print("[FFAudioDecoder] Failed to open codec")
            avcodec_free_context(&self.codecCtx)
            return nil
        }

        // Determine channel count and layout for Spatial Audio:
        // - 8 channels: 7.1 Surround (L, R, C, LFE, Ls, Rs, Rls, Rrs)
        // - 6 channels: 5.1 Surround (L, R, C, LFE, Ls, Rs)
        // - <= 2 channels: Stereo (L, R) or downmixed from non-standard (3.0, 4.0, 5.0)
        let srcChannels = ctx.pointee.ch_layout.nb_channels
        if srcChannels >= 8 {
            self.targetChannels = 8
            self.channelLayoutTag = kAudioChannelLayoutTag_AudioUnit_7_1 // L R C LFE Ls Rs Rls Rrs
        } else if srcChannels >= 6 {
            self.targetChannels = 6
            self.channelLayoutTag = kAudioChannelLayoutTag_AudioUnit_5_1 // L R C LFE Ls Rs (SMPTE standard)
        } else {
            self.targetChannels = 2
            self.channelLayoutTag = kAudioChannelLayoutTag_Stereo
        }

        self.frame = av_frame_alloc()
        self.packet = av_packet_alloc()

        guard frame != nil && packet != nil else {
            teardown()
            return nil
        }

        setupFormatDescription()
    }

    private func setupFormatDescription() {
        // Standard macOS CoreAudio PCM format: 48kHz, Float32 Linear PCM.
        // For Spatial Audio, CoreAudio requires an explicit AudioChannelLayout
        // matching the multi-channel arrangement (5.1 or 7.1).
        let bytesPerFrame = UInt32(targetChannels * 4) // 4 bytes per Float32
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(targetSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(targetChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = channelLayoutTag
        channelLayout.mChannelBitmap = []
        channelLayout.mNumberChannelDescriptions = 0

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &channelLayout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        if status == noErr {
            self.audioFormatDescription = formatDesc
            print("[FFAudioDecoder] Created CMAudioFormatDescription: \(targetChannels)ch @ 48kHz, tag: \(channelLayoutTag)")
        } else {
            print("[FFAudioDecoder] Failed to create CMAudioFormatDescription: \(status)")
        }
    }

    private func initSwrIfNeeded(srcFrame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if swrCtx != nil { return true }

        var inChLayout = srcFrame.pointee.ch_layout
        var outChLayout = AVChannelLayout()
        av_channel_layout_default(&outChLayout, targetChannels)

        var newSwr: OpaquePointer? = nil
        let ret = swr_alloc_set_opts2(
            &newSwr,
            &outChLayout,
            AV_SAMPLE_FMT_FLT, // Interleaved Float32
            targetSampleRate,
            &inChLayout,
            AVSampleFormat(rawValue: srcFrame.pointee.format),
            srcFrame.pointee.sample_rate,
            0,
            nil
        )

        guard ret == 0, let validSwr = newSwr else {
            print("[FFAudioDecoder] swr_alloc_set_opts2 failed: \(ret)")
            return false
        }

        if swr_init(validSwr) < 0 {
            print("[FFAudioDecoder] swr_init failed")
            swr_free(&newSwr)
            return false
        }

        self.swrCtx = validSwr
        return true
    }

    /// Decodes a demuxed audio packet and returns one or more CMSampleBuffers containing Linear PCM
    public func decode(packetData: Data, pts: Int64, timebase: AVRational) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = codecCtx, let avFrame = frame, let avPkt = packet, let formatDesc = audioFormatDescription else {
            return []
        }

        av_packet_unref(avPkt)
        let count = packetData.count
        guard let mem = malloc(count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { return [] }
        _ = packetData.withUnsafeBytes { raw in
            memcpy(mem, raw.baseAddress!, count)
        }
        memset(mem.advanced(by: count), 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))

        avPkt.pointee.data = mem.assumingMemoryBound(to: UInt8.self)
        avPkt.pointee.size = Int32(count)
        avPkt.pointee.pts = pts
        avPkt.pointee.dts = pts

        defer {
            free(mem)
            av_packet_unref(avPkt)
        }

        if avcodec_send_packet(ctx, avPkt) < 0 {
            return []
        }

        var sampleBuffers: [CMSampleBuffer] = []

        while avcodec_receive_frame(ctx, avFrame) == 0 {
            defer { av_frame_unref(avFrame) }

            guard initSwrIfNeeded(srcFrame: avFrame), let swr = swrCtx else {
                continue
            }

            // Estimate out sample count
            let maxOutSamples = swr_get_out_samples(swr, avFrame.pointee.nb_samples)
            let outBufferSize = Int(maxOutSamples * targetChannels * 4) // 4 bytes per float
            guard let outData = malloc(outBufferSize) else { continue }

            var outPtr: UnsafeMutablePointer<UInt8>? = outData.assumingMemoryBound(to: UInt8.self)
            var inDataPointers: [UnsafePointer<UInt8>?] = []
            withUnsafePointer(to: &avFrame.pointee.data) { dataArrayPtr in
                let tuplePtr = UnsafeRawPointer(dataArrayPtr).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                for i in 0..<8 {
                    if let ptr = tuplePtr[i] {
                        inDataPointers.append(UnsafePointer(ptr))
                    }
                }
            }

            let convertedSamples = inDataPointers.withUnsafeBufferPointer { inBufPtr -> Int32 in
                guard let base = inBufPtr.baseAddress else { return 0 }
                return swr_convert(
                    swr,
                    &outPtr,
                    maxOutSamples,
                    base,
                    avFrame.pointee.nb_samples
                )
            }

            guard convertedSamples > 0 else {
                free(outData)
                continue
            }

            let actualByteLength = Int(convertedSamples * targetChannels * 4)

            // Wrap in CMBlockBuffer
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: outData,
                blockLength: actualByteLength,
                blockAllocator: kCFAllocatorMalloc,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: actualByteLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard blockStatus == kCMBlockBufferNoErr, let validBlockBuffer = blockBuffer else {
                free(outData)
                continue
            }

            // Presentation timestamp
            let framePts = avFrame.pointee.pts
            let ptsSeconds: Double
            if framePts != Int64.min && timebase.den > 0 {
                ptsSeconds = Double(framePts) * Double(timebase.num) / Double(timebase.den)
            } else {
                ptsSeconds = 0
            }
            let cmPts = CMTime(seconds: ptsSeconds, preferredTimescale: targetSampleRate)
            let cmDuration = CMTime(value: CMTimeValue(convertedSamples), timescale: targetSampleRate)

            var timing = CMSampleTimingInfo(
                duration: cmDuration,
                presentationTimeStamp: cmPts,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: validBlockBuffer,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(convertedSamples),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )

            if status == noErr, let sb = sampleBuffer {
                sampleBuffers.append(sb)
            }
        }

        return sampleBuffers
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        if let ctx = codecCtx {
            avcodec_flush_buffers(ctx)
        }
        if let swr = swrCtx {
            swr_init(swr)
        }
    }

    private func teardown() {
        if let swr = swrCtx {
            var p: OpaquePointer? = swr
            swr_free(&p)
            self.swrCtx = nil
        }
        if frame != nil {
            av_frame_free(&frame)
        }
        if packet != nil {
            av_packet_free(&packet)
        }
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
    }

    deinit {
        teardown()
    }
}
