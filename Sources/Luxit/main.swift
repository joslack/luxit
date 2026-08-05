import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import MetalKit

private enum DictationState {
    case idle
    case recording
}

private enum EdgeState {
    case hidden
    case recording
    case processing
    case completing
    case error
}

private typealias SelectedTranscriptionProfile = TranscriptionModelProfile

enum DiagnosticLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeWhisper/edgewhisper.log")
    private static let queue = DispatchQueue(
        label: "com.joslack.luxit.diagnostic-log",
        qos: .utility
    )
    private static var handle: FileHandle?
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let timestamp = Date()
        queue.async {
            let line = "\(formatter.string(from: timestamp)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                if handle == nil {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                    }
                    let openedHandle = try FileHandle(forWritingTo: url)
                    try openedHandle.seekToEnd()
                    handle = openedHandle
                }
                try handle?.write(contentsOf: data)
            } catch {
                NSLog("Luxit log failed: \(error.localizedDescription)")
            }
        }
    }
}

private func commandExists(_ command: String) -> Bool {
    guard !command.isEmpty else { return false }
    guard let path = ProcessInfo.processInfo.environment["PATH"] else {
        return false
    }
    return path
        .split(separator: ":")
        .contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(command)
                    .path
            )
        }
}

private func reasonForAvailability(_ availability: ModelAvailability) -> String {
    switch availability {
    case .available:
        "Ready"
    case .unavailable(let reason):
        reason
    }
}

private final class EdgeIndicatorView: NSView {
    var indicatorState: EdgeState = .hidden {
        didSet {
            if indicatorState != oldValue { refreshVisuals() }
        }
    }
    var audioLevel: CGFloat = 0 {
        didSet {
            if audioLevel != oldValue { refreshVisuals() }
        }
    }
    var audioProfile: [CGFloat] = Array(repeating: 0, count: 23) {
        didSet {
            if audioProfile != oldValue { refreshVisuals() }
        }
    }
    var pulse: CGFloat = 0 {
        didSet {
            if pulse != oldValue { refreshVisuals() }
        }
    }
    var processingProgress: CGFloat = 0 {
        didSet {
            if processingProgress != oldValue { refreshVisuals() }
        }
    }
    var animationPhase: CGFloat = 0 {
        didSet {
            if animationPhase != oldValue { refreshVisuals() }
        }
    }
    var orbMotionPhase: CGFloat = 0 {
        didSet {
            if orbMotionPhase != oldValue { refreshVisuals() }
        }
    }
    var completionProgress: CGFloat = 0 {
        didSet {
            if completionProgress != oldValue { refreshVisuals() }
        }
    }
    var pointerLocation: NSPoint? {
        didSet {
            if pointerLocation != oldValue { refreshVisuals() }
        }
    }
    var appearanceProgress: CGFloat = 0 {
        didSet {
            if appearanceProgress != oldValue { refreshVisuals() }
        }
    }

    private var metalOrbView: MTKView?
    private var metalOrbRenderer: MetalOrbRenderer?
    private var visualUpdateDepth = 0
    private var visualRefreshPending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureMetalOrb()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMetalOrb()
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        metalOrbView?.frame = bounds
        syncMetalOrb()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard indicatorState != .hidden else { return }
        guard metalOrbRenderer == nil else { return }

        switch indicatorState {
        case .recording:
            drawVoiceOrb()
        case .processing:
            drawVoiceOrb(processingProgress: processingProgress)
        case .completing:
            drawVoiceOrb(
                processingProgress: processingProgress,
                completion: completionProgress
            )
        case .error:
            drawVoiceOrb(processingProgress: 1)
        case .hidden:
            return
        }
    }

    private func configureMetalOrb() {
        let metalView = MTKView(frame: bounds, device: nil)
        metalView.autoresizingMask = [.width, .height]
        metalView.isHidden = true
        metalView.wantsLayer = true
        metalView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(metalView)
        metalOrbView = metalView
        metalOrbRenderer = MetalOrbRenderer(view: metalView)
        if metalOrbRenderer == nil {
            metalView.removeFromSuperview()
            metalOrbView = nil
            DiagnosticLog.write("Voice orb falling back to AppKit rendering")
        }
    }

    func performVisualUpdate(_ update: () -> Void) {
        visualUpdateDepth += 1
        update()
        visualUpdateDepth -= 1
        guard visualUpdateDepth == 0, visualRefreshPending else { return }
        visualRefreshPending = false
        renderVisuals()
    }

    private func refreshVisuals() {
        guard visualUpdateDepth == 0 else {
            visualRefreshPending = true
            return
        }
        renderVisuals()
    }

    private func renderVisuals() {
        needsDisplay = true
        syncMetalOrb()
    }

    private func syncMetalOrb() {
        let usesMetalOrb = indicatorState != .hidden
        metalOrbView?.isHidden = !usesMetalOrb
        guard usesMetalOrb, let metalOrbRenderer else { return }
        let (accent, highlight) = orbColors
        metalOrbRenderer.update(
            spectrum: audioProfile,
            level: audioLevel,
            orbMotionPhase: orbMotionPhase,
            animationPhase: animationPhase,
            pulse: pulse,
            processingProgress: processingProgress,
            completion: completionProgress,
            appearance: appearanceProgress,
            pointer: pointerLocation,
            accent: accent,
            highlight: highlight,
            bounds: bounds
        )
    }

    private var processingColor: NSColor {
        NSColor(
            calibratedRed: 1.0,
            green: 0.64,
            blue: 0.12,
            alpha: 1
        )
    }

    private var orbColors: (accent: NSColor, highlight: NSColor) {
        switch indicatorState {
        case .processing, .completing:
            let colorBlend =
                VoiceOrbMotion.processingColorBlend(processingProgress)
            return (
                NSColor.white.blended(
                    withFraction: colorBlend,
                    of: processingColor
                ) ?? .white,
                NSColor.white.blended(
                    withFraction: colorBlend,
                    of: NSColor(
                        calibratedRed: 1,
                        green: 0.87,
                        blue: 0.52,
                        alpha: 1
                    )
                ) ?? .white
            )
        case .error:
            return (
                NSColor(
                    calibratedRed: 1,
                    green: 0.08,
                    blue: 0.42,
                    alpha: 1
                ),
                NSColor(
                    calibratedRed: 1,
                    green: 0.72,
                    blue: 0.82,
                    alpha: 1
                )
            )
        case .recording, .hidden:
            return (.white, .white)
        }
    }

    private func drawVoiceOrb(
        processingProgress: CGFloat = 0,
        completion: CGFloat = 0
    ) {
        let processing = max(0, min(1, processingProgress))
        let processingBlend =
            VoiceOrbMotion.processingGeometryBlend(processing)
        let progress = max(0, min(1, completion))
        let completionAlpha =
            VoiceOrbMotion.visibilityAlpha(1 - progress)
        let appearanceCondensation =
            VoiceOrbMotion.materializationBlend(appearanceProgress)
        let condensation =
            VoiceOrbMotion.materializationCondensation(
                appearance: appearanceProgress,
                completion: progress
            )
        let voice = pow(max(0, min(1, audioLevel)), 0.72)
        let displayLevel = max(
            VoiceOrbMotion.idleVisualFloor,
            max(
                voice,
                VoiceOrbMotion.processingLevelFloor * processingBlend
            )
        )
        let strongestBand = audioProfile.max() ?? 0
        let orbSpectrum = strongestBand > 0
            ? audioProfile.map { max(0, min(1, $0 / strongestBand)) }
            : audioProfile
        let points = VoiceOrbGeometry.points(
            spectrum: orbSpectrum,
            level: displayLevel
        )
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let processingScale =
            VoiceOrbMotion.processingBreathScale(pulse)
        let baseRadius = (
            VoiceOrbMotion.baseRadius +
            displayLevel * VoiceOrbMotion.voiceRadiusGrowth
        ) *
            (1 + (processingScale - 1) * processingBlend)
        // Processing preserves the recording flow phase while a separate
        // radius modulation adds the unified breathing signal.
        let rotation = animationPhase * 0.11
        let (color, highlight) = orbColors
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let materializationFieldRadius =
            VoiceOrbMotion.materializationFieldRadius(
                baseRadius: baseRadius,
                panelExtent: min(bounds.width, bounds.height)
            )
        let materializationDotScale =
            VoiceOrbMotion.materializationDotScale(
                appearanceCondensation
            )
        for (index, point) in points.enumerated() {
            let rotatedX = point.x * cosine - point.y * sine
            let rotatedY = point.x * sine + point.y * cosine
            let particleTimeX =
                animationPhase * point.velocity + point.flowPhase
            let particleTimeY =
                animationPhase * (0.55 + point.velocity * 1.17) +
                point.flowPhaseY
            let jitterAmount =
                (
                    0.55 +
                    displayLevel *
                        4.20 *
                        VoiceOrbMotion.voiceResponseScale
                ) *
                (0.42 + point.intensity * 0.58) *
                point.driftScale *
                VoiceOrbMotion.jitterScale
            let flowAmount = (
                2.20 +
                displayLevel *
                    point.intensity *
                    4.80 *
                    VoiceOrbMotion.voiceResponseScale
            ) * point.driftScale * VoiceOrbMotion.currentScale
            let spatialScale = VoiceOrbMotion.spatialScale
            let flowX =
                (
                    sin(
                        particleTimeX * 1.35 +
                        rotatedY * 5.2 * spatialScale
                    ) +
                    cos(
                        particleTimeY * 0.73 -
                        rotatedX * 4.0 * spatialScale
                    ) * 0.55
                ) * flowAmount
            let flowY =
                (
                    cos(
                        particleTimeY * 1.21 +
                        rotatedX * 5.0 * spatialScale
                    ) +
                    sin(
                        particleTimeX * 0.67 +
                        rotatedY * 3.8 * spatialScale
                    ) * 0.50
                ) * flowAmount
            let attractorAmount =
                (
                    2.6 +
                    displayLevel *
                        8.5 *
                        VoiceOrbMotion.voiceResponseScale
                ) *
                point.driftScale
            let attractorX =
                (
                    sin(rotatedY * 1.7 + particleTimeX) +
                    cos(rotatedX * -1.3 - particleTimeY) * 0.55
                ) * attractorAmount
            let attractorY =
                (
                    sin(rotatedX * -1.9 + particleTimeY) +
                    cos(rotatedY * 1.5 + particleTimeX) * 0.55
                ) * attractorAmount
            let noiseX =
                VoiceOrbGeometry.motionNoise(
                    point: index,
                    time:
                        orbMotionPhase * point.velocity +
                        point.flowPhase * 0.16,
                    channel: 0
                ) * jitterAmount
            let noiseY =
                VoiceOrbGeometry.motionNoise(
                    point: index,
                    time:
                        orbMotionPhase *
                            (0.48 + point.velocity * 1.31) +
                        point.flowPhaseY * 0.16,
                    channel: 1
                ) * jitterAmount
            let radialDistance = hypot(point.x, point.y)
            let rippleOffset = VoiceOrbMotion.processingRippleOffset(
                radialDistance: radialDistance,
                processingProgress: processing,
                completion: progress
            )
            let safeRadialDistance = max(0.0001, radialDistance)
            let rippleX =
                rotatedX / safeRadialDistance * rippleOffset
            let rippleY =
                rotatedY / safeRadialDistance * rippleOffset
            let settledX =
                rotatedX * baseRadius +
                flowX +
                attractorX +
                noiseX +
                rippleX
            let settledY =
                rotatedY * baseRadius +
                flowY +
                attractorY +
                noiseY +
                rippleY
            let radialSeed = max(
                0,
                min(1, point.flowPhaseY / (2 * .pi))
            )
            let spawnRadius =
                materializationFieldRadius * sqrt(radialSeed)
            let spawnX = cos(point.flowPhase) * spawnRadius
            let spawnY = sin(point.flowPhase) * spawnRadius
            var position = NSPoint(
                x:
                    center.x +
                    spawnX * (1 - condensation) +
                    settledX * condensation,
                y:
                    center.y +
                    spawnY * (1 - condensation) +
                    settledY * condensation
            )
            var dissipation: CGFloat = 0
            if let pointerLocation {
                let deltaX = position.x - pointerLocation.x
                let deltaY = position.y - pointerLocation.y
                let distance = hypot(deltaX, deltaY)
                dissipation = max(0, 1 - distance / 42)
                if dissipation > 0 {
                    let safeDistance = max(1, distance)
                    position.x += deltaX / safeDistance * dissipation * 13
                    position.y += deltaY / safeDistance * dissipation * 13
                }
            }

            let edgeFeather = pow(
                max(
                    0,
                    1 - smoothstep(0.62, 1.34, radialDistance)
                ),
                1.18
            )
            let edgeVariation =
                1 -
                smoothstep(0.64, 1.16, radialDistance) *
                (0.42 - min(0.42, point.driftScale * 0.16))
            let alpha =
                VoiceOrbMotion.particleBaseAlpha(
                    intensity: point.intensity
                ) *
                edgeFeather *
                edgeVariation *
                pow(1 - dissipation, 1.65) *
                completionAlpha *
                VoiceOrbMotion.materializationAlpha(
                    appearanceProgress,
                    seed: point.flowPhase / (2 * .pi)
                ) *
                VoiceOrbMotion.materializationAlpha(
                    1 - progress,
                    seed: point.flowPhase / (2 * .pi)
                )
            guard alpha > 0 else { continue }
            let baseDotRadius = max(
                VoiceOrbMotion.minimumParticleRadius,
                point.radius *
                (0.28 + edgeFeather * 0.72) *
                (1 - dissipation * 0.68) *
                    materializationDotScale
            )
            let pointColor =
                color.blended(
                    withFraction: min(0.72, point.intensity * 0.64),
                    of: highlight
                ) ?? color
            let dotRadius = baseDotRadius
            let gradientEdgeWidth =
                VoiceOrbMotion.particleHaloWidth(
                    coreRadius: dotRadius
                )
            let outerRadius = dotRadius + gradientEdgeWidth
            func moteColor(at radius: CGFloat) -> NSColor {
                let field =
                    VoiceOrbMotion.particleMoteField(radius: radius)
                return pointColor.withAlphaComponent(
                    alpha * field
                )
            }
            let gradient = NSGradient(
                colorsAndLocations:
                    (moteColor(at: 0), 0),
                    (moteColor(at: 0.28), 0.28),
                    (moteColor(at: 0.56), 0.56),
                    (moteColor(at: 0.78), 0.78),
                    (moteColor(at: 1), 1)
            )
            guard let context = NSGraphicsContext.current?.cgContext else {
                continue
            }
            context.saveGState()
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: point.flowPhase)
            context.scaleBy(
                x: VoiceOrbMotion.particleMoteAspect(
                    seed: point.flowPhaseY / (2 * .pi)
                ),
                y: 1
            )
            gradient?.draw(
                in: NSRect(
                    x: -outerRadius,
                    y: -outerRadius,
                    width: outerRadius * 2,
                    height: outerRadius * 2
                ),
                relativeCenterPosition: .zero
            )
            context.restoreGState()
        }
    }

    private func smoothstep(
        _ lower: CGFloat,
        _ upper: CGFloat,
        _ value: CGFloat
    ) -> CGFloat {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        let normalized = max(0, min(1, (value - lower) / (upper - lower)))
        return normalized * normalized * (3 - 2 * normalized)
    }
}

