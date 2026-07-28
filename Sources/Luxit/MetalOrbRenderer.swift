import AppKit
import Metal
import MetalKit
import QuartzCore

final class MetalOrbRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private weak var view: MTKView?
    private var particleBuffer: MTLBuffer?
    private var particleCount = 0
    private var uniformValues = [Float](repeating: 0, count: 29)
    private var lastSpectrum: [CGFloat] = []
    private var lastLevel: CGFloat = -1

    init?(view: MTKView) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        view.device = device
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(
            name: CGColorSpace.extendedLinearDisplayP3
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
            metalLayer.edrMetadata = nil
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
        super.init()
        view.delegate = self
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
        guard bounds.width > 0, bounds.height > 0 else { return }
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
        let strongestBand = spectrum.max() ?? 0
        let normalizedSpectrum = strongestBand > 0
            ? spectrum.map { max(0, min(1, $0 / strongestBand)) }
            : spectrum
        if normalizedSpectrum != lastSpectrum || displayLevel != lastLevel {
            rebuildParticles(
                spectrum: normalizedSpectrum,
                level: displayLevel
            )
            lastSpectrum = normalizedSpectrum
            lastLevel = displayLevel
        }

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
        uniformValues[23] = Float(VoiceOrbMotion.jitterScale)
        uniformValues[24] = Float(VoiceOrbMotion.spatialScale)
        uniformValues[25] = 1
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
        view?.layer?.contentsHeadroom = edrGain
        view?.draw()
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
        particleBuffer = device.makeBuffer(
            bytes: values,
            length: values.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
    }

    func draw(in view: MTKView) {
        guard
            particleCount > 0,
            let particleBuffer,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        uniformValues.withUnsafeBytes { bytes in
            encoder.setVertexBytes(
                bytes.baseAddress!,
                length: bytes.count,
                index: 1
            )
        }
        encoder.drawPrimitives(
            type: .point,
            vertexStart: 0,
            vertexCount: particleCount
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {}

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
                name: CGColorSpace.extendedLinearDisplayP3
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
        float4 color;
        float coreRatio;
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
        constant float *u [[buffer(1)]]
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
        float2 settled = rotated * u[2] + flow + jitter;
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

        float dissipation = 0.0;
        if (u[12] > 0.5) {
            float2 delta = position - float2(u[10], u[11]);
            float distance = length(delta);
            dissipation = max(0.0, 1.0 - distance / 42.0);
            if (dissipation > 0.0) {
                position += normalize(delta + float2(0.0001)) *
                    dissipation * 13.0;
            }
        }

        float radialDistance = length(base);
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
            (0.50 + intensity * 0.50) *
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
        float3 color = mix(
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
            0.5,
            radius * 2.0 *
                (0.28 + edgeFeather * 0.72) *
                (1.0 - dissipation * 0.68) *
                (0.55 + appearanceCondensation * 0.45) *
                u[20]
        );
        float logicalCoreRadius = coreSize / (2.0 * u[20]);
        float rimWidth =
            clamp(logicalCoreRadius * 0.22, 0.65, 0.8) * u[20];
        out.pointSize = coreSize + rimWidth * 2.0;
        out.coreRatio = coreSize / out.pointSize;
        out.color = float4(color, alpha);
        out.edrHeadroom = u[28];
        return out;
    }

    fragment half4 voiceOrbFragment(
        OrbVertexOut in [[stage_in]],
        float2 pointCoordinate [[point_coord]]
    ) {
        float distance = length(pointCoordinate - float2(0.5)) * 2.0;
        float outerCoverage = 1.0 - smoothstep(0.72, 1.0, distance);
        float coreCoverage = 1.0 - smoothstep(
            in.coreRatio * 0.72,
            in.coreRatio,
            distance
        );
        float rimCoverage = max(0.0, outerCoverage - coreCoverage);
        float coreLuminance = dot(
            in.color.rgb,
            float3(0.2126, 0.7152, 0.0722)
        );
        float lightCore = smoothstep(0.45, 0.82, coreLuminance);
        float rimOpacity = mix(0.14, 0.60, lightCore);
        float3 rimColor = float3(mix(1.0, 0.07, lightCore));
        float rimWeight = rimCoverage * rimOpacity;
        float totalCoverage = coreCoverage + rimWeight;
        float2 sphereCoordinate =
            (pointCoordinate - float2(0.5)) * 2.0 /
            max(0.0001, in.coreRatio);
        float sphereZ = sqrt(
            max(0.0, 1.0 - dot(sphereCoordinate, sphereCoordinate))
        );
        float3 normal = float3(
            sphereCoordinate.x,
            -sphereCoordinate.y,
            sphereZ
        );
        float3 light = normalize(float3(-0.48, 0.38, 0.79));
        float3 halfVector = normalize(light + float3(0.0, 0.0, 1.0));
        float diffuse = max(0.0, dot(normal, light));
        float specular = pow(max(0.0, dot(normal, halfVector)), 26.0);
        float pearlShade =
            0.54 +
            0.34 * diffuse +
            0.10 * pow(max(0.0, 1.0 - sphereZ), 1.6);
        float edrSpecular =
            specular *
            (0.18 + 0.72 * max(0.0, in.edrHeadroom - 1.0));
        float3 coreColor =
            in.color.rgb * pearlShade + float3(edrSpecular);
        float3 compositedColor = (
            coreColor * coreCoverage +
            rimColor * rimWeight
        ) / max(0.0001, totalCoverage);
        return half4(
            half3(compositedColor),
            half(in.color.a * totalCoverage)
        );
    }
    """
}
