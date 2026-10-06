import Foundation
import Metal
import QuartzCore
import CoreVideo
import AppKit

public struct ToneMapUniforms: Sendable {
    public var targetNits: Float = 203.0                  // 203 nits standard ITU SDR reference
    public var sourcePeakNits: Float = 1000.0             // from SEI 144 / mastering display
    public var outputExposure: Float = 1.0
    public var outputSaturation: Float = 1.0
    public var outputWarmCorrection: Float = 0.0
    public var outputHighlightCompression: Float = 0.0
    public var outputShadowDetail: Float = 0.0
    public var outputShadowLift: Float = 0.0
    public var outputSharpness: Float = 0.5               // Default 0.5 for CAS sharpening on 5K display

    public init(
        targetNits: Float = 203.0,
        sourcePeakNits: Float = 1000.0,
        outputExposure: Float = 1.0,
        outputSaturation: Float = 1.0,
        outputWarmCorrection: Float = 0.0,
        outputHighlightCompression: Float = 0.0,
        outputShadowDetail: Float = 0.0,
        outputShadowLift: Float = 0.0,
        outputSharpness: Float = 0.5
    ) {
        self.targetNits = targetNits
        self.sourcePeakNits = sourcePeakNits
        self.outputExposure = outputExposure
        self.outputSaturation = outputSaturation
        self.outputWarmCorrection = outputWarmCorrection
        self.outputHighlightCompression = outputHighlightCompression
        self.outputShadowDetail = outputShadowDetail
        self.outputShadowLift = outputShadowLift
        self.outputSharpness = outputSharpness
    }
}

import os

public final class MetalVideoRenderer: @unchecked Sendable {
    public let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private let renderLock = NSLock()
    private let uniformsLock = OSAllocatedUnfairLock(initialState: ToneMapUniforms())

    public var uniforms: ToneMapUniforms {
        get { uniformsLock.withLock { $0 } }
        set { uniformsLock.withLock { $0 = newValue } }
    }

    public func updateUniforms(_ modify: @Sendable (inout ToneMapUniforms) -> Void) {
        uniformsLock.withLock { modify(&$0) }
    }

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        metalLayer.device = device
        metalLayer.pixelFormat = .bgr10a2Unorm
        metalLayer.framebufferOnly = true
        // Set colorspace to Display P3
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)

        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess {
            self.textureCache = cache
        }

        setupPipeline()
    }

    private func setupPipeline() {
        guard let defaultLibrary = try? device.makeDefaultLibrary(bundle: .module) ?? device.makeDefaultLibrary() else {
            print("[MetalVideoRenderer] Failed to load Metal default library")
            return
        }

        let vertexFn = defaultLibrary.makeFunction(name: "hdrVertexShader")
        let fragFn = defaultLibrary.makeFunction(name: "hdrToneMapFragmentShader")

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgr10a2Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            print("[MetalVideoRenderer] Pipeline state creation failed:", error)
        }
    }

    public func render(pixelBuffer: CVPixelBuffer) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let pipelineState,
              let textureCache,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Plane 0: Y channel (10-bit r16Unorm)
        var yTextureRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            width,
            height,
            0,
            &yTextureRef
        )

        // Plane 1: UV / CbCr channel (10-bit rg16Unorm, half width & height)
        var uvTextureRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            width / 2,
            height / 2,
            1,
            &uvTextureRef
        )

        guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
              let yTexture = CVMetalTextureGetTexture(yTextureRef!),
              let uvTexture = CVMetalTextureGetTexture(uvTextureRef!) else {
            return
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDesc.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)

        var currentUniforms = uniforms
        encoder.setFragmentBytes(&currentUniforms, length: MemoryLayout<ToneMapUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Retain CVMetalTexture references until GPU finishes processing
        let retainedTextures = (yTextureRef, uvTextureRef)
        commandBuffer.addCompletedHandler { _ in
            _ = retainedTextures
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