private final class EdgeIndicator {
    private struct Surface {
        let displayID: NSNumber
        let panel: NSPanel
        let view: EdgeIndicatorView
    }

    private var surfaces: [Surface] = []
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var breathPhase: CGFloat = -.pi / 2
    private var currentState: EdgeState = .hidden
    private var currentAudioLevel: CGFloat = 0
    private var currentAudioProfile: [CGFloat] = Array(repeating: 0, count: 23)
    private var orbMotionPhase: CGFloat = 0
    private var orbMotionSpeed: CGFloat = 0
    private var lastAnimationUptime: TimeInterval = 0
    private var appearanceProgress: CGFloat = 0
    private var processingProgress: CGFloat = 0
    private var processingBeganAt: TimeInterval?
    private var pendingCompletionWorkItem: DispatchWorkItem?
    private var completionUsesProcessing = false
    private let voiceAnimationFilter = VoiceAnimationFilter()
    private var targetDisplayID: NSNumber?

    init() {
        rebuildPanels()
    }

    func show(_ state: EdgeState) {
        let previousState = currentState
        if state != .processing {
            pendingCompletionWorkItem?.cancel()
            pendingCompletionWorkItem = nil
            processingBeganAt = nil
        }
        currentState = state
        for surface in surfaces {
            surface.view.completionProgress = 0
        }
        ensureCurrentScreens()
        if state == .recording && previousState != .recording {
            voiceAnimationFilter.beginRecording()
            currentAudioLevel = 0
            currentAudioProfile = Array(repeating: 0, count: 23)
            orbMotionPhase = 0
            orbMotionSpeed = 0
            phase = 0
            appearanceProgress = 0
            processingProgress = 0
            let target = resolveTargetDisplay()
            targetDisplayID = target.displayID
            DiagnosticLog.write(
                "Edge indicator target display=\(target.displayID) " +
                "source=\(target.source)"
            )
        } else if state == .processing && previousState != .processing {
            // Preserve the exact flow phase and full cloud volume, then begin
            // a separate processing breath without an inward preparatory beat.
            breathPhase = -.pi / 2
            processingProgress = 0
            processingBeganAt = ProcessInfo.processInfo.systemUptime
        } else if state == .error {
            appearanceProgress = 1
            processingProgress = 1
        } else if targetDisplayID == nil {
            targetDisplayID = resolveTargetDisplay().displayID
        }
        presentPanels()

        timer?.invalidate()
        if state == .recording {
            lastAnimationUptime = ProcessInfo.processInfo.systemUptime
            let recordingTimer = Timer(
                timeInterval: animationInterval,
                repeats: true
            ) {
                [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = min(
                    1.0 / 30.0,
                    max(0, now - self.lastAnimationUptime)
                )
                self.lastAnimationUptime = now
                self.appearanceProgress = min(
                    1,
                    self.appearanceProgress +
                        elapsed / VoiceOrbMotion.appearanceTransitionDuration
                )
                self.orbMotionPhase +=
                    elapsed *
                    self.orbMotionSpeed *
                    VoiceOrbMotion.speedScale
                let flowSpeed =
                    1.55 +
                    (
                        self.currentAudioLevel * 2.40 +
                        min(2.00, self.orbMotionSpeed * 0.15)
                    ) * VoiceOrbMotion.voiceResponseScale
                self.phase +=
                    elapsed * flowSpeed * VoiceOrbMotion.speedScale
                for surface in self.surfaces {
                    surface.view.performVisualUpdate {
                        surface.view.orbMotionPhase = self.orbMotionPhase
                        surface.view.animationPhase = self.phase
                        surface.view.appearanceProgress =
                            self.appearanceProgress
                        surface.view.processingProgress = 0
                    }
                }
                self.updatePointerDissipation()
            }
            timer = recordingTimer
            RunLoop.main.add(recordingTimer, forMode: .common)
        } else if state == .processing {
            lastAnimationUptime = ProcessInfo.processInfo.systemUptime
            let processingTimer = Timer(
                timeInterval: animationInterval,
                repeats: true
            ) {
                [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = min(
                    1.0 / 30.0,
                    max(0, now - self.lastAnimationUptime)
                )
                self.lastAnimationUptime = now
                self.appearanceProgress = min(
                    1,
                    self.appearanceProgress +
                        elapsed / VoiceOrbMotion.appearanceTransitionDuration
                )
                self.advanceProcessingTransition(elapsed: elapsed)
                self.breathPhase += elapsed * 2.2
                self.orbMotionPhase +=
                    elapsed *
                    self.orbMotionSpeed *
                    VoiceOrbMotion.speedScale
                let flowSpeed =
                    1.55 +
                    (
                        self.currentAudioLevel * 2.40 +
                        min(2.00, self.orbMotionSpeed * 0.15)
                    ) * VoiceOrbMotion.voiceResponseScale
                self.phase +=
                    elapsed * flowSpeed * VoiceOrbMotion.speedScale
                let pulse = (sin(self.breathPhase) + 1) / 2
                for surface in self.surfaces {
                    surface.view.performVisualUpdate {
                        surface.view.pulse = pulse
                        surface.view.animationPhase = self.phase
                        surface.view.orbMotionPhase = self.orbMotionPhase
                        surface.view.appearanceProgress =
                            self.appearanceProgress
                        surface.view.processingProgress =
                            self.processingProgress
                        surface.view.audioLevel = self.currentAudioLevel
                        surface.view.audioProfile =
                            self.currentAudioProfile
                    }
                }
                self.updatePointerDissipation()
            }
            timer = processingTimer
            RunLoop.main.add(processingTimer, forMode: .common)
        } else if state == .error {
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) {
                [weak self] _ in self?.hide()
            }
        }

        let expectedState = stateName(state)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.stateName(self.currentState) == expectedState else {
                return
            }
            let visibleCount = self.surfaces.filter(\.panel.isVisible).count
            DiagnosticLog.write(
                "Edge indicator render state=\(expectedState) " +
                "visiblePanels=\(visibleCount)/\(self.surfaces.count)"
            )
        }
    }

