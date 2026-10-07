import Foundation
import Testing

@testable import MetalPlayerCore

@Suite("ToneMapUniforms & Renderer Concurrency Tests")
struct ToneMapUniformsTests {
    @Test("Default uniforms adhere to reference 203 nits ITU standard")
    func testDefaultUniforms() {
        let uniforms = ToneMapUniforms()
        #expect(uniforms.targetNits == 203.0)
        #expect(uniforms.outputSharpness == 0.5)
        #expect(uniforms.outputExposure == 1.0)
    }

    @Test("ToneMapUniforms mutation via MetalVideoRenderer is thread-safe")
    func testRendererUniformsThreadSafety() async {
        guard let renderer = MetalVideoRenderer() else { return }

        // Concurrently mutate uniforms across multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let sharpness = Float(i) / 100.0
                    renderer.updateUniforms { u in
                        u.outputSharpness = sharpness
                        u.outputExposure = 1.0 + Float(i) * 0.01
                    }
                    _ = renderer.uniforms.outputSharpness
                }
            }
        }

        #expect(renderer.uniforms.outputSharpness >= 0.0 && renderer.uniforms.outputSharpness <= 1.0)
    }
}
