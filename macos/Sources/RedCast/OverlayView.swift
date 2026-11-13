import AppKit
import SwiftUI

// MARK: - Panel

/// Borderless floating panel (no system title bar that could swallow clicks).
/// `sharingType = .none` asks macOS to exclude it from screen sharing / recording.
final class OverlayPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false   // dragging only by the header: buttons stay clickable
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 420, height: 360)
        contentView = NSHostingView(rootView: rootView)
        if !setFrameUsingName("RedCastMain"), let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24,
                                   y: screen.visibleFrame.maxY - frame.height - 24))
        }
        setFrameAutosaveName("RedCastMain")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The app has no visible menu bar, so route ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z manually.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let ch = event.charactersIgnoringModifiers?.lowercased() {
            var action: Selector?
            switch ch {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: break
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case hints, settings
    var id: String { rawValue }
    var title: String { self == .hints ? "Подсказки" : "Настройки" }
}

@MainActor
final class OverlayController: ObservableObject {
    static let shared = OverlayController()

    @Published var tab: MainTab = .hints
    @Published private(set) var compact = false
    @Published private(set) var clickThrough = false

    private var panel: OverlayPanel?
    private var expandedFrame: NSRect?
    var window: NSWindow? { panel }

    func show() {
        if panel == nil {
            panel = OverlayPanel(rootView: MainView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(HotKeyStore.shared)
                .environmentObject(self))
        }
        applySharing()
        panel?.orderFrontRegardless()
    }

    func showSettings() {
        if compact { toggleCompact() }
        tab = .settings
        show()
        panel?.makeKey()
    }

    func applySharing() {
        panel?.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel?.alphaValue = AppSettings.shared.overlayOpacity
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggleVisible() {
        guard let panel else { return show() }
        if panel.isVisible { hide() } else { show() }
    }

    func toggleCompact() {
        guard let panel else { return }
        if compact {
            let target = expandedFrame ?? NSRect(x: panel.frame.minX, y: panel.frame.maxY - 700, width: 560, height: 700)
            compact = false
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - target.height,
                                  width: target.width, height: target.height), display: true, animate: true)
        } else {
            expandedFrame = panel.frame
            compact = true
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 52, width: 520, height: 52),
                           display: true, animate: true)
        }
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        panel?.ignoresMouseEvents = clickThrough
        AppState.shared.status = clickThrough
            ? "Сквозные клики включены (\(HotKeyStore.shared.combos[.clickThrough]?.display ?? "") — выключить)"
            : (AppState.shared.isListening ? "Слушаю…" : "Готов")
    }

    func scroll(by delta: CGFloat) {
        guard let root = panel?.contentView else { return }
        var scrollViews: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { scrollViews.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let target = scrollViews.max(by: { $0.frame.height < $1.frame.height }) else { return }
        let clip = target.contentView
        var origin = clip.bounds.origin
        let maxY = max(0, (target.documentView?.frame.height ?? 0) - clip.bounds.height)
        origin.y = min(max(0, origin.y + (target.documentView?.isFlipped == false ? -delta : delta)), maxY)
        clip.scroll(to: origin)
        target.reflectScrolledClipView(clip)
    }
}

// MARK: - AppKit helpers

/// Makes the empty background of a view drag the window.
/// Pure SwiftUI gesture on the background layer: buttons on top keep receiving their clicks.
struct WindowDraggable: ViewModifier {
    @State private var startOrigin: NSPoint?
    @State private var startMouse: NSPoint?

    func body(content: Content) -> some View {
        content.background(
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { _ in
                            guard let w = OverlayController.shared.window else { return }
                            let mouse = NSEvent.mouseLocation
                            if startOrigin == nil {
                                startOrigin = w.frame.origin
                                startMouse = mouse
                            }
                            guard let o = startOrigin, let m = startMouse else { return }
                            w.setFrameOrigin(NSPoint(x: o.x + mouse.x - m.x, y: o.y + mouse.y - m.y))
                        }
                        .onEnded { _ in
                            startOrigin = nil
                            startMouse = nil
                        }
                )
        )
    }
}