    func complete() {
        guard currentState != .completing else { return }
        guard currentState == .processing else {
            hide()
            return
        }

        if let processingBeganAt {
            let elapsed =
                ProcessInfo.processInfo.systemUptime - processingBeganAt
            let remaining =
                TimeInterval(VoiceOrbMotion.processingMinimumDwell) -
                elapsed
            if remaining > 0 {
                pendingCompletionWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.currentState == .processing else {
                        return
                    }
                    self.pendingCompletionWorkItem = nil
                    self.complete()
                }
                pendingCompletionWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + remaining,
                    execute: workItem
                )
                return
            }
        }

        beginCompletion(usesProcessing: true)
    }

    func completeRecording() {
        guard currentState == .recording else {
            complete()
            return
        }
        beginCompletion(usesProcessing: false)
    }

    private func beginCompletion(usesProcessing: Bool) {
        pendingCompletionWorkItem?.cancel()
        pendingCompletionWorkItem = nil
        processingBeganAt = nil
        completionUsesProcessing = usesProcessing
        timer?.invalidate()
        timer = nil
        currentState = .completing
        for surface in surfaces where surface.panel.isVisible {
            surface.view.performVisualUpdate {
                surface.view.indicatorState = .completing
                surface.view.completionProgress = 0
            }
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        lastAnimationUptime = startedAt
        let duration =
            TimeInterval(VoiceOrbMotion.completionTransitionDuration)
        let completionTimer = Timer(
            timeInterval: animationInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.currentState == .completing else {
                timer.invalidate()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let frameElapsed = min(
                1.0 / 30.0,
                max(0, now - self.lastAnimationUptime)
            )
            self.lastAnimationUptime = now
            if self.completionUsesProcessing {
                self.advanceProcessingTransition(elapsed: frameElapsed)
            }
            self.breathPhase += frameElapsed * 2.2
            self.orbMotionPhase +=
                frameElapsed *
                self.orbMotionSpeed *
                VoiceOrbMotion.speedScale
            let flowSpeed =
                1.55 +
                (
                    self.currentAudioLevel * 2.40 +
                    min(2.00, self.orbMotionSpeed * 0.15)
                ) * VoiceOrbMotion.voiceResponseScale
            self.phase +=
                frameElapsed * flowSpeed * VoiceOrbMotion.speedScale
            let pulse = (sin(self.breathPhase) + 1) / 2
            let elapsed = now - startedAt
            let progress = min(1, CGFloat(elapsed / duration))
            for surface in self.surfaces {
                surface.view.performVisualUpdate {
                    surface.view.completionProgress = progress
                    surface.view.pulse = pulse
                    surface.view.animationPhase = self.phase
                    surface.view.orbMotionPhase = self.orbMotionPhase
                    surface.view.appearanceProgress =
                        self.appearanceProgress
                    surface.view.processingProgress =
                        self.processingProgress
                    surface.view.audioLevel = self.currentAudioLevel
                    surface.view.audioProfile =
                        self.currentAudioProfile
                }
            }
            self.updatePointerDissipation()
            if progress >= 1 {
                timer.invalidate()
                self.hide()
                DiagnosticLog.write("Edge indicator completion cascade finished")
            }
        }
        timer = completionTimer
        RunLoop.main.add(completionTimer, forMode: .common)
    }

    private func advanceProcessingTransition(elapsed: CGFloat) {
        processingProgress = VoiceOrbMotion.advanceProcessingProgress(
            processingProgress,
            elapsed: elapsed
        )
        let settling = min(1, elapsed * 2.2)
        currentAudioLevel += (0.22 - currentAudioLevel) * settling
        for index in currentAudioProfile.indices {
            currentAudioProfile[index] +=
                (0.18 - currentAudioProfile[index]) * settling
        }
        orbMotionSpeed +=
            (VoiceOrbMotion.processingMotionSpeed - orbMotionSpeed) *
            settling
    }

    func setAudioLevel(_ level: Float, spectrum: [Float]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let conditioned = self.voiceAnimationFilter.process(
                level: level,
                spectrum: spectrum
            )
            let target = CGFloat(
                VoiceAnimationFilter.visualResponse(
                    for: conditioned.level
                )
            )
            let responsiveness: CGFloat =
                target > self.currentAudioLevel ? 0.72 : 0.28
            self.currentAudioLevel +=
                (target - self.currentAudioLevel) * responsiveness

            let strongestBand = conditioned.spectrum.max() ?? 0
            var spectralFlux: CGFloat = 0
            for index in self.currentAudioProfile.indices {
                let relativeEnergy: CGFloat
                if strongestBand > 0,
                   conditioned.spectrum.indices.contains(index) {
                    relativeEnergy = CGFloat(
                        max(
                            0,
                            min(
                                1,
                                conditioned.spectrum[index] / strongestBand
                            )
                        )
                    )
                } else {
                    relativeEnergy = 0
                }
                // Log-like compression preserves the spectral shape while the
                // measured full-band RMS controls its absolute visual size.
                let spectralShape = pow(relativeEnergy, 0.42)
                let bandTarget = target * spectralShape
                spectralFlux += abs(
                    bandTarget - self.currentAudioProfile[index]
                )
                let bandResponsiveness: CGFloat =
                    bandTarget > self.currentAudioProfile[index] ? 0.76 : 0.24
                self.currentAudioProfile[index] +=
                    (bandTarget - self.currentAudioProfile[index]) *
                    bandResponsiveness
            }
            spectralFlux /= CGFloat(max(1, self.currentAudioProfile.count))
            let targetMotionSpeed =
                0.35 +
                self.currentAudioLevel * 11.5 +
                min(5.0, spectralFlux * 60)
            self.orbMotionSpeed +=
                (targetMotionSpeed - self.orbMotionSpeed) * 0.42
            for surface in self.surfaces {
                surface.view.performVisualUpdate {
                    surface.view.audioLevel = self.currentAudioLevel
                    surface.view.audioProfile = self.currentAudioProfile
                }
            }
            self.updatePointerDissipation()
        }
    }

    func hide() {
        pendingCompletionWorkItem?.cancel()
        pendingCompletionWorkItem = nil
        processingBeganAt = nil
        timer?.invalidate()
        timer = nil
        completionUsesProcessing = false
        currentState = .hidden
        targetDisplayID = nil
        processingProgress = 0
        for surface in surfaces {
            surface.view.performVisualUpdate {
                surface.view.indicatorState = .hidden
                surface.view.pointerLocation = nil
            }
            surface.panel.orderOut(nil)
        }
    }

    func rebuildPanels() {
        let oldSurfaces = surfaces
        surfaces = NSScreen.screens.compactMap(makeSurface)
        for surface in oldSurfaces {
            surface.panel.orderOut(nil)
        }
        if let targetDisplayID,
           !surfaces.contains(where: { $0.displayID == targetDisplayID }) {
            self.targetDisplayID = nil
        }
        if currentState != .hidden {
            if targetDisplayID == nil {
                targetDisplayID = resolveTargetDisplay().displayID
            }
            presentPanels()
        }
        DiagnosticLog.write(
            "Edge indicator panels rebuilt displays=\(surfaces.count)"
        )
    }

    private func makeSurface(for screen: NSScreen) -> Surface? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: VoiceOrbLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let indicatorView = EdgeIndicatorView(frame: .zero)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = indicatorView
        panel.setFrame(panelFrame(on: screen), display: false)

        // Realize the transparent panel with WindowServer at launch. Its first
        // recording indication should only change pixels, not create a window.
        indicatorView.indicatorState = .hidden
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        return Surface(displayID: displayID, panel: panel, view: indicatorView)
    }

    private var animationInterval: TimeInterval {
        let display = targetDisplayID.flatMap(screen(for:))
        let framesPerSecond = max(
            60,
            min(120, display?.maximumFramesPerSecond ?? 60)
        )
        return 1 / TimeInterval(framesPerSecond)
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        VoiceOrbLayout.frame(in: screen.visibleFrame)
    }

    private func screen(for displayID: NSNumber) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber) == displayID
        }
    }

    private func updatePointerDissipation() {
        let mouse = NSEvent.mouseLocation
        for surface in surfaces {
            guard
                surface.displayID == targetDisplayID,
                surface.panel.isVisible,
                surface.panel.frame.insetBy(dx: -32, dy: -32).contains(mouse)
            else {
                surface.view.pointerLocation = nil
                continue
            }
            let windowPoint = surface.panel.convertPoint(fromScreen: mouse)
            surface.view.pointerLocation = surface.view.convert(
                windowPoint,
                from: nil
            )
        }
    }

    private func ensureCurrentScreens() {
        let currentIDs = Set(surfaces.map(\.displayID))
        let screenIDs = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        })
        if currentIDs != screenIDs {
            rebuildPanels()
        }
    }

    func screenParametersChanged() {
        let screensByID: [NSNumber: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber else {
                    return nil
                }
                return (displayID, screen)
            }
        )
        let currentIDs = Set(surfaces.map(\.displayID))
        guard currentIDs == Set(screensByID.keys) else {
            rebuildPanels()
            return
        }
        for surface in surfaces {
            guard let screen = screensByID[surface.displayID] else {
                continue
            }
            surface.panel.setFrame(
                panelFrame(on: screen),
                display: false
            )
        }
    }

    private func presentPanels() {
        let target = targetDisplayID ?? resolveTargetDisplay().displayID
        targetDisplayID = target
        for surface in surfaces {
            guard surface.displayID == target else {
                surface.view.indicatorState = .hidden
                surface.panel.orderOut(nil)
                continue
            }
            let visiblePulsePhase =
                currentState == .processing || currentState == .completing
                    ? breathPhase
                    : phase
            surface.view.performVisualUpdate {
                surface.view.indicatorState = currentState
                surface.view.audioLevel = currentAudioLevel
                surface.view.audioProfile = currentAudioProfile
                surface.view.appearanceProgress = appearanceProgress
                surface.view.processingProgress = processingProgress
                surface.view.pulse =
                    (sin(visiblePulsePhase) + 1) / 2
                surface.view.animationPhase = phase
                surface.view.orbMotionPhase = orbMotionPhase
            }
            surface.panel.orderFrontRegardless()
            surface.panel.displayIfNeeded()
        }
        updatePointerDissipation()
    }

    private func resolveTargetDisplay() -> (
        displayID: NSNumber,
        source: String
    ) {
        if let element = focusedAccessibilityElement() {
            if let caretRect = caretRect(for: element),
               let displayID = displayID(containingAXPoint: CGPoint(
                   x: caretRect.midX,
                   y: caretRect.midY
               )) {
                return (displayID, "caret")
            }
            if let elementRect = accessibilityFrame(for: element),
               let displayID = displayID(containingAXPoint: CGPoint(
                   x: elementRect.midX,
                   y: elementRect.midY
               )) {
                return (displayID, "focused-element")
            }
        }

        if let application = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(
                application.processIdentifier
            )
            if let window = copiedElementAttribute(
                appElement,
                kAXFocusedWindowAttribute
            ), let windowRect = accessibilityFrame(for: window),
               let displayID = displayID(containingAXPoint: CGPoint(
                   x: windowRect.midX,
                   y: windowRect.midY
               )) {
                return (displayID, "focused-window")
            }
        }

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(mouse)
        }), let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return (displayID, "mouse-fallback")
        }

        if let main = NSScreen.main,
           let displayID = main.deviceDescription[
               NSDeviceDescriptionKey("NSScreenNumber")
           ] as? NSNumber {
            return (displayID, "main-display-fallback")
        }

        return (surfaces.first?.displayID ?? 0, "first-display-fallback")
    }

    private func focusedAccessibilityElement() -> AXUIElement? {
        copiedElementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute
        )
    }

    private func copiedElementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func caretRect(for element: AXUIElement) -> CGRect? {
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        ) == .success, let selectedRange else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRange,
            &boundsValue
        ) == .success, let boundsValue else {
            return nil
        }

        let value = unsafeBitCast(boundsValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect),
              rect.height > 0,
              rect.midX.isFinite,
              rect.midY.isFinite else {
            return nil
        }
        return rect
    }

    private func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue else {
            return nil
        }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func displayID(containingAXPoint point: CGPoint) -> NSNumber? {
        surfaces.first { surface in
            CGDisplayBounds(
                CGDirectDisplayID(surface.displayID.uint32Value)
            ).contains(point)
        }?.displayID
    }

    private func stateName(_ state: EdgeState) -> String {
        switch state {
        case .hidden: return "hidden"
        case .recording: return "recording"
        case .processing: return "processing"
        case .completing: return "completing"
        case .error: return "error"
        }
    }
}

