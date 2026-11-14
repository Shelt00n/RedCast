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
            .fill(Theme.lineStrong)
            .frame(width: 32, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
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
                    if ui.tab == .hints {
                        HintsPane()
                    } else {
                        SettingsPane()
                    }
                }
            }
        }
        .foregroundStyle(Theme.fg)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .tint(Theme.fg2)
        .onChange(of: settings.hideFromScreenShare) { OverlayController.shared.applySharing() }
        .onChange(of: settings.overlayOpacity) { OverlayController.shared.applySharing() }
        .onChange(of: settings.showInDock) { OverlayController.applyDockPolicy() }
    }
}

/// Tally bound to the app state.
struct StatusDot: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Tally(on: state.isListening || !state.recording.isEmpty,
              starting: state.isStarting,
              ring: state.isListening && state.speaking.contains(.interviewer))
    }
}

/// The one primary action. While on air it turns into a quiet «Стоп» with the lit tally.
struct StartButton: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        if compact {
            IconButton(symbol: state.isListening ? "stop" : "play",
                       help: state.isListening ? "Стоп" : "Старт",
                       tint: state.isListening ? Theme.fg : Theme.fg2) { state.toggleListening() }
        } else {
            Button {
                state.toggleListening()
            } label: {
                HStack(spacing: 8) {
                    if state.isStarting {
                        ProgressView().controlSize(.mini)
                    } else if state.isListening {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "play")
                    }
                    Text(state.isListening ? "Стоп" : (state.isStarting ? "Запуск…" : "Старт"))
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(RCButtonStyle(kind: state.isListening ? .secondary : .primary,
                                       live: state.isListening, height: 40, padding: 20, fontSize: 14))
            .help(state.isListening ? "Остановить прослушивание" : "Начать слушать созвон")
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    var body: some View {
        VStack(spacing: 12) {
            GrabHandle().padding(.top, -4).padding(.bottom, -4)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    StatusDot()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.status).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(state.modelStatus).font(.system(size: 12)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .help(state.status)
                Segmented(selection: ui.tab,
                          items: MainTab.allCases.map { (value: $0, title: $0.title) }) { ui.tab = $0 }
                HStack(spacing: 0) {
                    IconButton(symbol: "minus", help: "Свернуть в полоску", size: 12) { ui.toggleCompact() }
                    IconButton(symbol: "xmark", help: "Скрыть окно (вернуть — значок волны в строке меню)", size: 12) { ui.hide() }
                }
            }
            if let p = state.modelProgress {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.fg2)
            }
            if ui.tab == .hints {
                HStack(spacing: 8) {
                    ModePicker()
                    Spacer()
                    Button { state.solveScreenshot() } label: { IconLabel(symbol: "camera.viewfinder", title: "Скриншот") }
                        .buttonStyle(RCButtonStyle())
                        .help("Решить задачу с экрана")
                    IconButton(symbol: "trash", help: "Очистить подсказки и расшифровку") { state.clear() }
                }
                HStack(spacing: 8) {
                    if settings.listenMode == .auto {
                        StartButton()
                        Button { state.answerNow() } label: { IconLabel(symbol: "bolt", title: "Ответить сейчас") }
                            .buttonStyle(RCButtonStyle(height: 40, padding: 16, fontSize: 14))
                            .help("Не ждать паузы")
                        Spacer()
                    } else {
                        RecordButton(speaker: .interviewer)
                        RecordButton(speaker: .me)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .windowDraggable()
    }
}

struct ModePicker: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Segmented(selection: settings.listenMode,
                  items: ListenMode.allCases.map { (value: $0, title: $0.title) }) { state.setMode($0) }
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
    private var symbol: String { speaker == .interviewer ? "headphones" : "mic" }
    private var help: String {
        speaker == .interviewer
            ? "Нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил: получите ответ"
            : "Нажмите и говорите (например, повторите вопрос), нажмите ещё раз — получите подсказку"
    }

    var body: some View {
        if compact {
            IconButton(symbol: isRecording ? "stop" : symbol, help: help,
                       tint: isRecording ? Theme.fg : Theme.fg2) { state.toggleRecord(speaker) }
        } else {
            Button {
                state.toggleRecord(speaker)
            } label: {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if isRecording {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        } else {
                            Image(systemName: symbol).foregroundStyle(Theme.fg2)
                        }
                        Text(isRecording ? "Готово, получить ответ" : (speaker == .interviewer ? "Интервьюер" : "Я"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    if isRecording {
                        Text("идёт запись").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    } else if let combo = hotkeys.combos[action]?.display {
                        Text(combo).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.fg3)
                    } else {
                        Text("нажмите, чтобы записать").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RCButtonStyle(live: isRecording, height: 56))
            .help(help)
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var state: AppState
    let text: String
    let permission: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if permission {
                    Text("Если переключатель уже включён: macOS запомнил прошлую версию RedCast. Нажмите «Сбросить разрешение» — RedCast перезапустится, и macOS спросит доступ заново. Разрешите его.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Сбросить разрешение и перезапустить") {
                            Updater.resetScreenPermissionAndRelaunch()
                        }
                        .buttonStyle(RCButtonStyle(kind: .primary, height: 28))
                        Button("Открыть настройки") {
                            state.openPrivacySettings("Privacy_ScreenCapture")
                        }
                        .buttonStyle(RCButtonStyle(height: 28))
                    }
                }
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Закрыть", size: 11) { state.errorMessage = nil }
                .padding(.top, -6)
        }
        .padding(.leading, 12)
        .padding(.vertical, 12)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
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
        HStack(spacing: 4) {
            StatusDot().padding(.trailing, 4)
            if settings.listenMode == .auto {
                StartButton(compact: true)
                IconButton(symbol: "bolt", help: "Ответить сейчас") { state.answerNow() }
            } else {
                RecordButton(speaker: .interviewer, compact: true)
                RecordButton(speaker: .me, compact: true)
            }
            IconButton(symbol: "camera.viewfinder", help: "Задача со скриншота") { state.solveScreenshot() }
                .padding(.trailing, 8)
            Text(lastLine)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .help(state.answers.last?.text ?? "")
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Развернуть", size: 12) { ui.toggleCompact() }
            IconButton(symbol: "xmark", help: "Скрыть окно", size: 12) { ui.hide() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
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
                HStack(spacing: 12) {
                    Circle().fill(Theme.positive).frame(width: 8, height: 8)
                    Text(state.isUpdating ? state.updateStatus : "Доступна новая версия \(u.version)")
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    if state.isUpdating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Обновить") { Task { await state.installUpdate() } }
                            .buttonStyle(RCButtonStyle(kind: .primary))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            answersList
            HStack {
                Button {
                    showTranscript.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showTranscript ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        Text("Расшифровка")
                    }
                }
                .buttonStyle(RCButtonStyle(kind: .ghost, height: 28, padding: 8, fontSize: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .windowDraggable()
            if showTranscript { transcript }
            inputBar
        }
    }

    private func key(_ a: HotKeyAction) -> String { hotkeys.combos[a]?.display ?? "не задано" }

    private var answersList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if state.answers.isEmpty { emptyHint }
                    ForEach(state.answers) { item in
                        AnswerCard(item: item, fontSize: settings.fontSize, isCurrent: item.id == state.currentAnswerID) {
                            state.toggleExpanded(item.id)
                        }
                        .id(item.id)
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 16)
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
                Text("Режим «Авто»: нажмите «Старт» и начните созвон").font(.system(size: 15, weight: .medium))
                Text("""
                RedCast сам слышит вопросы интервьюера — подсказка появится через 1–3 секунды после паузы.
                \(key(.answerNow)) — ответить сразу · \(key(.screenshot)) — задача со скриншота · \(key(.toggleWindow)) — спрятать окно · \(key(.toggleCompact)) — свернуть.
                """)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.fg2)
            } else {
                Text("Режим «По кнопкам»").font(.system(size: 15, weight: .medium))
                Text("""
                «Интервьюер» (\(key(.recordInterviewer))): нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил. Через 1–3 секунды появится ответ.
                «Я» (\(key(.recordMe))): то же для вашего микрофона — например, повторите вопрос вслух или начните отвечать, и RedCast подскажет, что добавить.
                """)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.fg2)
            }
            Text("Клавиши можно поменять во вкладке «Настройки».")
                .font(.system(size: 13))
                .foregroundStyle(Theme.fg2)
        }
        .padding(.top, 4)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if state.entries.isEmpty && state.partial.isEmpty {
                        Text(state.isListening ? "Жду речь…" : "Расшифровка появится здесь")
                            .font(.system(size: 13)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(state.entries.suffix(40)) { e in
                        line(e.speaker, e.text, live: false)
                    }
                    if let p = state.partial[.interviewer] { line(.interviewer, p, live: true) }
                    if let p = state.partial[.me] { line(.me, p, live: true) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.entries.count) { proxy.scrollTo("end") }
            .onChange(of: state.partial[.interviewer]) { proxy.scrollTo("end") }
        }
        .frame(height: 120)
    }

    /// Speakers differ by text role, not by color: the interviewer is primary, «Я» is muted.
    private func line(_ speaker: Speaker, _ text: String, live: Bool) -> some View {
        (Text(speaker == .interviewer ? "Интервьюер: " : "Я: ")
            .foregroundColor(live ? Theme.fg3 : (speaker == .interviewer ? Theme.fg : Theme.fg3))
            .fontWeight(.medium)
         + Text(text).foregroundColor(live ? Theme.fg3 : Theme.fg2))
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
    }

    private var inputBar: some View {
        TextField("", text: $manualQuestion, prompt: Text("Вопрос текстом — Enter").foregroundColor(Theme.fg3))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
            .onSubmit {
                state.askManual(manualQuestion)
                manualQuestion = ""
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.bgDeep)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct AnswerCard: View {
    let item: AnswerItem
    let fontSize: Double
    var isCurrent = false
    var onToggle: () -> Void = {}

    private var preview: String {
        let line = item.text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isCurrent {
                // On-air rule: the answer being read right now
                RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onToggle) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.fg3)
                        Text(item.question)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.fg2)
                            .lineLimit(item.expanded ? 2 : 1)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if item.isStreaming && item.text.isEmpty {
                            ProgressView().controlSize(.small)
                        } else if let t = item.firstTokenSeconds {
                            Text(String(format: "%.1f с", t))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.fg3)
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
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let err = item.error {
                    Text(err).font(.system(size: 13)).foregroundStyle(Theme.negative).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
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
                            .foregroundStyle(Theme.fg)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.bgDeep))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                } else {
                    Text(Self.attributed(part.body, fontSize: fontSize))
                        .font(.system(size: fontSize))
                        .foregroundStyle(Theme.fg)
                        .lineSpacing(fontSize * 0.4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func attributed(_ s: String, fontSize: Double) -> AttributedString {
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
        var result = (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
        // Emphasis is semibold, not bold; bullets stay in the muted role.
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                result[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] =
                    Font.system(size: fontSize, weight: .semibold)
            }
        }
        var search = result.startIndex
        while let r = result[search...].range(of: "•") {
            result[r][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Theme.fg3
            search = r.upperBound
        }
        return result
    }
}
