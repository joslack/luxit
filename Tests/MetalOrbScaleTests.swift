import AppKit
import Metal
import MetalKit

enum DiagnosticLog {
    static func write(_ message: String) { print(message) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum MetalOrbScaleTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is required to check rendered particle sizes")
        }
        let library = try device.makeLibrary(source: MetalOrbRenderer.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "voiceOrbVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "voiceOrbFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        // One static, centered particle isolates size from voice, motion, and
        // display brightness. These are the production vertex/fragment shaders.
        let point: [Float] = [0, 0, 8, 1, 0, 0, .pi, 0]
        var values = [Float](repeating: 0, count: 30)
        values[0] = 64
        values[1] = 64
        values[9] = 1
        for index in 13...18 { values[index] = 1 }
        values[20] = 1
        values[21] = 1
        values[28] = 1

        func diameter(pixels: Int, uniforms: [Float]) throws -> Double {
            let textureDescription = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: pixels, height: pixels, mipmapped: false)
            textureDescription.usage = .renderTarget
            textureDescription.storageMode = .shared
            let texture = device.makeTexture(descriptor: textureDescription)!
            let particles = device.makeBuffer(bytes: point, length: point.count * 4)!
            let interaction = device.makeBuffer(length: 8 * 4)!
            memset(interaction.contents(), 0, interaction.length)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(particles, offset: 0, index: 0)
            encoder.setVertexBuffer(interaction, offset: 0, index: 2)
            uniforms.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            expect(command.status == .completed, "The scale-check frame must render successfully")
            var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: pixels * 4,
                                 from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
            }
            var left = pixels
            var right = -1
            for y in 0..<pixels {
                for x in 0..<pixels where bytes[(y * pixels + x) * 4 + 3] > 25 {
                    left = min(left, x)
                    right = max(right, x)
                }
            }
            expect(right >= left, "The rendered particle must be visible")
            return Double(right - left + 1) / (Double(pixels) / Double(values[0]))
        }

        let reference = try diameter(pixels: 64, uniforms: values)
        for (pixels, staleScale): (Int, Float) in [(64, 2), (128, 1), (32, 2), (96, 1), (192, 2)] {
            var queued = values
            queued[20] = staleScale
            let resolved = MetalOrbRenderer.uniformsForDrawable(queued, pixelWidth: pixels)
            expect(queued[20] == staleScale, "Resolving a render target does not mutate another queued frame")
            expect(resolved.enumerated().allSatisfy { $0.offset == 20 || $0.element == queued[$0.offset] },
                   "Display scaling preserves geometry, animation, pointer, and color uniforms")
            let measured = try diameter(pixels: pixels, uniforms: resolved)
            // The threshold edge is quantized to whole texture pixels; a
            // half-resolution pixel spans two logical points.
            let pixelTolerance = max(1, 64.0 / Double(pixels))
            expect(abs(measured - reference) <= pixelTolerance,
                   "A \(pixels)-pixel target with stale \(staleScale)x metadata keeps the same logical particle diameter (\(measured) vs \(reference))")
        }
        var stale = values
        stale[20] = 2
        let oversized = try diameter(pixels: 64, uniforms: stale)
        expect(oversized > reference * 1.8,
               "The regression fixture reproduces oversized dots when scale metadata is stale")
        print("MetalOrbScaleTests passed (actual GPU pixels at 0.5x, 1x, 1.5x, 2x, 3x; stale-scale regression)")
        print("Particle diameter: reference \(reference) pt; stale-scale reproduction \(oversized) pt")
    }
}