private struct RecordedAudio {
    let url: URL
    let duration: TimeInterval
    let peakLevel: Float
    let voicedSeconds: TimeInterval

    var isLikelySilent: Bool {
        duration < 0.35 || peakLevel < 0.0075 || voicedSeconds < 0.12
    }
}

private final class AudioRecorder {
    private var engine = AVAudioEngine()
    private let spectrumAnalyzer = LogSpectrumAnalyzer()
    private let metricsLock = NSLock()
    private let speechLevelThreshold: Float = 0.006
    private var routeTracker = AudioInputRouteTracker()
    private var file: AVAudioFile?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var peakLevel: Float = 0
    private var voicedSeconds: TimeInterval = 0
    private var isPrepared = false

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func prepareIfAuthorized() {
        guard !isPrepared,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }
        let beganAt = CACurrentMediaTime()
        do {
            let device = try SystemAudioInput.preferredDevice()
            let input = engine.inputNode
            try SystemAudioInput.bind(input, to: device)
            _ = input.outputFormat(forBus: 0)
            engine.prepare()
            routeTracker.markPrepared(for: device.id)
            isPrepared = true
            DiagnosticLog.write(
                String(
                    format: "Audio engine prepared input=%@ id=%u in %.3fs",
                    device.name,
                    device.id,
                    CACurrentMediaTime() - beganAt
                )
            )
        } catch {
            routeTracker.invalidate()
            isPrepared = false
            DiagnosticLog.write(
                "Audio engine prewarm deferred: \(error.localizedDescription)"
            )
        }
    }

    func start(level: @escaping (Float, [Float]) -> Void) throws {
        let beganAt = CACurrentMediaTime()
        let device = try SystemAudioInput.preferredDevice()
        if routeTracker.requiresEngineReplacement(for: device.id) {
            let previousDeviceID = routeTracker.preparedDeviceID
            engine.stop()
            engine.reset()
            engine = AVAudioEngine()
            routeTracker.invalidate()
            isPrepared = false
            DiagnosticLog.write(
                "Audio input changed id=\(previousDeviceID ?? 0)->\(device.id); " +
                "rebuilt recorder"
            )
        }

        let input = engine.inputNode
        try SystemAudioInput.bind(input, to: device)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Luxit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone is available."]
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-whisper-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        file = audioFile
        recordingURL = url
        metricsLock.lock()
        peakLevel = 0
        voicedSeconds = 0
        metricsLock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.file?.write(from: buffer)
            } catch {
                NSLog("Luxit audio write failed: \(error.localizedDescription)")
            }

            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                let samples = channels[0]
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) {
                    sum += samples[index] * samples[index]
                }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let spectrum = self.spectrumAnalyzer?.process(
                    samples: samples,
                    frameCount: Int(buffer.frameLength),
                    sampleRate: format.sampleRate
                ) ?? Array(
                    repeating: 0,
                    count: LogSpectrumAnalyzer.defaultBandCount
                )
                let bufferSeconds = Double(buffer.frameLength) / format.sampleRate
                self.metricsLock.lock()
                self.peakLevel = max(self.peakLevel, rms)
                if rms >= self.speechLevelThreshold {
                    self.voicedSeconds += bufferSeconds
                }
                self.metricsLock.unlock()
                level(rms, spectrum)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            startedAt = Date()
            routeTracker.markPrepared(for: device.id)
            isPrepared = true
            DiagnosticLog.write(
                String(
                    format: "Audio recorder ready input=%@ id=%u rate=%.0fHz " +
                        "channels=%u latency=%.3fs",
                    device.name,
                    device.id,
                    format.sampleRate,
                    format.channelCount,
                    CACurrentMediaTime() - beganAt
                )
            )
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            recordingURL = nil
            startedAt = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> RecordedAudio? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        guard let recordingURL else { return nil }
        let duration = max(0, Date().timeIntervalSince(startedAt ?? Date()))
        metricsLock.lock()
        let peakLevel = self.peakLevel
        let voicedSeconds = self.voicedSeconds
        metricsLock.unlock()
        self.recordingURL = nil
        startedAt = nil
        return RecordedAudio(
            url: recordingURL,
            duration: duration,
            peakLevel: peakLevel,
            voicedSeconds: voicedSeconds
        )
    }
}

private struct StatisticsSnapshot {
    let audioSeconds: TimeInterval
    let processingSeconds: TimeInterval
    let words: Int
    let dictations: Int

    var averageLatency: TimeInterval {
        dictations > 0 ? processingSeconds / Double(dictations) : 0
    }

    var realtimeSpeed: Double {
        processingSeconds > 0 ? audioSeconds / processingSeconds : 0
    }
}

private final class StatisticsStore {
    private enum Key {
        static let audioSeconds = "stats.audioSeconds"
        static let processingSeconds = "stats.processingSeconds"
        static let words = "stats.words"
        static let dictations = "stats.dictations"
    }

    private let defaults = UserDefaults.standard

    var snapshot: StatisticsSnapshot {
        StatisticsSnapshot(
            audioSeconds: defaults.double(forKey: Key.audioSeconds),
            processingSeconds: defaults.double(forKey: Key.processingSeconds),
            words: defaults.integer(forKey: Key.words),
            dictations: defaults.integer(forKey: Key.dictations)
        )
    }

    func record(audioSeconds: TimeInterval, processingSeconds: TimeInterval, text: String) {
        let existing = snapshot
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        defaults.set(existing.audioSeconds + audioSeconds, forKey: Key.audioSeconds)
        defaults.set(existing.processingSeconds + processingSeconds, forKey: Key.processingSeconds)
        defaults.set(existing.words + wordCount, forKey: Key.words)
        defaults.set(existing.dictations + 1, forKey: Key.dictations)
    }
}

private final class StatsPopoverViewController: NSViewController {
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let hoursValue = NSTextField(labelWithString: "0.00 h")
    private let wordsValue = NSTextField(labelWithString: "0")
    private let dictationsValue = NSTextField(labelWithString: "0")
    private let performanceValue = NSTextField(labelWithString: "—")
    private let permissionsValue = NSTextField(labelWithString: "Checking permissions…")
    private let modelControl = NSPopUpButton(frame: .zero, pullsDown: false)

