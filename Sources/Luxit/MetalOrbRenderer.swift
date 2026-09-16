import AppKit
import Metal
import MetalKit
import QuartzCore

final class MetalOrbRenderer {
    private let renderQueue = DispatchQueue(label: "com.joslack.luxit.orb-render", qos: .userInteractive)
    private let frameGate = DispatchSemaphore(value: 2)
    private let resultLock = NSLock()
    private var unavailableFrames = 0
    var consecutiveUnavailableFrames: Int {
        resultLock.lock()
        defer { resultLock.unlock() }
        return unavailableFrames
    }
    private let metalLayer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private weak var view: MTKView?
    private var particleBuffers: [MTLBuffer?] = [nil, nil]
    private var bufferIndex = 0
    private var particleValues: [Float] = []
    private var particleCount = 0
    // GPU-only state survives frames; tracked resources on one command queue
    // serialize access. Each point vertex owns exactly two float4 elements.
    private var interactionBuffer: MTLBuffer?
    private var lastFrameUptime = ProcessInfo.processInfo.systemUptime
    private var uniformValues = [Float](repeating: 0, count: 30)
    private var lastSpectrum: [CGFloat] = []
    private var lastLevel: CGFloat = -1

    init?(view: MTKView) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        guard let metalLayer = view.layer as? CAMetalLayer else { return nil }
        self.metalLayer = metalLayer
        self.device = device
        self.commandQueue = commandQueue
        view.device = device
        view.colorPixelFormat = .bgra10_xr_srgb
        view.colorspace = CGColorSpace(
            name: CGColorSpace.extendedSRGB
        )
        view.clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.layer?.isOpaque = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.colorspace = view.colorspace
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.preferredDynamicRange = .constrainedHigh
            metalLayer.contentsHeadroom =
                VoiceOrbMotion.maximumParticleEDRGain
            metalLayer.edrMetadata = nil
            metalLayer.maximumDrawableCount = 3
            metalLayer.presentsWithTransaction = false
        }

        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard
                let vertex = library.makeFunction(name: "voiceOrbVertex"),
                let fragment = library.makeFunction(name: "voiceOrbFragment")
            else {
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor =
                .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor =
                .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(
                descriptor: descriptor
            )
        } catch {
            DiagnosticLog.write(
                "Metal orb pipeline unavailable: \(error.localizedDescription)"
            )
            return nil
        }

        self.view = view
        DiagnosticLog.write("Metal orb renderer initialized")
    }

    func update(
        spectrum: [CGFloat],
        level: CGFloat,
        orbMotionPhase: CGFloat,
        animationPhase: CGFloat,
        pulse: CGFloat,
        processingProgress: CGFloat,
        completion: CGFloat,
        appearance: CGFloat,
        pointer: NSPoint?,
        accent: NSColor,
        highlight: NSColor,
        bounds: NSRect
    ) {
        guard bounds.width > 0, bounds.height > 0,
              view?.window?.isVisible == true,
              frameGate.wait(timeout: .now()) == .success else { return }
        let processing = max(0, min(1, processingProgress))
        let processingBlend =
            VoiceOrbMotion.processingGeometryBlend(processing)
        let voice = pow(max(0, min(1, level)), 0.72)
        let displayLevel = max(
            VoiceOrbMotion.idleVisualFloor,
            max(
                voice,
                VoiceOrbMotion.processingLevelFloor * processingBlend
            )
        )
        let normalizedSpectrum = spectrum

        let progress = max(0, min(1, completion))
        let completionAlpha =
            VoiceOrbMotion.visibilityAlpha(1 - progress)
        let processingScale =
            VoiceOrbMotion.processingBreathScale(pulse)
        let baseRadius = (
            VoiceOrbMotion.baseRadius +
            displayLevel * VoiceOrbMotion.voiceRadiusGrowth
        ) *
            (1 + (processingScale - 1) * processingBlend)
        let rotation = animationPhase * 0.11
        let accentComponents = Self.components(of: accent)
        let highlightComponents = Self.components(of: highlight)
        let backingScale = CGFloat(
            (view?.drawableSize.width ?? bounds.width) / bounds.width
        )

        uniformValues[0] = Float(bounds.width)
        uniformValues[1] = Float(bounds.height)
        uniformValues[2] = Float(baseRadius)
        uniformValues[3] = Float(rotation)
        uniformValues[4] = Float(orbMotionPhase)
        uniformValues[5] = Float(animationPhase)
        uniformValues[6] = Float(displayLevel)
        uniformValues[7] = Float(processing)
        uniformValues[8] = Float(progress)
        uniformValues[9] = Float(completionAlpha)
        uniformValues[10] = Float(pointer?.x ?? -10_000)
        uniformValues[11] = Float(pointer?.y ?? -10_000)
        uniformValues[12] = pointer == nil ? 0 : 1
        uniformValues[13] = Float(accentComponents.red)
        uniformValues[14] = Float(accentComponents.green)
        uniformValues[15] = Float(accentComponents.blue)
        uniformValues[16] = Float(highlightComponents.red)
        uniformValues[17] = Float(highlightComponents.green)
        uniformValues[18] = Float(highlightComponents.blue)
        uniformValues[19] = Float(pulse)
        uniformValues[20] = Float(max(1, backingScale))
        uniformValues[21] = Float(max(0, min(1, appearance)))
        uniformValues[22] = Float(VoiceOrbMotion.currentScale)
        uniformValues[23] = Float(VoiceOrbMotion.particleJitterScale(level: level))
        uniformValues[24] = Float(VoiceOrbMotion.spatialScale)
        uniformValues[25] = Float(VoiceOrbMotion.attractorScale)
        uniformValues[26] = Float(VoiceOrbMotion.voiceResponseScale)
        uniformValues[27] = Float(
            VoiceOrbMotion.materializationFieldRadius(
                baseRadius: baseRadius,
                panelExtent: min(bounds.width, bounds.height)
            )
        )
        let availableHeadroom =
            view?.window?.screen?
                .maximumExtendedDynamicRangeColorComponentValue ?? 1
        let edrGain = VoiceOrbMotion.particleEDRGain(
            availableHeadroom: availableHeadroom
        )
        uniformValues[28] = Float(edrGain)
        let now = ProcessInfo.processInfo.systemUptime
        uniformValues[29] = Float(VoiceOrbMotion.frameElapsed(since: lastFrameUptime, now: now))
        lastFrameUptime = now
        let uniforms = uniformValues
        // nextDrawable may wait for WindowServer. Never do that on AppKit's
        // event thread. Two independent buffers let a new frame be prepared
        // while the previous presentation completes, without growing a queue.
        renderQueue.async { [self] in
            autoreleasepool {
                if normalizedSpectrum != lastSpectrum || displayLevel != lastLevel {
                    rebuildParticles(spectrum: normalizedSpectrum, level: displayLevel)
                    lastSpectrum = normalizedSpectrum
                    lastLevel = displayLevel
                }
                render(uniforms: uniforms)
            }
        }
    }

    private func rebuildParticles(spectrum: [CGFloat], level: CGFloat) {
        let points = VoiceOrbGeometry.points(
            spectrum: spectrum,
            level: level
        )
        var values: [Float] = []
        values.reserveCapacity(points.count * 8)
        for point in points {
            values.append(Float(point.x))
            values.append(Float(point.y))
            values.append(Float(point.radius))
            values.append(Float(point.intensity))
            values.append(Float(point.velocity))
            values.append(Float(point.flowPhase))
            values.append(Float(point.flowPhaseY))
            values.append(Float(point.driftScale))
        }
        particleCount = points.count
        particleValues = values
    }

    private func render(uniforms: [Float]) {
        let index = bufferIndex
        let byteCount = particleValues.count * MemoryLayout<Float>.stride
        if particleBuffers[index] == nil || particleBuffers[index]!.length < byteCount {
            particleBuffers[index] = device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        if interactionBuffer == nil || interactionBuffer!.length != byteCount {
            interactionBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            if let interactionBuffer { memset(interactionBuffer.contents(), 0, byteCount) }
        }
        guard particleCount > 0, let particleBuffer = particleBuffers[index], let interactionBuffer,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            finishFrame(succeeded: false)
            return
        }
        // The command queue completes in order and the two-slot frame gate
        // protects each buffer until its previous GPU use has completed.
        particleValues.withUnsafeBytes { bytes in
            particleBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            finishFrame(succeeded: false)
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(interactionBuffer, offset: 0, index: 2)
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [self] command in
            finishFrame(succeeded: command.status == .completed)
        }
        // Failed drawable/encoder acquisition must reuse this unused slot.
        // Advancing on failure could wrap around to a buffer still on the GPU.
        bufferIndex = (bufferIndex + 1) % particleBuffers.count
        commandBuffer.commit()
    }

    private func finishFrame(succeeded: Bool) {
        resultLock.lock()
        unavailableFrames = succeeded ? 0 : unavailableFrames + 1
        resultLock.unlock()
        frameGate.signal()
    }

    private static func components(
        of color: NSColor
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let converted =
            color.usingColorSpace(Self.rendererColorSpace) ??
            color.usingColorSpace(.deviceRGB) ??
            color
        return (
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent
        )
    }

    private static let rendererColorSpace: NSColorSpace = {
        guard
            let colorSpace = CGColorSpace(
                name: CGColorSpace.extendedSRGB
            ),
            let converted = NSColorSpace(cgColorSpace: colorSpace)
        else {
            return .deviceRGB
        }
        return converted
    }()

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct OrbVertexOut {
        float4 position [[position]];
        float pointSize [[point_size]];
        float3 color;
        float2 moteAxis;
        float moteAspect;
        float alpha;
        float edrHeadroom;
    };

    float hashValue(uint value) {
        value ^= value >> 16;
        value *= 0x7feb352d;
        value ^= value >> 15;
        value *= 0x846ca68b;
        value ^= value >> 16;
        return float(value & 0x00ffffff) / float(0x00ffffff);
    }

    float motionNoise(uint point, float time, uint channel) {
        float lowerStep = floor(time);
        float fraction = time - lowerStep;
        float eased = fraction * fraction * (3.0 - 2.0 * fraction);
        uint base = point * 0x9e3779b9u + channel * 0x85ebca6bu;
        float lower = hashValue(base ^ uint(int(lowerStep)));
        float upper = hashValue(base ^ uint(int(lowerStep) + 1));
        return mix(lower, upper, eased) * 2.0 - 1.0;
    }

    vertex OrbVertexOut voiceOrbVertex(
        uint vertexID [[vertex_id]],
        device const float *particles [[buffer(0)]],
        constant float *u [[buffer(1)]],
        device float4 *interaction [[buffer(2)]]
    ) {
        uint offset = vertexID * 8;
        float2 base = float2(particles[offset], particles[offset + 1]);
        float radius = particles[offset + 2];
        float intensity = particles[offset + 3];
        float velocity = particles[offset + 4];
        float flowPhaseX = particles[offset + 5];
        float flowPhaseY = particles[offset + 6];
        float driftScale = particles[offset + 7];
        float rotation = u[3];
        float cosine = cos(rotation);
        float sine = sin(rotation);
        float2 rotated = float2(
            base.x * cosine - base.y * sine,
            base.x * sine + base.y * cosine
        );
        float appearance = clamp(u[21], 0.0, 1.0);
        float appearanceCondensation =
            appearance * appearance * (3.0 - 2.0 * appearance);
        float completion = clamp(u[8], 0.0, 1.0);
        float dispersal =
            completion * completion * (3.0 - 2.0 * completion);
        float condensation = appearanceCondensation * (1.0 - dispersal);
        float particleTimeX = u[5] * velocity + flowPhaseX;
        float particleTimeY =
            u[5] * (0.55 + velocity * 1.17) + flowPhaseY;
        float jitterAmount =
            (0.55 + u[6] * 4.20 * u[26]) *
            (0.42 + intensity * 0.58) *
            driftScale *
            u[23];
        float flowAmount =
            (2.20 + u[6] * intensity * 4.80 * u[26]) *
            driftScale *
            u[22];
        float spatialScale = u[24];
        float2 flow = float2(
            sin(particleTimeX * 1.35 + rotated.y * 5.2 * spatialScale) +
                cos(
                    particleTimeY * 0.73 -
                    rotated.x * 4.0 * spatialScale
                ) * 0.55,
            cos(particleTimeY * 1.21 + rotated.x * 5.0 * spatialScale) +
                sin(
                    particleTimeX * 0.67 +
                    rotated.y * 3.8 * spatialScale
                ) * 0.50
        ) * flowAmount;
        float2 attractor = float2(
            sin(rotated.y * 1.7 + particleTimeX) +
                cos(rotated.x * -1.3 - particleTimeY) * 0.55,
            sin(rotated.x * -1.9 + particleTimeY) +
                cos(rotated.y * 1.5 + particleTimeX) * 0.55
        ) * (
            2.6 + u[6] * 8.5 * u[26]
        ) * driftScale * u[25];
        flow += attractor;
        float noiseTimeX = u[4] * velocity + flowPhaseX * 0.16;
        float noiseTimeY =
            u[4] * (0.48 + velocity * 1.31) + flowPhaseY * 0.16;
        float2 jitter = float2(
            motionNoise(vertexID, noiseTimeX, 0),
            motionNoise(vertexID, noiseTimeY, 1)
        ) * jitterAmount;
        float radialDistance = length(base);
        float waveFront = clamp(u[7], 0.0, 1.0) * 1.35;
        float rippleDistance = radialDistance - waveFront;
        float rippleEntrance = smoothstep(
            0.0,
            0.12,
            clamp(u[7], 0.0, 1.0)
        );
        float rippleOffset =
            exp(-(rippleDistance * rippleDistance) * 38.0) *
            9.0 *
            rippleEntrance *
            (1.0 - completion);
        float2 settled = rotated * u[2] + flow + jitter;
        float2 radialDirection = radialDistance > 0.0001
            ? rotated / radialDistance
            : float2(0.0);
        settled += radialDirection * rippleOffset;
        float radialSeed = clamp(
            flowPhaseY / (2.0 * M_PI_F),
            0.0,
            1.0
        );
        float spawnRadius = u[27] * sqrt(radialSeed);
        float2 spawn = float2(
            cos(flowPhaseX),
            sin(flowPhaseX)
        ) * spawnRadius;
        float2 position =
            float2(u[0] * 0.5, u[1] * 0.5) +
            mix(spawn, settled, condensation);

        float4 motion = interaction[vertexID * 2];
        float dissipation = interaction[vertexID * 2 + 1].x;
        if (appearance < 0.01) { motion = float4(0.0); dissipation = 0.0; }
        float influence = 0.0;
        float2 force = float2(0.0);
        if (u[12] > 0.5) {
            float2 delta = position - float2(u[10], u[11]);
            float distance = length(delta);
            influence = 1.0 - smoothstep(\(VoiceOrbDissolution.innerRadius), \(VoiceOrbDissolution.outerRadius), distance);
            float2 direction = distance > 0.001 ? delta / distance : float2(cos(flowPhaseX), sin(flowPhaseX));
            float2 tangent = float2(-direction.y, direction.x);
            force = (direction * \(VoiceOrbDissolution.radialForce) +
                tangent * (\(VoiceOrbDissolution.tangentialForce) * sin(flowPhaseX))) * influence;
        }
        float dt = u[29];
        motion.zw += (force - motion.xy * \(VoiceOrbDissolution.spring) - motion.zw * \(VoiceOrbDissolution.damping)) * dt;
        motion.xy += motion.zw * dt;
        dissipation += (influence - dissipation) * (1.0 - exp(-dt /
            (influence > dissipation ? \(VoiceOrbDissolution.attack) : \(VoiceOrbDissolution.release))));
        interaction[vertexID * 2] = motion;
        interaction[vertexID * 2 + 1] = float4(dissipation, 0.0, 0.0, 0.0);
        position += motion.xy;

        float edgeFeather = pow(
            max(0.0, 1.0 - smoothstep(0.62, 1.34, radialDistance)),
            1.18
        );
        float edgeVariation = mix(
            1.0,
            0.58 + hashValue(vertexID * 0x9e3779b9u) * 0.42,
            smoothstep(0.64, 1.16, radialDistance)
        );
        float alpha =
            (0.65 + intensity * 0.35) *
            edgeFeather *
            edgeVariation *
            pow(1.0 - dissipation, 1.65) *
            u[9] *
            smoothstep(
                fract(flowPhaseX / (2.0 * M_PI_F)) * 0.14,
                0.58 +
                    fract(flowPhaseX / (2.0 * M_PI_F)) * 0.18,
                appearance
            ) *
            smoothstep(
                fract(flowPhaseX / (2.0 * M_PI_F)) * 0.14,
                0.58 +
                    fract(flowPhaseX / (2.0 * M_PI_F)) * 0.18,
                1.0 - completion
            );
        float colorMix = min(0.72, intensity * 0.64);
        float3 particleColor = mix(
            float3(u[13], u[14], u[15]),
            float3(u[16], u[17], u[18]),
            colorMix
        );

        OrbVertexOut out;
        out.position = float4(
            position.x / u[0] * 2.0 - 1.0,
            position.y / u[1] * 2.0 - 1.0,
            0.0,
            1.0
        );
        float coreSize = max(
            1.10 * u[20],
            radius * 2.0 *
                (0.28 + edgeFeather * 0.72) *
                (1.0 - dissipation * 0.68) *
                (0.55 + appearanceCondensation * 0.45) *
                u[20]
        );
        float logicalCoreRadius = coreSize / (2.0 * u[20]);
        float gradientEdgeWidth =
            clamp(logicalCoreRadius * 0.25, 0.50, 0.80) * u[20];
        out.pointSize = coreSize + gradientEdgeWidth * 2.0;
        out.color = particleColor;
        out.moteAxis = float2(cos(flowPhaseX), sin(flowPhaseX));
        out.moteAspect = mix(
            0.86,
            1.0,
            smoothstep(
                0.0,
                1.0,
                fract(flowPhaseY / (2.0 * M_PI_F))
            )
        );
        out.alpha = alpha;
        out.edrHeadroom = u[28];
        return out;
    }

    fragment half4 voiceOrbFragment(
        OrbVertexOut in [[stage_in]],
        float2 pointCoordinate [[point_coord]]
    ) {
        float2 local = (pointCoordinate - float2(0.5)) * 2.0;
        float2 perpendicular = float2(
            -in.moteAxis.y,
            in.moteAxis.x
        );
        float2 moteCoordinate = float2(
            dot(local, in.moteAxis) / in.moteAspect,
            dot(local, perpendicular)
        );
        float ellipticalRadius = length(moteCoordinate);
        float field = 1.0 - smoothstep(
            0.06,
            1.0,
            ellipticalRadius
        );
        field = pow(max(0.0, field), 0.82);
        return half4(
            half3(in.color * in.edrHeadroom),
            half(in.alpha * field)
        );
    }
    """
}
