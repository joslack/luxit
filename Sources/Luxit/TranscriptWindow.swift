import AppKit
import SwiftUI
import QuartzCore

final class RecordingMeterModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
}

struct LuxitModelOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let available: Bool
}

final class LuxitSettingsModel: ObservableObject {
    @Published var models: [LuxitModelOption] = []
    @Published var selectedModelID = ""
    @Published var selectedModelName = ""
    @Published var canSelectModel = true
    @Published var permissions = ""
    @Published var usage = ""
    @Published var performance = ""
    var onSelectModel: ((String) -> Void)?
    var onPermissions: (() -> Void)?
    var onVocabulary: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?
}

final class TranscriptWindowModel: ObservableObject {
    @Published var entries: [TranscriptEntry] = []
    @Published var selectedID: UUID?
    @Published var selectedTab = 0
    @Published var activeRecordingID: UUID?
    @Published var recording = false
    @Published var paused = false
    @Published var busy = false
    let meter = RecordingMeterModel()
    let settings = LuxitSettingsModel()
    @Published var showingSettings = false
    @Published var message = "Caps Lock to dictate · Record to capture computer + microphone"
    @Published var error: String?
    var onDismiss: (() -> Void)?
    var onSettings: (() -> Void)?
    var onRecord: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onRetry: ((UUID) -> Void)?
}

private final class TranscriptHostingView: NSHostingView<TranscriptWindowView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    var onDismiss: (() -> Void)?
}

final class TranscriptWindowController: NSWindowController {
    private var animationGeneration = 0

    init(model: TranscriptWindowModel) {
        let panel = TranscriptPanel(contentRect: NSRect(origin: .zero, size: TranscriptPanelLayout.size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Luxit Transcripts"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hostingView = TranscriptHostingView(rootView: TranscriptWindowView(model: model))
        // Tab contents must never resize the host window or displace hit targets.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        super.init(window: panel)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        model.onDismiss = { [weak self] in self?.dismiss() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        animationGeneration += 1
        if window.isVisible, window.alphaValue > 0.99 { window.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frame = TranscriptPanelLayout.frame(in: screen.visibleFrame)
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame.offsetBy(dx: 0, dy: reducedMotion ? 0 : 22), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0.1 : 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let window, window.isVisible else { return }
        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: 14), display: true)
            }
        } completionHandler: { [weak self] in
            guard self?.animationGeneration == generation else { return }
            window.orderOut(nil)
        }
    }

    func toggle() {
        if window?.isVisible == true, window?.alphaValue == 1 { dismiss() } else { present() }
    }
}

struct TranscriptWindowView: View {
    @ObservedObject var model: TranscriptWindowModel
    private var tab: Int { get { model.selectedTab } nonmutating set { model.selectedTab = newValue } }
    @State private var query = ""
    @State private var copied = false
    @State private var confirmingDelete = false

    private var selection: TranscriptEntry? {
        model.entries.first { $0.id == model.selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.showingSettings {
                    Button { model.showingSettings = false } label: {
                        Label("Settings", systemImage: "chevron.left")
                    }.buttonStyle(.plain).font(.system(size: 14, weight: .semibold))
                        .help("Back to transcripts")
                } else {
                    RecordingMeterView(meter: model.meter, recording: model.recording, paused: model.paused)
                }
                Spacer()
                if model.recording {
                    Button(model.paused ? "Resume" : "Pause") { model.onPause?() }
                        .disabled(model.busy)
                    Button("Stop") { model.onStop?() }.disabled(model.busy)
                } else {
                    Button { model.onRecord?() } label: {
                        Label("Record", systemImage: "record.circle")
                    }.disabled(model.busy)
                        .help("Record computer audio and your microphone")
                }
                if !model.showingSettings {
                    Button("Settings", systemImage: "gearshape") { model.onSettings?() }
                        .labelStyle(.iconOnly).help("Models, permissions, and settings")
                }
                Button("Dismiss", systemImage: "chevron.up") { model.onDismiss?() }
                    .labelStyle(.iconOnly).help("Hide panel (Escape)")
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)

            if !model.showingSettings {
                HStack(spacing: 4) {
                    ForEach(0..<2) { index in
                        Button {
                            tab = index
                        } label: {
                            Text(index == 0 ? "History" : "Transcript")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(tab == index ? Color.white.opacity(0.13) : .clear, in: Capsule())
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(tab == index ? .isSelected : [])
                    }
                }.padding(4).background(.white.opacity(0.035), in: Capsule())
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }

            if model.showingSettings {
                LuxitSettingsView(model: model.settings)
            } else if tab == 0 {
                history
            } else if let entry = selection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(entry.source.title) · \(clock(entry.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.displayText, forType: .string)
                            copied = true
                        }
                        if entry.recordingState == .failed {
                            Button("Retry", systemImage: "arrow.clockwise") { model.onRetry?(entry.id) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .labelStyle(.iconOnly).disabled(entry.recordingState?.inProgress == true || entry.id == model.activeRecordingID)
                    }
                    TranscriptTextView(entry: entry, paused: model.paused).id(entry.id)
                }.padding(.horizontal, 18).padding(.bottom, 12)
            } else {
                empty("Your transcript", detail: model.recording
                      ? "Your transcript grows here as you speak."
                      : "Choose a transcript from History, or make a recording.")
            }

            HStack(spacing: 8) {
                Image(systemName: model.error == nil ? "lock.shield" : "exclamationmark.circle")
                Text(model.error ?? model.message).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(model.error == nil ? Color.secondary : .orange)
                .padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(red: 0.035, green: 0.04, blue: 0.065),
                                            Color(red: 0.075, green: 0.11, blue: 0.19)],
                                   startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        .preferredColorScheme(.dark)
        .onChange(of: model.selectedID) { _, _ in copied = false }
        .confirmationDialog("Delete this transcript from this Mac?", isPresented: $confirmingDelete) {
            Button("Delete transcript", role: .destructive) {
                if let id = model.selectedID { model.onDelete?(id) }
            }
        }
    }