    var onPermissions: (() -> Void)?
    var onVocabulary: (() -> Void)?
    var onShowInApplications: (() -> Void)?
    var onModel: ((SelectedTranscriptionProfile) -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 350, height: 390)
        )
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.45)
            .cgColor
        view = background

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "mic.circle.fill",
            accessibilityDescription: "Luxit"
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)

        let title = NSTextField(labelWithString: "Luxit")
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [title, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let header = NSStackView(views: [icon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let grid = NSGridView(views: [
            metricRow(label: "Audio transcribed", value: hoursValue),
            metricRow(label: "Words", value: wordsValue),
            metricRow(label: "Dictations", value: dictationsValue),
            metricRow(label: "Average performance", value: performanceValue)
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        permissionsValue.font = .systemFont(ofSize: 11)
        permissionsValue.textColor = .secondaryLabelColor
        permissionsValue.maximumNumberOfLines = 2
        permissionsValue.lineBreakMode = .byWordWrapping

        let modelLabel = NSTextField(labelWithString: "Whisper model")
        modelLabel.font = .systemFont(ofSize: 12)
        modelLabel.textColor = .secondaryLabelColor
        modelControl.target = self
        modelControl.action = #selector(changeModel)
        modelControl.controlSize = .small
        modelControl.toolTip =
            "Models download from the official whisper.cpp repository on Hugging Face"
        let modelRow = NSStackView(views: [modelLabel, modelControl])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.distribution = .fill
        modelRow.spacing = 12

        let permissionsButton = makeButton(
            "Permissions",
            symbol: "hand.raised",
            action: #selector(openPermissions)
        )
        let vocabularyButton = makeButton(
            "Vocabulary",
            symbol: "text.book.closed",
            action: #selector(openVocabulary)
        )
        let settingsRow = NSStackView(views: [permissionsButton, vocabularyButton])
        settingsRow.orientation = .horizontal
        settingsRow.distribution = .fillEqually
        settingsRow.spacing = 8

        let showButton = makeButton(
            "Show App",
            symbol: "folder",
            action: #selector(showInApplications)
        )
        let restartButton = makeButton(
            "Restart",
            symbol: "arrow.clockwise",
            action: #selector(restart)
        )
        let quitButton = makeButton(
            "Quit",
            symbol: "power",
            action: #selector(quit)
        )
        let appRow = NSStackView(views: [showButton, restartButton, quitButton])
        appRow.orientation = .horizontal
        appRow.distribution = .fillEqually
        appRow.spacing = 8

        let content = NSStackView(views: [
            header,
            separator(),
            grid,
            separator(),
            modelRow,
            permissionsValue,
            settingsRow,
            appRow
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            grid.widthAnchor.constraint(equalTo: content.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            permissionsValue.widthAnchor.constraint(equalTo: content.widthAnchor),
            settingsRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            appRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func refresh(
        status: String,
        statistics: StatisticsSnapshot,
        accessibility: Bool,
        inputMonitoring: Bool,
        microphone: Bool,
        whisperModel: SelectedTranscriptionProfile,
        modelAvailabilities: [SelectedTranscriptionProfile: ModelAvailability],
        modelSelectionEnabled: Bool
    ) {
        statusLabel.stringValue = status
        hoursValue.stringValue = String(format: "%.2f h", statistics.audioSeconds / 3600)
        wordsValue.stringValue = statistics.words.formatted()
        dictationsValue.stringValue = statistics.dictations.formatted()
        if statistics.dictations == 0 {
            performanceValue.stringValue = "—"
        } else {
            performanceValue.stringValue = String(
                format: "%.1f× realtime · %.1fs avg",
                statistics.realtimeSpeed,
                statistics.averageLatency
            )
        }
        let checks = [
            accessibility ? "Accessibility ✓" : "Accessibility needed",
            inputMonitoring ? "Input Monitoring ✓" : "Input Monitoring needed",
            microphone ? "Microphone ✓" : "Microphone needed"
        ]
        permissionsValue.stringValue = checks.joined(separator: "   ")
        modelControl.removeAllItems()
        for model in SelectedTranscriptionProfile.rankedProfiles {
            let availability = modelAvailabilities[model] ?? .unavailable("Checking runtime...")
            let suffix = switch availability {
            case .available: "ready"
            case .unavailable:
                "unavailable"
            }
            modelControl.addItem(
                withTitle:
                    "\(model.shortName) · \(suffix)"
            )
            if let menuItem = modelControl.itemArray.last {
                menuItem.toolTip = reasonForAvailability(availability)
                menuItem.isEnabled =
                    modelSelectionEnabled &&
                    model.supportsLocalSelection &&
                    availability.isAvailable
            }
        }
        modelControl.selectItem(
            at: SelectedTranscriptionProfile.rankedProfiles.firstIndex(of: whisperModel) ?? 0
        )
        modelControl.isEnabled = modelSelectionEnabled
    }

    private func metricRow(label: String, value: NSTextField) -> [NSView] {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.alignment = .right
        return [name, value]
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func openPermissions() { onPermissions?() }
    @objc private func openVocabulary() { onVocabulary?() }
    @objc private func showInApplications() { onShowInApplications?() }
    @objc private func changeModel() {
        let index = modelControl.indexOfSelectedItem
        guard SelectedTranscriptionProfile.rankedProfiles.indices.contains(index) else { return }
        onModel?(SelectedTranscriptionProfile.rankedProfiles[index])
    }
    @objc private func restart() { onRestart?() }
    @objc private func quit() { onQuit?() }
}

private protocol TranscriptionBackend {
    var isReady: Bool { get }
    func load(
        profile: SelectedTranscriptionProfile,
        modelURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func unloadNow(completion: @escaping () -> Void)
    func unload(after seconds: TimeInterval)
    func transcribe(
        wavURL: URL,
        vadModelURL: URL,
        prompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    )
}

private final class WhisperCppEngine: TranscriptionBackend {
    private let queue = DispatchQueue(label: "com.joslack.luxit.inference", qos: .userInitiated)
    private var context: UnsafeMutableRawPointer?
    private var unloadWorkItem: DispatchWorkItem?
    private(set) var activeProfile: SelectedTranscriptionProfile?
    private(set) var isReady = false

    deinit {
        unloadWorkItem?.cancel()
        if let context {
            ew_whisper_free(context)
        }
    }

    func load(
        profile: SelectedTranscriptionProfile,
        modelURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil

            guard profile.whisperCppStrategy != nil else {
                DispatchQueue.main.async {
                    completion(.failure(ModelSelectionError.unsupportedProfile(profile.rawValue)))
                }
                return
            }

            if self.context != nil && self.activeProfile == profile {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            if self.context != nil {
                ew_whisper_free(self.context)
                self.context = nil
                self.isReady = false
            }

            guard let strategy = profile.whisperCppStrategy?.rawValue else {
                DispatchQueue.main.async {
                    completion(.failure(
                        ModelSelectionError.unsupportedProfile(profile.rawValue)
                    ))
                }
                return
            }
            ew_whisper_set_strategy(Int32(strategy))
            let loaded = modelURL.path.withCString { ew_whisper_load($0) }
            guard let loaded else {
                let message = String(cString: ew_whisper_last_error())
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                }
                return
            }
            self.context = loaded
            self.activeProfile = profile
            self.isReady = true
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func unloadNow(completion: @escaping () -> Void) {
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil
            if let context = self.context {
                ew_whisper_free(context)
                self.context = nil
            }
            self.isReady = false
            DispatchQueue.main.async(execute: completion)
        }
    }

    func unload(after seconds: TimeInterval) {
        queue.async {
            self.unloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard let context = self.context else { return }
                    ew_whisper_free(context)
                    self.context = nil
                    self.isReady = false
                    DiagnosticLog.write("Whisper model unloaded after idle timeout")
                }
            }
            self.unloadWorkItem = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + seconds,
                execute: workItem
            )
        }
    }

    func transcribe(
        wavURL: URL,
        vadModelURL: URL,
        prompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil
            guard let context = self.context else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The Whisper model is not ready."]
                    )))
                }
                return
            }

            let pointer = wavURL.path.withCString { wavPath in
                vadModelURL.path.withCString { vadPath in
                    prompt.withCString { promptValue in
                        ew_whisper_transcribe(
                            context,
                            wavPath,
                            promptValue,
                            vadPath
                        )
                    }
                }
            }
            guard let pointer else {
                let message = String(cString: ew_whisper_last_error())
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                }
                return
            }

            let transcript = String(cString: pointer)
            ew_whisper_string_free(pointer)
            DispatchQueue.main.async { completion(.success(transcript)) }
        }
    }
}

private final class ParakeetEngine: TranscriptionBackend {
    private let queue = DispatchQueue(label: "com.joslack.luxit.parakeet", qos: .userInitiated)
    private var context: UnsafeMutableRawPointer?
    private var unloadWorkItem: DispatchWorkItem?
    private(set) var activeProfile: SelectedTranscriptionProfile?
    private(set) var isReady = false
    private var threads = 4

    deinit {
        unloadWorkItem?.cancel()
        if let context {
            ew_parakeet_free(context)
        }
    }

    func load(
        profile: SelectedTranscriptionProfile,
        modelURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil

            guard profile.usesParakeetEngine else {
                DispatchQueue.main.async {
                    completion(.failure(ModelSelectionError.unsupportedProfile(profile.rawValue)))
                }
                return
            }

            if self.context != nil && self.activeProfile == profile {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            if self.context != nil {
                ew_parakeet_free(self.context)
                self.context = nil
                self.isReady = false
            }

            self.threads = max(1, profile.parakeetThreads)
            let loaded = ew_parakeet_load(
                modelURL.path,
                profile.parakeetLibraryPath,
                profile.parakeetUseGPU ? 1 : 0,
                0
            )
            guard let loaded else {
                let message = String(cString: ew_whisper_last_error())
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                }
                return
            }
            self.context = loaded
            self.activeProfile = profile
            self.isReady = true
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func unloadNow(completion: @escaping () -> Void) {
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil
            if let context = self.context {
                ew_parakeet_free(context)
                self.context = nil
            }
            self.activeProfile = nil
            self.isReady = false
            DispatchQueue.main.async(execute: completion)
        }
    }

    func unload(after seconds: TimeInterval) {
        queue.async {
            self.unloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.unloadNow { DiagnosticLog.write("Parakeet model unloaded after idle timeout") }
            }
            self.unloadWorkItem = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + seconds,
                execute: workItem
            )
        }
    }

    func transcribe(
        wavURL: URL,
        vadModelURL: URL,
        prompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        _ = prompt
        queue.async {
            self.unloadWorkItem?.cancel()
            self.unloadWorkItem = nil
            guard let context = self.context else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The Parakeet model is not ready."]
                    )))
                }
                return
            }

            let pointer = wavURL.path.withCString { wavPath in
                vadModelURL.path.withCString { vadPath in
                    ew_parakeet_transcribe(
                        context,
                        wavPath,
                        vadPath,
                        Int32(self.threads)
                    )
                }
            }
            guard let pointer else {
                let message = String(cString: ew_whisper_last_error())
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                }
                return
            }

            let transcript = String(cString: pointer)
            ew_whisper_string_free(pointer)
            DispatchQueue.main.async { completion(.success(transcript)) }
        }
    }
}

private final class TranscriptionEngine {
    private let queue = DispatchQueue(label: "com.joslack.luxit.inference", qos: .userInitiated)
    private let whisperEngine = WhisperCppEngine()
    private let parakeetEngine = ParakeetEngine()
    private var activeProfile: SelectedTranscriptionProfile?
    private var pressureEligibleAt: Date?
    private let memoryPressureSource: DispatchSourceMemoryPressure

    init() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        memoryPressureSource.setEventHandler { [weak self] in
            guard
                let self,
                let pressureEligibleAt = self.pressureEligibleAt,
                Date() >= pressureEligibleAt
            else {
                return
            }
            DiagnosticLog.write(
                "Memory pressure received after idle window; unloading transcription model"
            )
            self.unloadNow {}
        }
        memoryPressureSource.resume()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    private func backend(for profile: SelectedTranscriptionProfile) -> TranscriptionBackend {
        if profile.usesParakeetEngine {
            return parakeetEngine
        }
        return whisperEngine
    }

    var isReady: Bool {
        guard let activeProfile else { return false }
        return isReady(for: activeProfile)
    }

    func isReady(for profile: SelectedTranscriptionProfile) -> Bool {
        activeProfile == profile && backend(for: profile).isReady
    }