extension View {
    func windowDraggable() -> some View { modifier(WindowDraggable()) }
}

/// Small visible "grab here" handle.
struct GrabHandle: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .help("Потяните, чтобы переместить окно")
    }
}

/// Area that moves the window when dragged.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Bottom-right corner handle that resizes the borderless window.
struct ResizeGrip: NSViewRepresentable {
    final class GripView: NSView {
        private var startMouse = NSPoint.zero
        private var startFrame = NSRect.zero

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let p = NSEvent.mouseLocation
            var f = startFrame
            f.size.width = max(w.minSize.width, startFrame.width + (p.x - startMouse.x))
            f.size.height = max(w.minSize.height, startFrame.height - (p.y - startMouse.y))
            f.origin.y = startFrame.maxY - f.height
            w.setFrame(f, display: true)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath()
            for i in 1...3 {
                let o = CGFloat(i) * 4
                path.move(to: NSPoint(x: bounds.maxX - o, y: bounds.minY + 2))
                path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + o))
            }
            path.lineWidth = 1
            path.stroke()
        }
    }
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Main view

struct MainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    var body: some View {
        Group {
            if ui.compact {
                CompactBar()
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    if let err = state.errorMessage {
                        ErrorBanner(text: err, permission: state.errorIsPermission)
                    }
                    Divider().opacity(0.35)
                    if ui.tab == .hints {
                        HintsPane()
                    } else {
                        SettingsPane()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    ResizeGrip().frame(width: 16, height: 16).padding(3)
                }
            }
        }
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .onChange(of: settings.hideFromScreenShare) { OverlayController.shared.applySharing() }
        .onChange(of: settings.overlayOpacity) { OverlayController.shared.applySharing() }
    }
}

struct StatusDot: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Circle()
            .fill(!state.recording.isEmpty ? Color.red
                  : state.isListening ? (state.speaking.contains(.interviewer) ? Color.orange : Color.green)
                  : (state.isStarting ? Color.yellow : Color.gray))
            .frame(width: 10, height: 10)
    }
}