    private var history: some View {
        VStack(spacing: 10) {
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 16)
            if model.entries.isEmpty {
                empty("Your transcript history", detail: "Dictations and recordings stay here, on this Mac.\nCopy a transcript whenever you need it.")
            } else {
                let entries = model.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
                if entries.isEmpty {
                    empty("No matching transcripts", detail: "Try another word or phrase.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(entries) { entry in
                                let preview = entry.displayText
                                Button {
                                    model.selectedID = entry.id
                                    tab = 1
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Label(entry.source.title, systemImage: entry.source == .dictation ? "mic" : "waveform")
                                            Spacer()
                                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            Text("· \(clock(entry.duration))")
                                        }.font(.caption).foregroundStyle(.secondary)
                                        Text(preview.isEmpty ? (entry.recordingState?.inProgress == true ? "Recording transcript…" : "No transcript yet") : preview).font(.system(size: 13)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                                        .contentShape(RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clock(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Only this small header observes meter ticks; search, history, and transcript
/// layout do not participate in audio-driven updates.
private struct TranscriptTextView: View {
    let entry: TranscriptEntry
    let paused: Bool
    @State private var following: Bool
    @State private var userScrolling = false
    private let bottomID = "transcript-bottom"

    init(entry: TranscriptEntry, paused: Bool) {
        self.entry = entry
        self.paused = paused
        _following = State(initialValue: entry.recordingState?.inProgress == true)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let segments = entry.displaySegments {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(TranscriptSegment.timestamp(segment.start)) · \(segment.sourceTitle)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(segment.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if entry.recordingState?.inProgress == true {
                            Text(paused ? "Recording paused." : (entry.recordingState == .recording
                                 ? "Listening… New paragraphs appear at pauses." : "Finishing the remaining audio…"))
                                .font(.callout).foregroundStyle(.secondary)
                        } else if segments.isEmpty {
                            Text(entry.recordingState == .failed ? "Audio is saved. Retry to finish the transcript." : "No speech detected.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(entry.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 48
            } action: { _, atBottom in
                if userScrolling { following = atBottom }
            }
            .onScrollPhaseChange { _, phase, context in
                let manual = phase == .tracking || phase == .interacting || phase == .decelerating
                if userScrolling && phase == .idle {
                    following = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 48
                }
                userScrolling = manual
            }
            .task(id: entry.displayText) {
                guard following else { return }
                // Allow the newly appended paragraph to lay out before moving.
                await Task.yield()
                guard !Task.isCancelled, following else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following && entry.recordingState?.inProgress == true {
                    Button("Latest", systemImage: "arrow.down") {
                        following = true
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }.buttonStyle(.borderedProminent).controlSize(.small).padding(6)
                }
            }
        }
    }
}

private struct RecordingMeterView: View {
    @ObservedObject var meter: RecordingMeterModel
    let recording: Bool
    let paused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<5) { index in
                    Capsule().fill(recording && !paused ? Color.white : Color.secondary)
                        .frame(width: 3, height: height(index))
                }
            }.frame(width: 27, height: 24)
                .accessibilityLabel(recording ? "Recording" : "Luxit")
            if recording {
                let seconds = max(0, Int(meter.elapsed))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                Text(paused ? "Paused" : "Mic + Mac").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Luxit").font(.system(size: 18, weight: .semibold))
            }
        }
    }

    private func height(_ index: Int) -> CGFloat {
        let base: [CGFloat] = [12, 23, 17, 26, 14]
        return recording && !paused
            ? base[index] * (0.35 + CGFloat(min(1, meter.level * 12)) * 0.65) : base[index] * 0.6
    }
}

private struct LuxitSettingsView: View {
    @ObservedObject var model: LuxitSettingsModel
    @State private var choosingModel = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    Button { choosingModel.toggle() } label: {
                        row("Transcription model", detail: model.selectedModelName,
                            icon: "waveform", accessory: choosingModel ? "chevron.up" : "chevron.down")
                    }.buttonStyle(.plain)
                    if choosingModel {
                        ForEach(model.models) { option in
                            Button { model.onSelectModel?(option.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.selectedModelID == option.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.selectedModelID == option.id ? Color.cyan : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.title).font(.system(size: 12, weight: .medium))
                                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!model.canSelectModel || !option.available)
                        }
                    }
                }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                action("Permissions", detail: model.permissions, icon: "lock.shield", perform: model.onPermissions)
                action("Vocabulary", detail: "Names and words you use", icon: "text.book.closed", perform: model.onVocabulary)
                row("Usage", detail: model.usage + "\n" + model.performance, icon: "chart.bar", accessory: nil)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                action("Show Luxit in Applications", icon: "folder", perform: model.onReveal)
                HStack(spacing: 10) {
                    Text("Luxit " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart") { model.onRestart?() }
                    Button("Quit") { model.onQuit?() }
                }.buttonStyle(.bordered).padding(.vertical, 6)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func row(_ title: String, detail: String? = nil, icon: String, accessory: String? = "chevron.right") -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            if let accessory { Image(systemName: accessory).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func action(_ title: String, detail: String? = nil, icon: String, perform: (() -> Void)?) -> some View {
        Button { perform?() } label: { row(title, detail: detail, icon: icon) }
            .buttonStyle(.plain).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