    func load(
        profile: SelectedTranscriptionProfile,
        modelURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            self.pressureEligibleAt = nil

            if self.activeProfile == profile {
                self.backend(for: profile).load(
                    profile: profile,
                    modelURL: modelURL,
                    completion: completion
                )
                return
            }

            guard let priorProfile = self.activeProfile else {
                self.activeProfile = profile
                self.loadBackend(
                    profile: profile,
                    modelURL: modelURL,
                    completion: completion
                )
                return
            }

            self.activeProfile = nil
            self.backend(for: priorProfile).unloadNow { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.activeProfile = profile
                    self.loadBackend(
                        profile: profile,
                        modelURL: modelURL,
                        completion: completion
                    )
                }
            }
        }
    }

    private func loadBackend(
        profile: SelectedTranscriptionProfile,
        modelURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        backend(for: profile).load(
            profile: profile,
            modelURL: modelURL
        ) { [weak self] result in
            if case .failure = result {
                self?.queue.async {
                    guard self?.activeProfile == profile else { return }
                    self?.activeProfile = nil
                }
            }
            completion(result)
        }
    }

    func unloadNow(completion: @escaping () -> Void) {
        queue.async {
            self.pressureEligibleAt = nil
            self.activeProfile = nil
            self.whisperEngine.unloadNow {
                self.parakeetEngine.unloadNow {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    func unload(after seconds: TimeInterval) {
        queue.async {
            self.pressureEligibleAt = Date().addingTimeInterval(seconds)
        }
    }

    func transcribe(
        profile: SelectedTranscriptionProfile,
        wavURL: URL,
        vadModelURL: URL,
        prompt: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            self.pressureEligibleAt = nil
            guard self.activeProfile == profile else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "Luxit",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The selected transcription model is not ready."
                        ]
                    )))
                }
                return
            }
            self.backend(for: profile).transcribe(
                wavURL: wavURL,
                vadModelURL: vadModelURL,
                prompt: prompt,
                completion: completion
            )
        }
    }
}

private final class CapsLockRemapper {
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"
    private static let capsLockUsage = UInt64(0x700000039)
    private static let f19Usage = UInt64(0x70000006E)

    private var originalMappings: [[String: NSNumber]]?

    /// Maps Caps Lock to F19 below the Quartz event layer. macOS applies
    /// accidental-keystroke prevention to Caps Lock itself; an ordinary F19
    /// key-down arrives immediately and has no capitalization state or LED.
    func install() -> Bool {
        guard let current = readMappings() else {
            DiagnosticLog.write("Caps Lock HID remap query failed; using Quartz fallback")
            return false
        }

        if originalMappings == nil {
            let alreadyOwnedByLuxit = current.contains { mapping in
                sourceUsage(in: mapping) == Self.capsLockUsage &&
                    destinationUsage(in: mapping) == Self.f19Usage
            }
            originalMappings = alreadyOwnedByLuxit
                ? current.filter { sourceUsage(in: $0) != Self.capsLockUsage }
                : current
        }

        var desired = current.filter {
            sourceUsage(in: $0) != Self.capsLockUsage
        }
        desired.append([
            Self.sourceKey: NSNumber(value: Self.capsLockUsage),
            Self.destinationKey: NSNumber(value: Self.f19Usage)
        ])
        let written = writeMappings(desired)
        let installed = written && readMappings()?.contains { mapping in
            sourceUsage(in: mapping) == Self.capsLockUsage &&
                destinationUsage(in: mapping) == Self.f19Usage
        } == true
        DiagnosticLog.write(
            installed
                ? "Caps Lock remapped and verified as immediate F19 HID event"
                : "Caps Lock HID remap write or verification failed; using Quartz fallback"
        )
        return installed
    }

    func restore() {
        guard let originalMappings else { return }
        if writeMappings(originalMappings) {
            DiagnosticLog.write("Original HID key mappings restored")
        } else {
            DiagnosticLog.write("Original HID key mappings could not be restored")
        }
    }

    private func sourceUsage(in mapping: [String: NSNumber]) -> UInt64? {
        mapping[Self.sourceKey]?.uint64Value
    }

    private func destinationUsage(in mapping: [String: NSNumber]) -> UInt64? {
        mapping[Self.destinationKey]?.uint64Value
    }

    private func readMappings() -> [[String: NSNumber]]? {
        let result = runHIDUtil(["property", "--get", "UserKeyMapping"])
        guard result.status == 0 else {
            DiagnosticLog.write(
                "hidutil get failed status=\(result.status) " +
                "output=\(loggableOutput(result.output))"
            )
            return nil
        }
        guard let output = String(data: result.output, encoding: .utf8) else {
            DiagnosticLog.write("hidutil get returned non-UTF8 output")
            return nil
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "(null)" {
            return []
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: result.output,
            options: [],
            format: nil
        ) else {
            DiagnosticLog.write(
                "hidutil get returned unparseable output=\(loggableOutput(result.output))"
            )
            return nil
        }
        guard let rawMappings = propertyList as? [[String: Any]] else {
            DiagnosticLog.write(
                "hidutil get returned unexpected property-list type"
            )
            return nil
        }
        var mappings: [[String: NSNumber]] = []
        for rawMapping in rawMappings {
            var mapping: [String: NSNumber] = [:]
            for key in [Self.sourceKey, Self.destinationKey] {
                if let number = rawMapping[key] as? NSNumber {
                    mapping[key] = number
                } else if let string = rawMapping[key] as? String,
                          let value = UInt64(string) {
                    // OpenStep property lists represent these 64-bit HID usage
                    // values as strings on current macOS.
                    mapping[key] = NSNumber(value: value)
                } else {
                    DiagnosticLog.write(
                        "hidutil mapping contained an invalid \(key) value"
                    )
                    return nil
                }
            }
            mappings.append(mapping)
        }
        return mappings
    }

    private func writeMappings(_ mappings: [[String: NSNumber]]) -> Bool {
        guard JSONSerialization.isValidJSONObject(mappings),
              let data = try? JSONSerialization.data(
                withJSONObject: ["UserKeyMapping": mappings]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        let result = runHIDUtil(["property", "--set", json])
        if result.status != 0 {
            DiagnosticLog.write(
                "hidutil set failed status=\(result.status) " +
                "output=\(loggableOutput(result.output))"
            )
        }
        return result.status == 0
    }

    private func loggableOutput(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        return String(
            raw
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(240)
        )
    }

    private func runHIDUtil(_ arguments: [String]) -> (
        status: Int32,
        output: Data
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                output.fileHandleForReading.readDataToEndOfFile()
            )
        } catch {
            return (-1, Data())
        }
    }
}

private final class GlobalCapsLock {
    struct PressTiming {
        let hardwareEventUptimeNanoseconds: UInt64
        let callbackUptimeNanoseconds: UInt64
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let remapper = CapsLockRemapper()
    private(set) var immediateMappingActive = false
    var onPress: ((PressTiming) -> Void)?

    var isListening: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// Input Monitoring has no dependable callback-based status API. A live
    /// hotkey tap is the strongest signal; otherwise probe with a temporary
    /// HID listen-only tap, matching the approach used by established macOS
    /// dictation apps.
    func hasInputMonitoringAccess() -> Bool {
        if isListening {
            return true
        }

        let probe = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let probe else { return false }
        CFMachPortInvalidate(probe)
        return true
    }

    func start() -> Bool {
        if isListening {
            return true
        }
        invalidateEventTap()
        let mask =
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let owner = Unmanaged<GlobalCapsLock>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                DispatchQueue.main.async {
                    DiagnosticLog.write("Keyboard event tap re-enabled from disabled callback")
                }
                return Unmanaged.passUnretained(event)
            }

            let disposition = CapsLockEventClassifier.classify(
                type: type,
                keyCode: event.getIntegerValueField(.keyboardEventKeycode)
            )
            switch disposition {
            case .toggleAndConsume:
                // This source is installed on the main run loop. Handle the
                // toggle now instead of adding an avoidable queue turn.
                owner.onPress?(PressTiming(
                    hardwareEventUptimeNanoseconds: event.timestamp,
                    callbackUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                ))
                return nil
            case .consume:
                return nil
            case .passThrough:
                // Caps Lock is dedicated to dictation. Strip Alpha Shift from
                // every ordinary keyboard event so it never capitalizes text,
                // even while the physical Caps LED/state is on for recording.
                var flags = event.flags
                flags.remove(.maskAlphaShift)
                event.flags = flags
                return Unmanaged.passUnretained(event)
            }
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func recreate() -> Bool {
        invalidateEventTap()
        prepareBeforeListening()
        let recreated = start()
        DiagnosticLog.write(
            recreated
                ? "Keyboard event tap recreated"
                : "Keyboard event tap recreation failed"
        )
        return recreated
    }

    func retryImmediateMapping() -> Bool {
        immediateMappingActive = remapper.install()
        return immediateMappingActive
    }

    /// Establish a known initial Caps state before the event tap exists.
    /// Runtime recording transitions never call IOHID, so they cannot feed
    /// synthetic Caps events back into the listener.
    func prepareBeforeListening() {
        immediateMappingActive = remapper.install()
        let cleared = ew_set_caps_lock_led(0) != 0
        DiagnosticLog.write("Initial Caps Lock state cleared result=\(cleared)")
    }

    func stop() {
        invalidateEventTap()
        remapper.restore()
        immediateMappingActive = false
        _ = ew_set_caps_lock_led(0)
    }

    private func invalidateEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

private final class AppDelegate:
    NSObject,
    NSApplicationDelegate,
    NSMenuDelegate
{
    private let recorder = AudioRecorder()
    private let transcriptionEngine = TranscriptionEngine()
    private let capsLock = GlobalCapsLock()
    private let indicator = EdgeIndicator()
    private let statistics = StatisticsStore()
    private let audioPreparationQueue = DispatchQueue(
        label: "com.joslack.luxit.audio-preparation",
        qos: .userInitiated
    )
    private let statusMenu = NSMenu()
    private let statusSummaryItem = NSMenuItem()
    private let usageAudioItem = NSMenuItem()
    private let usagePerformanceItem = NSMenuItem()
    private let modelRootItem = NSMenuItem()
    private let modelMenu = NSMenu()
    private let permissionsItem = NSMenuItem()
    private var modelMenuItems: [SelectedTranscriptionProfile: NSMenuItem] = [:]
    private var state: DictationState = .idle
    private var pendingTranscriptions = 0
    private var nextJobID = 1
    private let maximumPendingTranscriptions = 3
    private var statusItem: NSStatusItem!
    private var permissionsTimer: Timer?
    private var statusText = "Ready — model loads when recording starts"
    private var keyboardReady = false
    private var exitRequested = false
    private var keyboardRecoveryGeneration = 0
    private var selectedModel = SelectedTranscriptionProfile.saved
    private var pendingModelActivation: SelectedTranscriptionProfile?
    private let modelIdleTimeoutSeconds: TimeInterval = 10 * 60
    private let keyboardRecoveryDelays: [TimeInterval] = [
        0.35, 0.75, 1.5, 3.0, 6.0
    ]

    private let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeWhisper")
    private var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("Models")
    }
    private var selectedModelURL: URL? {
        modelURL(for: selectedModel)
    }
    private var vadModelURL: URL {
        supportDirectory
            .appendingPathComponent("Models")
            .appendingPathComponent("ggml-silero-v6.2.0.bin")
    }
    private var promptURL: URL {
        supportDirectory.appendingPathComponent("prompt.txt")
    }

