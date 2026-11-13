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
        minSize = OverlayPanel.normalMinSize
        // Content + invisible resize zones on every edge and corner (AppKit views on top,
        // so they always get the mouse, unlike a SwiftUI overlay).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 700))
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        for edge in ResizeHandle.Edge.allCases {
            container.addSubview(ResizeHandle(edge: edge, in: container.bounds))
        }
        contentView = container
        if !setFrameUsingName("RedCastMain"), let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 24,
                                   y: screen.visibleFrame.maxY - frame.height - 24))
        }
        setFrameAutosaveName("RedCastMain")
    }

    static let normalMinSize = NSSize(width: 360, height: 300)

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
        keepOnScreen()
        panel?.orderFrontRegardless()
    }

    /// Bring the window back if it ended up outside every screen (monitor unplugged, resized…).
    private func keepOnScreen() {
        guard let panel, let main = NSScreen.main else { return }
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame.insetBy(dx: 40, dy: 40)) }
        if !visible {
            let vf = main.visibleFrame
            let size = NSSize(width: min(panel.frame.width, vf.width - 48), height: min(panel.frame.height, vf.height - 48))
            panel.setFrame(NSRect(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24, width: size.width, height: size.height),
                           display: true)
        }
    }

    /// Dock icon on/off (useful when the menu bar icon is hidden behind the MacBook notch).
    static func applyDockPolicy() {
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
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

    /// ✕: the window goes to the menu bar (and the Dock icon, if enabled). The app keeps running.
    func hide() {
        panel?.orderOut(nil)
        let key = "hideHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let combo = HotKeyStore.shared.combos[.toggleWindow]?.display ?? "⌃⌥H"
        let alert = NSAlert()
        alert.messageText = "RedCast свёрнут и продолжает работать"
        alert.informativeText = """
        Вернуть окно:
        • \(combo) — в любой программе;
        • значок волны в строке меню (на MacBook с «чёлкой» он может быть скрыт под вырезом камеры);
        • снова открыть RedCast из «Программ», Spotlight или Launchpad.

        Совсем закрыть: значок волны → «Выйти» или «Настройки» → «Выйти из RedCast».
        """
        alert.addButton(withTitle: "Понятно")
        alert.addButton(withTitle: "Показывать иконку в Dock")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            AppSettings.shared.showInDock = true
            OverlayController.applyDockPolicy()
        }
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
            panel.minSize = OverlayPanel.normalMinSize
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - target.height,
                                  width: target.width, height: target.height), display: true, animate: true)
        } else {
            expandedFrame = panel.frame
            compact = true
            panel.minSize = NSSize(width: 320, height: 52)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 52)
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 52, width: max(panel.frame.width, 520), height: 52),
                           display: true, animate: true)
        }
    }

    enum SizePreset: String, CaseIterable, Identifiable {
        case small, medium, large, tall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: return "Маленькое"
            case .medium: return "Среднее"
            case .large: return "Большое"
            case .tall: return "На всю высоту экрана"
            }
        }
    }

    /// Quick window sizes (menu bar → «Размер окна»). Keeps the window on screen.
    func setSize(_ preset: SizePreset) {
        if compact { toggleCompact() }
        show()
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var size: NSSize
        switch preset {
        case .small: size = NSSize(width: 420, height: 480)
        case .medium: size = NSSize(width: 560, height: 720)
        case .large: size = NSSize(width: 760, height: 900)
        case .tall: size = NSSize(width: max(panel.frame.width, 560), height: vf.height - 16)
        }
        size.width = min(size.width, vf.width - 16)
        size.height = min(size.height, vf.height - 16)
        var origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
        origin.y = min(max(vf.minY + 8, origin.y), vf.maxY - size.height - 8)
        if preset == .tall { origin.y = vf.minY + 8 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
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

/// Invisible strip along a window edge / corner that resizes the borderless window.
final class ResizeHandle: NSView {
    enum Edge: CaseIterable { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }

    static let thickness: CGFloat = 6
    static let corner: CGFloat = 14

    let edge: Edge
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(edge: Edge, in b: NSRect) {
        self.edge = edge
        let t = ResizeHandle.thickness, c = ResizeHandle.corner
        let frame: NSRect
        let mask: NSView.AutoresizingMask
        switch edge {
        case .left: frame = NSRect(x: 0, y: c, width: t, height: b.height - 2 * c); mask = [.height, .maxXMargin]
        case .right: frame = NSRect(x: b.width - t, y: c, width: t, height: b.height - 2 * c); mask = [.height, .minXMargin]
        case .bottom: frame = NSRect(x: c, y: 0, width: b.width - 2 * c, height: t); mask = [.width, .maxYMargin]
        case .top: frame = NSRect(x: c, y: b.height - t, width: b.width - 2 * c, height: t); mask = [.width, .minYMargin]
        case .bottomLeft: frame = NSRect(x: 0, y: 0, width: c, height: c); mask = [.maxXMargin, .maxYMargin]
        case .bottomRight: frame = NSRect(x: b.width - c, y: 0, width: c, height: c); mask = [.minXMargin, .maxYMargin]
        case .topLeft: frame = NSRect(x: 0, y: b.height - c, width: c, height: c); mask = [.maxXMargin, .minYMargin]
        case .topRight: frame = NSRect(x: b.width - c, y: b.height - c, width: c, height: c); mask = [.minXMargin, .minYMargin]
        }
        super.init(frame: frame)
        autoresizingMask = mask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch edge {
        case .left, .right: cursor = .resizeLeftRight
        case .top, .bottom: cursor = .resizeUpDown
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        let minW = w.minSize.width, minH = w.minSize.height
        let maxW = w.maxSize.width, maxH = w.maxSize.height
        var f = startFrame
        if [.right, .topRight, .bottomRight].contains(edge) {
            f.size.width = min(maxW, max(minW, startFrame.width + dx))
        }
        if [.left, .topLeft, .bottomLeft].contains(edge) {
            let width = min(maxW, max(minW, startFrame.width - dx))
            f.origin.x = startFrame.maxX - width
            f.size.width = width
        }
        if [.top, .topLeft, .topRight].contains(edge) {
            f.size.height = min(maxH, max(minH, startFrame.height + dy))   // bottom edge stays
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(edge) {
            let height = min(maxH, max(minH, startFrame.height - dy))      // top edge stays
            f.origin.y = startFrame.maxY - height
            f.size.height = height
        }
        w.setFrame(f, display: true)
    }
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
            }
        }
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .onChange(of: settings.hideFromScreenShare) { OverlayController.shared.applySharing() }
        .onChange(of: settings.overlayOpacity) { OverlayController.shared.applySharing() }
        .onChange(of: settings.showInDock) { OverlayController.applyDockPolicy() }
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
                    Text("Если переключатель уже включён: macOS запомнил прошлую версию RedCast. Нажмите «Сбросить разрешение» — RedCast перезапустится, и macOS спросит доступ заново. Разрешите его.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Сбросить разрешение и перезапустить") {
                            Updater.resetScreenPermissionAndRelaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Открыть настройки") {
                            state.openPrivacySettings("Privacy_ScreenCapture")
                        }
                        .controlSize(.small)
                    }
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
    @AppStorage("showTranscript") private var showTranscript = true

    var body: some View {
        VStack(spacing: 0) {
            if let u = state.updateAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.green)
                    Text(state.isUpdating ? state.updateStatus : "Доступна новая версия \(u.version)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if state.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Обновить") { Task { await state.installUpdate() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.green.opacity(0.14))
            }
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
                VStack(alignment: .leading, spacing: 12) {
                    if state.answers.isEmpty { emptyHint }
                    ForEach(state.answers) { item in
                        AnswerCard(item: item, fontSize: settings.fontSize) {
                            state.toggleExpanded(item.id)
                        }
                        .id(item.id)
                    }
                    Color.clear.frame(height: 24)
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
        .background(Color.black.opacity(0.15))
    }
}

struct AnswerCard: View {
    let item: AnswerItem
    let fontSize: Double
    var onToggle: () -> Void = {}

    private var preview: String {
        let line = item.text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(item.question)
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(.secondary)
                        .lineLimit(item.expanded ? 4 : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if item.isStreaming && item.text.isEmpty {
                        ProgressView().controlSize(.small)
                    } else if let t = item.firstTokenSeconds {
                        Text(String(format: "%.1f с", t)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.expanded ? "Свернуть ответ" : "Развернуть ответ")

            if item.expanded {
                MarkdownText(text: item.text, fontSize: fontSize)
            } else if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: fontSize - 1, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let err = item.error {
                Text(err).font(.system(size: 12)).foregroundColor(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(item.expanded ? 0.07 : 0.04)))
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