struct StartButton: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        Button {
            state.toggleListening()
        } label: {
            HStack(spacing: 5) {
                if state.isStarting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: state.isListening ? "stop.fill" : "play.fill")
                }
                if !compact {
                    Text(state.isListening ? "Стоп" : (state.isStarting ? "Запуск…" : "Старт"))
                }
            }
            .frame(minWidth: compact ? 18 : 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isListening ? .red : .green)
        .controlSize(compact ? .small : .regular)
        .help(state.isListening ? "Остановить прослушивание" : "Начать слушать созвон")
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    var body: some View {
        VStack(spacing: 8) {
            GrabHandle().padding(.top, -6)
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatusDot()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.status).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(state.modelStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
                Picker("", selection: $ui.tab) {
                    ForEach(MainTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                WindowButton(symbol: "minus", help: "Свернуть в полоску") { ui.toggleCompact() }
                WindowButton(symbol: "xmark", help: "Скрыть окно (вернуть — значок волны в строке меню)") { ui.hide() }
            }
            if let p = state.modelProgress {
                ProgressView(value: p).progressViewStyle(.linear).controlSize(.small)
            }
            if ui.tab == .hints {
                HStack(spacing: 8) {
                    ModePicker()
                    Spacer()
                    ActionButton(symbol: "camera.viewfinder", title: "Скриншот", help: "Решить задачу с экрана") { state.solveScreenshot() }
                    ActionButton(symbol: "trash", title: nil, help: "Очистить") { state.clear() }
                }
                HStack(spacing: 8) {
                    if settings.listenMode == .auto {
                        StartButton()
                        ActionButton(symbol: "bolt.fill", title: "Ответить сейчас", help: "Не ждать паузы") { state.answerNow() }
                        Spacer()
                    } else {
                        RecordButton(speaker: .interviewer)
                        RecordButton(speaker: .me)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .windowDraggable()
    }
}

struct ModePicker: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Picker("Режим", selection: Binding(get: { settings.listenMode }, set: { state.setMode($0) })) {
            ForEach(ListenMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .help("Авто — слушает всё и отвечает сам. По кнопкам — вы сами отмечаете начало и конец вопроса.")
    }
}

/// «По кнопкам»: 1st press — record this channel, 2nd press — recognise and answer.
struct RecordButton: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hotkeys: HotKeyStore
    let speaker: Speaker
    var compact = false

    private var isRecording: Bool { state.recording.contains(speaker) }
    private var action: HotKeyAction { speaker == .interviewer ? .recordInterviewer : .recordMe }

    var body: some View {
        Button {
            state.toggleRecord(speaker)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.circle.fill"
                      : (speaker == .interviewer ? "headphones" : "mic.fill"))
                if !compact {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(isRecording ? "Готово → ответ" : (speaker == .interviewer ? "Интервьюер" : "Я"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(isRecording ? "идёт запись…" : (hotkeys.combos[action]?.display ?? "нажмите, чтобы записать"))
                            .font(.system(size: 10))
                            .opacity(0.8)
                    }
                }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.vertical, compact ? 0 : 3)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : (speaker == .interviewer ? .orange : .blue))
        .controlSize(compact ? .small : .regular)
        .help(speaker == .interviewer
              ? "Нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил: получите ответ"
              : "Нажмите и говорите (например, повторите вопрос), нажмите ещё раз — получите подсказку")
    }
}

struct WindowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ActionButton: View {
    let symbol: String
    let title: String?
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if let title {
                Label(title, systemImage: symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var state: AppState
    let text: String
    let permission: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if permission {
                    Button("Открыть настройки «Запись экрана и системного звука»") {
                        state.openPrivacySettings("Privacy_ScreenCapture")
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
            Button { state.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }
}

struct CompactBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    private var lastLine: String {
        guard let a = state.answers.last else { return state.status }
        if let e = a.error { return e }
        let first = a.text.split(separator: "\n").first.map(String.init) ?? ""
        return first.isEmpty ? (a.isStreaming ? "Думаю…" : state.status) : first.replacingOccurrences(of: "**", with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot()
            if settings.listenMode == .auto {
                StartButton(compact: true)
                Button { state.answerNow() } label: { Image(systemName: "bolt.fill") }
                    .buttonStyle(.bordered).controlSize(.small).help("Ответить сейчас")
            } else {
                RecordButton(speaker: .interviewer, compact: true)
                RecordButton(speaker: .me, compact: true)
            }
            Button { state.solveScreenshot() } label: { Image(systemName: "camera.viewfinder") }
                .buttonStyle(.bordered).controlSize(.small).help("Скриншот → решение")
            Text(lastLine)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .help(state.answers.last?.text ?? "")
            WindowButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Развернуть") { ui.toggleCompact() }
            WindowButton(symbol: "xmark", help: "Скрыть окно") { ui.hide() }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowDraggable()
    }
}

// MARK: - Hints

struct HintsPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hotkeys: HotKeyStore
    @State private var manualQuestion = ""
    @State private var showTranscript = true

    var body: some View {
        VStack(spacing: 0) {
            answersList
            Divider().opacity(0.35)
            HStack {
                Button {
                    showTranscript.toggle()
                } label: {
                    Label(showTranscript ? "Скрыть расшифровку" : "Показать расшифровку",
                          systemImage: showTranscript ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .windowDraggable()
            if showTranscript { transcript }
            inputBar
        }
    }

    private func key(_ a: HotKeyAction) -> String { hotkeys.combos[a]?.display ?? "не задано" }

    private var answersList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.answers.isEmpty { emptyHint }
                    ForEach(state.answers) { item in
                        AnswerCard(item: item, fontSize: settings.fontSize).id(item.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: state.answers.last?.id) {
                if let id = state.answers.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.listenMode == .auto {
                Text("Режим «Авто»: нажмите «Старт» и начните созвон").font(.system(size: settings.fontSize, weight: .semibold))
                Text("""
                RedCast сам слышит вопросы интервьюера — подсказка появится через 1–3 секунды после паузы.
                \(key(.answerNow)) — ответить сразу · \(key(.screenshot)) — задача со скриншота · \(key(.toggleWindow)) — спрятать окно · \(key(.toggleCompact)) — свернуть.
                """)
                .font(.system(size: settings.fontSize - 2))
                .foregroundStyle(.secondary)
            } else {
                Text("Режим «По кнопкам»").font(.system(size: settings.fontSize, weight: .semibold))
                Text("""
                🎧 «Интервьюер» (\(key(.recordInterviewer))): нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил. Через 1–3 секунды появится ответ.
                🎤 «Я» (\(key(.recordMe))): то же для вашего микрофона — например, повторите вопрос вслух или начните отвечать, и RedCast подскажет, что добавить.
                """)
                .font(.system(size: settings.fontSize - 2))
                .foregroundStyle(.secondary)
            }
            Text("Клавиши можно поменять во вкладке «Настройки».")
            .font(.system(size: settings.fontSize - 2))
            .foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if state.entries.isEmpty && state.partial.isEmpty {
                        Text(state.isListening ? "Жду речь…" : "Расшифровка появится здесь")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    ForEach(state.entries.suffix(40)) { e in
                        line(e.speaker, e.text, live: false)
                    }
                    if let p = state.partial[.interviewer] { line(.interviewer, p, live: true) }
                    if let p = state.partial[.me] { line(.me, p, live: true) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.entries.count) { proxy.scrollTo("end") }
            .onChange(of: state.partial[.interviewer]) { proxy.scrollTo("end") }
        }
        .frame(height: 120)
    }

    private func line(_ speaker: Speaker, _ text: String, live: Bool) -> some View {
        (Text(speaker == .interviewer ? "Интервьюер: " : "Я: ")
            .foregroundColor(speaker == .interviewer ? .orange : .blue)
            .bold()
         + Text(text).foregroundColor(live ? .secondary : .primary).italic(live))
            .font(.system(size: 12))
            .textSelection(.enabled)
    }

    private var inputBar: some View {
        HStack {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            TextField("Вопрос текстом → Enter", text: $manualQuestion)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    state.askManual(manualQuestion)
                    manualQuestion = ""
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .padding(.trailing, 16)
        .background(Color.black.opacity(0.15))
    }
}

struct AnswerCard: View {
    let item: AnswerItem
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.question)
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer()
                if item.isStreaming && item.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else if let t = item.firstTokenSeconds {
                    Text(String(format: "%.1f с", t)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            MarkdownText(text: item.text, fontSize: fontSize)
            if let err = item.error {
                Text(err).font(.system(size: 12)).foregroundColor(.red).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

/// Minimal Markdown: inline formatting + fenced code blocks.
struct MarkdownText: View {
    let text: String
    let fontSize: Double

    private struct Part: Identifiable {
        let id: Int
        let isCode: Bool
        let body: String
    }

    private var parts: [Part] {
        var result: [Part] = []
        let pieces = text.components(separatedBy: "```")
        for (i, piece) in pieces.enumerated() {
            if i % 2 == 1 {
                var lines = piece.components(separatedBy: "\n")
                if let first = lines.first, !first.contains(" "), lines.count > 1 { lines.removeFirst() }
                result.append(Part(id: i, isCode: true, body: lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Part(id: i, isCode: false, body: piece.trimmingCharacters(in: .newlines)))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parts) { part in
                if part.isCode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(part.body)
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                } else {
                    Text(Self.attributed(part.body))
                        .font(.system(size: fontSize))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func attributed(_ s: String) -> AttributedString {
        let normalized = s.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "•  " + String(trimmed.dropFirst(2))
            }
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
    }
}