    private func modelURL(for model: SelectedTranscriptionProfile) -> URL? {
        guard let path = model.modelPathHint(fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.write("App launched")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        createDefaultPrompt()
        checkPermissionsAndStartShortcut(prompt: false)
        verifyModel()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.indicator.screenParametersChanged()
        }

        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in workspaceNotifications {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleKeyboardRecovery(reason: name.rawValue)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        capsLock.stop()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        requestExit(restart: false)
        return .terminateCancel
    }

    private func scheduleKeyboardRecovery(reason: String) {
        keyboardRecoveryGeneration += 1
        let generation = keyboardRecoveryGeneration
        DiagnosticLog.write("Keyboard recovery scheduled reason=\(reason)")
        runKeyboardRecovery(generation: generation, attempt: 0)
    }

    private func runKeyboardRecovery(generation: Int, attempt: Int) {
        guard attempt < keyboardRecoveryDelays.count else { return }
        let delay = keyboardRecoveryDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.keyboardRecoveryGeneration else {
                return
            }

            if attempt == 0 {
                self.indicator.rebuildPanels()
                self.keyboardReady = self.capsLock.recreate()
            } else {
                _ = self.capsLock.retryImmediateMapping()
                if !self.capsLock.isListening {
                    self.keyboardReady = self.capsLock.start()
                }
            }

            if self.capsLock.immediateMappingActive {
                DiagnosticLog.write(
                    "Keyboard recovery succeeded attempt=\(attempt + 1)"
                )
                return
            }

            let nextAttempt = attempt + 1
            if nextAttempt < self.keyboardRecoveryDelays.count {
                DiagnosticLog.write(
                    "Keyboard recovery retrying attempt=\(nextAttempt + 1)"
                )
                self.runKeyboardRecovery(
                    generation: generation,
                    attempt: nextAttempt
                )
            } else {
                DiagnosticLog.write(
                    "Keyboard recovery exhausted; Quartz fallback remains active"
                )
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.joslack.luxit.statusItem"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.circle.fill",
                accessibilityDescription: "Luxit"
            )
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Luxit — click for stats and controls"
        }

        configureStatusMenu()
        statusItem.menu = statusMenu
        refreshStatusMenu()
    }

    private func configureStatusMenu() {
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        statusMenu.addItem(.sectionHeader(title: "Luxit"))
        statusSummaryItem.isEnabled = false
        statusMenu.addItem(statusSummaryItem)
        statusMenu.addItem(.separator())

        statusMenu.addItem(.sectionHeader(title: "Usage"))
        usageAudioItem.isEnabled = false
        usagePerformanceItem.isEnabled = false
        statusMenu.addItem(usageAudioItem)
        statusMenu.addItem(usagePerformanceItem)
        statusMenu.addItem(.separator())

        modelRootItem.submenu = modelMenu
        statusMenu.addItem(modelRootItem)
        for model in SelectedTranscriptionProfile.rankedProfiles {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectModelMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.rawValue
            modelMenu.addItem(item)
            modelMenuItems[model] = item
        }

        statusMenu.addItem(.separator())

        permissionsItem.title = "Permissions"
        permissionsItem.target = self
        permissionsItem.action = #selector(openPermissionsMenuItem)
        statusMenu.addItem(permissionsItem)
        statusMenu.addItem(menuItem(
            title: "Vocabulary",
            action: #selector(openVocabularyMenuItem)
        ))
        statusMenu.addItem(menuItem(
            title: "Show Luxit in Applications",
            action: #selector(showInApplicationsMenuItem)
        ))
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem(
            title: "Restart Luxit",
            action: #selector(restartMenuItem)
        ))
        statusMenu.addItem(menuItem(
            title: "Quit Luxit",
            action: #selector(quitMenuItem)
        ))
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showPopover() {
        refreshStatusMenu()
        statusItem.button?.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        refreshStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        DiagnosticLog.write("Native status menu opened")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        DiagnosticLog.write("Native status menu closed")
    }

    @objc private func selectModelMenuItem(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let model = SelectedTranscriptionProfile(rawValue: rawValue)
        else { return }
        selectModel(model)
    }

    @objc private func openPermissionsMenuItem() { openPermissions() }
    @objc private func openVocabularyMenuItem() { openPrompt() }
    @objc private func showInApplicationsMenuItem() { showInApplications() }
    @objc private func restartMenuItem() { requestExit(restart: true) }
    @objc private func quitMenuItem() { requestExit(restart: false) }

    private func selectModel(_ model: SelectedTranscriptionProfile) {
        guard model != selectedModel else {
            refreshStatusMenu()
            return
        }
        guard state == .idle, pendingTranscriptions == 0 else {
            setStatus(
                "Finish the current dictation before switching models",
                symbol: "clock.fill"
            )
            return
        }
        let availability = model.availability(
            fileExists: { path in
                FileManager.default.fileExists(atPath: path)
            },
            commandExists: commandExists
        )
        guard availability.isAvailable && model.supportsLocalSelection else {
            setStatus(
                "Cannot select \(model.shortName): \(reasonForAvailability(availability))",
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }

        guard (model.modelPathHint(fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        })) != nil else {
            setStatus(
                "Model file missing for \(model.shortName)",
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }

        activateModel(model)
    }

    private func activateModel(_ model: SelectedTranscriptionProfile) {
        guard state == .idle, pendingTranscriptions == 0 else {
            pendingModelActivation = model
            return
        }
        pendingModelActivation = model
        selectedModel = model
        model.save()
        setStatus(
            "Switching to \(model.shortName)…",
            symbol: "arrow.triangle.2.circlepath"
        )
        transcriptionEngine.unloadNow { [weak self] in
            guard let self else { return }
            self.pendingModelActivation = nil
            self.setStatus(
                "Ready · \(model.shortName) loads on first recording",
                symbol: "mic.circle.fill"
            )
            DiagnosticLog.write("Model selected model=\(model.rawValue)")
        }
    }

    private func createDefaultPrompt() {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: promptURL.path) {
                let prompt = """
                Accurate English dictation with natural punctuation. Preserve names, technical terms, and numbers exactly.
                Add personal names, company names, acronyms, and specialized vocabulary below:
                """
                try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Luxit could not create its support directory: \(error.localizedDescription)")
        }
    }

    private func verifyModel() {
        if selectedModelURL == nil {
            let fallbackURL = modelURL(for: .whisperCppGreedy)
            if let fallbackURL,
               FileManager.default.fileExists(atPath: fallbackURL.path) {
                selectedModel = .whisperCppGreedy
                selectedModel.save()
            }
        }
        guard let selectedModelURL,
              FileManager.default.fileExists(atPath: selectedModelURL.path) else {
            setStatus(
                "Model missing — choose one from the Luxit menu",
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }
        guard FileManager.default.fileExists(atPath: vadModelURL.path) else {
            setStatus(
                "Voice detector missing — run install.sh",
                symbol: "exclamationmark.triangle.fill"
            )
            return
        }
        setStatus(
            keyboardReady
                ? "Ready · \(selectedModel.shortName) loads when recording starts"
                : "Ready — keyboard permissions needed",
            symbol: keyboardReady ? "mic.circle.fill" : "exclamationmark.triangle.fill"
        )
        DiagnosticLog.write(
            "Whisper model available model=\(selectedModel.rawValue)"
        )
    }

    private func checkPermissionsAndStartShortcut(prompt: Bool) {
        let accessibilityTrusted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary
            accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibilityTrusted = AXIsProcessTrusted()
        }

        if prompt {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                recorder.requestPermission()
            }
            if !capsLock.hasInputMonitoringAccess() {
                _ = CGRequestListenEventAccess()
            }
        }

        recorder.prepareIfAuthorized()
        capsLock.onPress = { [weak self] timing in
            self?.toggleDictation(timing: timing)
        }
        // The event tap itself is the source of truth. Preflight APIs can stay
        // false after a permission change until process restart, while a newly
        // created tap accurately reports whether the listener can operate.
        if !capsLock.isListening {
            capsLock.prepareBeforeListening()
        }
        let started = capsLock.start()
        let inputMonitoringTrusted = capsLock.hasInputMonitoringAccess()
        keyboardReady = started
        if !started {
            setStatus("Permissions needed — click the menu-bar icon", symbol: "exclamationmark.triangle.fill")
        }
        DiagnosticLog.write(
            "Permissions accessibility=\(accessibilityTrusted) " +
            "inputMonitoring=\(inputMonitoringTrusted) eventTap=\(started)"
        )
        if started {
            permissionsTimer?.invalidate()
            permissionsTimer = nil
            if !capsLock.immediateMappingActive {
                scheduleKeyboardRecovery(reason: "initial HID remap verification")
            }
        } else if permissionsTimer == nil {
            permissionsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) {
                [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.capsLock.start() {
                    self.keyboardReady = true
                    self.setStatus(
                        "Ready — model loads when recording starts",
                        symbol: "mic.circle.fill"
                    )
                    DiagnosticLog.write("Keyboard event tap became active")
                    timer.invalidate()
                    self.permissionsTimer = nil
                }
            }
        }
    }

    private func openPrompt() {
        NSWorkspace.shared.open(promptURL)
    }

    private func openPermissions() {
        checkPermissionsAndStartShortcut(prompt: true)
        let pane: String
        if !capsLock.hasInputMonitoringAccess() {
            pane = "Privacy_ListenEvent"
        } else if !AXIsProcessTrusted() {
            pane = "Privacy_Accessibility"
        } else {
            pane = "Privacy_Microphone"
        }
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInApplications() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: "/Applications/Luxit.app")
        ])
    }

    private func requestExit(restart: Bool) {
        guard !exitRequested else { return }
        exitRequested = true
        statusMenu.cancelTrackingWithoutAnimation()
        if state == .recording, let recorded = recorder.stop() {
            try? FileManager.default.removeItem(at: recorded.url)
            state = .idle
        }
        capsLock.stop()

        if restart {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", "/Applications/Luxit.app"]
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(
                        domain: "Luxit",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The open command exited with status " +
                                "\(process.terminationStatus)."
                        ]
                    )
                }
            } catch {
                exitRequested = false
                setStatus(
                    "Could not restart: \(error.localizedDescription)",
                    symbol: "exclamationmark.triangle.fill"
                )
                _ = capsLock.retryImmediateMapping()
                _ = capsLock.start()
                return
            }
        }

        DiagnosticLog.write(restart ? "Restart requested" : "Quit requested")
        // ggml's dynamically loaded Metal backend can abort in its global C++
        // destructor while its residency worker is alive. All user-visible
        // state is synchronously restored above; _exit lets the kernel reclaim
        // inference resources without running that unsafe global teardown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Darwin._exit(0)
        }
    }

    private func setStatus(_ text: String, symbol: String) {
        statusText = text
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: text
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Luxit — \(text)"
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let snapshot = statistics.snapshot
        let displayedModel =
            pendingModelActivation ?? selectedModel
        let modelSelectionEnabled =
            pendingModelActivation == nil &&
            state == .idle &&
            pendingTranscriptions == 0

        statusSummaryItem.title = statusText
        statusSummaryItem.subtitle = displayedModel.displayName

        usageAudioItem.title = String(
            format: "%.2f hours transcribed",
            snapshot.audioSeconds / 3600
        )
        usageAudioItem.subtitle =
            "\(snapshot.words.formatted()) words · " +
            "\(snapshot.dictations.formatted()) dictations"

        if snapshot.dictations == 0 {
            usagePerformanceItem.title = "No completed dictations"
            usagePerformanceItem.subtitle = "Performance appears after the first transcription"
        } else {
            usagePerformanceItem.title = String(
                format: "%.1f× realtime",
                snapshot.realtimeSpeed
            )
            usagePerformanceItem.subtitle = String(
                format: "%.1fs average transcription time",
                snapshot.averageLatency
            )
        }

        modelRootItem.title = "Transcription Model"
        modelRootItem.subtitle = displayedModel.displayName
        modelRootItem.isEnabled = true
        for model in SelectedTranscriptionProfile.rankedProfiles {
            guard let item = modelMenuItems[model] else { continue }
            let availability = model.availability(
                fileExists: {
                    FileManager.default.fileExists(atPath: $0)
                },
                commandExists: commandExists
            )
            item.title = model.displayName
            item.subtitle =
                "\(model.warmHint) · \(reasonForAvailability(availability))"
            item.toolTip =
                "\(model.recommendationLabel)\n\(model.runtimeLifecycle)"
            item.state = model == displayedModel ? .on : .off
            item.isEnabled =
                modelSelectionEnabled &&
                model.supportsLocalSelection &&
                availability.isAvailable
        }

        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = capsLock.hasInputMonitoringAccess()
        permissionsItem.subtitle = [
            accessibility ? "Accessibility ✓" : "Accessibility needed",
            inputMonitoring ? "Input Monitoring ✓" : "Input Monitoring needed",
            microphone ? "Microphone ✓" : "Microphone needed"
        ].joined(separator: " · ")
    }

    private func toggleDictation(timing: GlobalCapsLock.PressTiming) {
        // A standard NSMenu runs a nested tracking loop. The global event tap
        // is installed in common run-loop modes, so Caps Lock still arrives
        // here; dismiss the menu synchronously before changing recorder state.
        statusMenu.cancelTrackingWithoutAnimation()
        let handlerUptime = DispatchTime.now().uptimeNanoseconds
        let hardwareToCallbackMilliseconds: Double
        if timing.callbackUptimeNanoseconds >= timing.hardwareEventUptimeNanoseconds {
            hardwareToCallbackMilliseconds = Double(
                timing.callbackUptimeNanoseconds - timing.hardwareEventUptimeNanoseconds
            ) / 1_000_000
        } else {
            hardwareToCallbackMilliseconds = -1
        }
        let callbackToHandlerMilliseconds = Double(
            handlerUptime - timing.callbackUptimeNanoseconds
        ) / 1_000_000
        DiagnosticLog.write(
            "Caps Lock received recording=\(state == .recording) " +
            "pending=\(pendingTranscriptions) " +
            String(
                format: "hardware-to-callback=%.1fms callback-to-handler=%.1fms",
                hardwareToCallbackMilliseconds,
                callbackToHandlerMilliseconds
            )
        )
        switch state {
        case .idle:
            startRecording()
        case .recording:
            finishRecording()
        }
    }

    private func startRecording() {
        guard pendingTranscriptions < maximumPendingTranscriptions else {
            setStatus(
                "Transcription queue full (\(maximumPendingTranscriptions)) — try again shortly",
                symbol: "exclamationmark.triangle.fill"
            )
            indicator.show(.processing)
            DiagnosticLog.write(
                "Recording not started: transcription queue full " +
                "(\(pendingTranscriptions))"
            )
            NSSound.beep()
            return
        }

        state = .recording
        indicator.show(.recording)
        setStatus(
            recordingStatusText(),
            symbol: "record.circle.fill"
        )
        DiagnosticLog.write("Recording start acknowledged")

        do {
            try recorder.start { [weak self] level, spectrum in
                self?.indicator.setAudioLevel(level, spectrum: spectrum)
            }
            DiagnosticLog.write("Recording started")
            guard let modelURL = selectedModelURL else {
                setStatus(
                    "Model missing — choose one from the Luxit menu",
                    symbol: "exclamationmark.triangle.fill"
                )
                indicator.show(.error)
                state = .idle
                return
            }
            transcriptionEngine.load(profile: selectedModel, modelURL: modelURL) {
                [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    DiagnosticLog.write("Model loaded")
                    if self.state == .recording {
                        self.setStatus(
                            self.recordingStatusText(),
                            symbol: "record.circle.fill"
                        )
                    }
                case .failure(let error):
                    self.setStatus(
                        "Model error: \(error.localizedDescription)",
                        symbol: "exclamationmark.triangle.fill"
                    )
                    self.indicator.show(.error)
                    DiagnosticLog.write("Model error: \(error.localizedDescription)")
                }
            }
        } catch {
            state = .idle
            setStatus(
                "Microphone error: \(error.localizedDescription)",
                symbol: "exclamationmark.triangle.fill"
            )
            indicator.show(.error)
            NSSound.beep()
        }
    }

    private func finishRecording() {
        guard let recorded = recorder.stop() else {
            state = .idle
            refreshActivityUI(recordingEndedWithoutSpeech: true)
            return
        }
        state = .idle

        let peakDB = 20 * log10(max(recorded.peakLevel, 0.000_001))
        DiagnosticLog.write(
            String(
                format: "Recording captured duration=%.2fs peak=%.1fdBFS voiced=%.2fs",
                recorded.duration,
                peakDB,
                recorded.voicedSeconds
            )
        )

        if recorded.isLikelySilent {
            try? FileManager.default.removeItem(at: recorded.url)
            DiagnosticLog.write("Recording discarded: no speech detected")
            refreshActivityUI(
                idleMessage: "No speech detected — ready",
                recordingEndedWithoutSpeech: true
            )
            if pendingTranscriptions == 0 {
                transcriptionEngine.unload(after: modelIdleTimeoutSeconds)
            }
            return
        }

        let cafURL = recorded.url
        let processingStartedAt = Date()
        let jobID = nextJobID
        nextJobID += 1
        pendingTranscriptions += 1
        refreshActivityUI()
        DiagnosticLog.write(
            "Recording stopped; transcription job \(jobID) queued " +
            "(pending=\(pendingTranscriptions))"
        )

        audioPreparationQueue.async { [weak self] in
            guard let self else { return }
            let wavURL = cafURL.deletingPathExtension().appendingPathExtension("wav")
            do {
                try self.convertToWhisperWAV(cafURL: cafURL, wavURL: wavURL)
                let prompt = (try? String(contentsOf: self.promptURL, encoding: .utf8)) ?? ""
                self.transcriptionEngine.transcribe(
                    profile: self.selectedModel,
                    wavURL: wavURL,
                    vadModelURL: self.vadModelURL,
                    prompt: prompt
                ) { [weak self] result in
                    try? FileManager.default.removeItem(at: cafURL)
                    try? FileManager.default.removeItem(at: wavURL)
                    self?.finishTranscription(
                        result,
                        jobID: jobID,
                        audioDuration: recorded.duration,
                        processingStartedAt: processingStartedAt
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: cafURL)
                try? FileManager.default.removeItem(at: wavURL)
                DispatchQueue.main.async { [weak self] in
                    self?.finishTranscription(
                        .failure(error),
                        jobID: jobID,
                        audioDuration: recorded.duration,
                        processingStartedAt: processingStartedAt
                    )
                }
            }
        }
    }

    private func convertToWhisperWAV(cafURL: URL, wavURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            cafURL.path,
            wavURL.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "Audio conversion failed."
            throw NSError(
                domain: "Luxit",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: detail.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    private func finishTranscription(
        _ result: Result<String, Error>,
        jobID: Int,
        audioDuration: TimeInterval,
        processingStartedAt: Date
    ) {
        pendingTranscriptions = max(0, pendingTranscriptions - 1)
        var errorMessage: String?
        switch result {
        case .success(let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                statistics.record(
                    audioSeconds: audioDuration,
                    processingSeconds: Date().timeIntervalSince(processingStartedAt),
                    text: text
                )
                let insertionText = text + " "
                pasteAtCursor(insertionText)
                DiagnosticLog.write(
                    "Transcription job \(jobID) inserted " +
                    "(\(insertionText.count) characters including trailing space)"
                )
            } else {
                DiagnosticLog.write("Transcription job \(jobID) returned empty text")
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            DiagnosticLog.write(
                "Transcription job \(jobID) error: \(error.localizedDescription)"
            )
            NSSound.beep()
        }

        if let errorMessage, state == .idle, pendingTranscriptions == 0 {
            indicator.show(.error)
            setStatus(
                "Transcription error: \(errorMessage)",
                symbol: "exclamationmark.triangle.fill"
            )
        } else {
            refreshActivityUI()
        }

        if state == .idle && pendingTranscriptions == 0 {
            transcriptionEngine.unload(after: modelIdleTimeoutSeconds)
        }
    }

    private func recordingStatusText() -> String {
        let modelStatus = transcriptionEngine.isReady(for: selectedModel) ? "" : " · loading model"
        let queueStatus = pendingTranscriptions > 0
            ? " · \(pendingTranscriptions) transcribing"
            : ""
        return "Recording…\(modelStatus)\(queueStatus)"
    }

    private func refreshActivityUI(
        idleMessage: String? = nil,
        recordingEndedWithoutSpeech: Bool = false
    ) {
        if state == .recording {
            indicator.show(.recording)
            setStatus(recordingStatusText(), symbol: "record.circle.fill")
        } else if pendingTranscriptions > 0 {
            indicator.show(.processing)
            let noun = pendingTranscriptions == 1 ? "transcription" : "transcriptions"
            setStatus(
                "\(pendingTranscriptions) \(noun) processing — Caps Lock starts the next recording",
                symbol: "ellipsis.circle.fill"
            )
        } else {
            if recordingEndedWithoutSpeech {
                indicator.completeRecording()
            } else {
                indicator.complete()
            }
            if let pendingModelActivation {
                activateModel(pendingModelActivation)
                return
            }
            setStatus(
                idleMessage ?? "Ready — Caps Lock to dictate",
                symbol: "mic.circle.fill"
            )
        }
    }

    private func pasteAtCursor(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let edgeWhisperChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if pasteboard.changeCount == edgeWhisperChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
