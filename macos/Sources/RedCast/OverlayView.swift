import AppKit
import AVFoundation
import SwiftUI

// MARK: - Panel

/// The first click on a button works even while the panel is not key
/// (otherwise macOS spends it on activating the window and the button «does nothing»).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless floating panel over a blurred «smoked glass» background.
/// `sharingType = .none` asks macOS to exclude it from screen sharing / recording.
final class OverlayPanel: NSPanel {
    static let normalMinSize = NSSize(width: 380, height: 340)
    static let defaultSize = NSSize(width: 480, height: 680)
    static let compactHeight: CGFloat = 48
    private static let frameKey = "RedCast.frame.v3"

    init<Content: View>(rootView: Content) {
        let frame = OverlayPanel.restoredFrame()
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false   // moved by the header / dock drag areas
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = OverlayPanel.normalMinSize

        // Blurred desktop behind, rounded by a mask (so the shadow is rounded too).
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = OverlayPanel.roundedMask(radius: Theme.radius)
        effect.autoresizingMask = [.width, .height]

        let hosting = FirstClickHostingView(rootView: rootView)
        hosting.sizingOptions = []            // SwiftUI content never resizes the window by itself
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        // Resize zones: left, right, bottom and the bottom corners. The top edge is left free:
        // the whole header moves the window, with no «dead» strips.
        for edge in ResizeHandle.Edge.allCases {
            effect.addSubview(ResizeHandle(edge: edge, in: effect.bounds))
        }
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Saved frame of the expanded window. The strip (compact) size is never saved, so
    /// the window can't come back as a squeezed 52-pixel bar after a restart.
    static func restoredFrame() -> NSRect {
        let d = UserDefaults.standard
        var r = d.string(forKey: frameKey).map(NSRectFromString) ?? .zero
        if r == .zero, let legacy = d.string(forKey: "NSWindow Frame RedCastMain") {
            let p = legacy.split(separator: " ").compactMap { Double($0) }
            if p.count >= 4 { r = NSRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
        }
        if r == .zero, let vf = NSScreen.main?.visibleFrame {
            return NSRect(x: vf.maxX - defaultSize.width - 24, y: vf.maxY - defaultSize.height - 24,
                          width: defaultSize.width, height: defaultSize.height)
        }
        if r.height < normalMinSize.height {
            let top = r.maxY
            r.size.height = defaultSize.height
            r.origin.y = top - r.height
        }
        r.size.width = max(r.width, normalMinSize.width)
        return r
    }

    func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

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
            case "w": OverlayController.shared.hide(); return true
            case ",": OverlayController.shared.showSettings(); return true
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

enum MainTab: String { case hints, settings }

@MainActor
final class OverlayController: ObservableObject {
    static let shared = OverlayController()

    @Published var tab: MainTab = .hints
    @Published var settingsSection: SettingsSection = .model
    @Published private(set) var compact = false
    @Published private(set) var clickThrough = false

    private var panel: OverlayPanel?
    private var expandedFrame: NSRect?
    private var observers: [NSObjectProtocol] = []
    var window: NSWindow? { panel }

    func show() {
        if panel == nil {
            let p = OverlayPanel(rootView: MainView()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
                .environmentObject(HotKeyStore.shared)
                .environmentObject(self))
            panel = p
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: p, queue: .main) { _ in
                    MainActor.assumeIsolated { OverlayController.shared.frameChanged() }
                })
            }
        }
        applySharing()
        keepOnScreen()
        panel?.orderFrontRegardless()
    }

    private func frameChanged() {
        guard let panel else { return }
        panel.invalidateShadow()
        if !compact { panel.saveFrame() }
    }

    /// Bring the window back if it ended up outside every screen (monitor unplugged, resized…).
    private func keepOnScreen() {
        guard let panel, let main = NSScreen.main else { return }
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame.insetBy(dx: 40, dy: 20)) }
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

    func showSettings(_ section: SettingsSection? = nil) {
        if compact { toggleCompact() }
        if let section { settingsSection = section }
        tab = .settings
        show()
        panel?.makeKey()
    }

    /// Snapshot tool only: flips the layout without touching the window.
    func setCompactFlag(_ on: Bool) { compact = on }

    func toggleSettings() {
        if tab == .settings { tab = .hints } else { showSettings() }
    }

    func applySharing() {
        panel?.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
        panel?.alphaValue = AppSettings.shared.overlayOpacity
    }

    /// Runs a modal dialog (file picker, alert) above the floating window instead of under it.
    func runModal<T>(_ body: () -> T) -> T {
        let saved = panel?.level ?? .statusBar
        panel?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        defer { panel?.level = saved }
        return body()
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

        Совсем закрыть: значок волны → «Выйти» или «Настройки» → «О программе» → «Выйти из RedCast».
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
            let target = expandedFrame ?? NSRect(origin: panel.frame.origin, size: OverlayPanel.defaultSize)
            compact = false
            panel.minSize = OverlayPanel.normalMinSize
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - target.height,
                                  width: target.width, height: target.height), display: true, animate: true)
        } else {
            expandedFrame = panel.frame
            compact = true
            tab = .hints
            let h = OverlayPanel.compactHeight
            panel.minSize = NSSize(width: 340, height: h)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: h)
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - h, width: max(panel.frame.width, 460), height: h),
                           display: true, animate: true)
        }
        panel.invalidateShadow()
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

    /// Quick window sizes (menu bar → «Размер окна», Settings → Window). Keeps the window on screen.
    func setSize(_ preset: SizePreset) {
        if compact { toggleCompact() }
        show()
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var size: NSSize
        switch preset {
        case .small: size = NSSize(width: 400, height: 500)
        case .medium: size = NSSize(width: 480, height: 680)
        case .large: size = NSSize(width: 680, height: 880)
        case .tall: size = NSSize(width: max(panel.frame.width, 480), height: vf.height - 16)
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
        AppState.shared.note = clickThrough
            ? "Сквозные клики: \(HotKeyStore.shared.combos[.clickThrough]?.display ?? "") — выключить"
            : nil
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

/// Empty space that moves the window (native drag: smooth, snaps like any window).
/// Double click runs `onDoubleClick` (the header folds the window into a strip).
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

extension View {
    /// The empty background of this view moves the window. Put labels on top with
    /// `.allowsHitTesting(false)` so they move it too.
    func windowDrag(onDoubleClick: (() -> Void)? = nil) -> some View {
        background(WindowDragArea(onDoubleClick: onDoubleClick))
    }
}

/// Invisible strip along a window edge / corner that resizes the borderless window.
final class ResizeHandle: NSView {
    enum Edge: CaseIterable { case left, right, bottom, bottomLeft, bottomRight }

    static let thickness: CGFloat = 5
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
        // Side strips stop below the header (top 50 pt), so the header corners always move the window.
        case .left: frame = NSRect(x: 0, y: c, width: t, height: max(0, b.height - c - 50)); mask = [.height, .maxXMargin]
        case .right: frame = NSRect(x: b.width - t, y: c, width: t, height: max(0, b.height - c - 50)); mask = [.height, .minXMargin]
        case .bottom: frame = NSRect(x: c, y: 0, width: b.width - 2 * c, height: t); mask = [.width, .maxYMargin]
        case .bottomLeft: frame = NSRect(x: 0, y: 0, width: c, height: c); mask = [.maxXMargin, .maxYMargin]
        case .bottomRight: frame = NSRect(x: b.width - c, y: 0, width: c, height: c); mask = [.minXMargin, .maxYMargin]
        }
        super.init(frame: frame)
        autoresizingMask = mask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The strip is moved, not stretched: only its width can change.
        let compact = MainActor.assumeIsolated { OverlayController.shared.compact }
        if compact && edge != .left && edge != .right { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if #available(macOS 15.0, *) {
            switch edge {
            case .left: cursor = .frameResize(position: .left, directions: .all)
            case .right: cursor = .frameResize(position: .right, directions: .all)
            case .bottom: cursor = .frameResize(position: .bottom, directions: .all)
            case .bottomLeft: cursor = .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: cursor = .frameResize(position: .bottomRight, directions: .all)
            }
        } else {
            cursor = (edge == .left || edge == .right) ? .resizeLeftRight : .resizeUpDown
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
        if [.right, .bottomRight].contains(edge) {
            f.size.width = min(maxW, max(minW, startFrame.width + dx))
        }
        if [.left, .bottomLeft].contains(edge) {
            let width = min(maxW, max(minW, startFrame.width - dx))
            f.origin.x = startFrame.maxX - width
            f.size.width = width
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
                    HeaderBar()
                    if let err = state.errorMessage {
                        ErrorBanner(text: err, permission: state.errorIsPermission)
                    }
                    if ui.tab == .hints {
                        if state.updateAvailable != nil { UpdateBanner() }
                        FeedView()
                        TranscriptDrawer()
                        ControlDock()
                    } else {
                        SettingsPane()
                    }
                }
            }
        }
        .foregroundStyle(Theme.fg)
        .background(Theme.glass)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .tint(Theme.fg2)
        .onChange(of: settings.hideFromScreenShare) { OverlayController.shared.applySharing() }
        .onChange(of: settings.overlayOpacity) { OverlayController.shared.applySharing() }
        .onChange(of: settings.showInDock) { OverlayController.applyDockPolicy() }
    }
}

/// What RedCast is doing right now, in plain words (header and strip).
@MainActor
enum Phase {
    static func title(_ state: AppState) -> String {
        if let note = state.note { return note }
        if let speaker = state.recording.first {
            return speaker == .interviewer ? "Запись: интервьюер" : "Запись: вы"
        }
        if !state.recognizing.isEmpty { return "Распознаю…" }
        if let a = state.answers.last, a.isStreaming, a.id == state.currentAnswerID {
            return a.text.isEmpty ? "Думаю…" : "Отвечаю…"
        }
        if state.isStarting { return "Запуск…" }
        if state.isListening {
            return state.speaking.contains(.interviewer) ? "Интервьюер говорит…" : "Слушаю"
        }
        if state.modelProgress != nil { return "Скачиваю модель речи" }
        if !state.modelReady && !state.modelFailed { return "Загружаю распознавание…" }
        return "Готов"
    }

    static func onAir(_ state: AppState) -> Bool { state.isListening || !state.recording.isEmpty }
}

struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    private var subtitle: String {
        if state.modelProgress != nil || (!state.modelReady && !state.modelFailed) { return state.modelStatus }
        if state.modelFailed { return "Ошибка модели речи — откройте настройки" }
        let mode = settings.listenMode == .manual ? "по кнопкам" : "авто"
        return "\(settings.backend.shortTitle) · \(modelName) · \(mode)"
    }

    private var modelName: String {
        if settings.backend.provider != nil { return settings.providerModel.isEmpty ? "модель не выбрана" : settings.providerModel }
        return Catalog.claudeModels.first { $0.id == settings.model }?.title.components(separatedBy: " —").first ?? settings.model
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Tally(on: Phase.onAir(state), starting: state.isStarting)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Phase.title(state)).font(.system(size: 13, weight: .semibold))
                        if let speaker = state.recording.first, let since = state.recordingSince[speaker] {
                            ElapsedText(since: since).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.fg3)
                }
                .lineLimit(1)
            }
            .allowsHitTesting(false)
            Spacer(minLength: 6)
            if Phase.onAir(state) { ChannelMeters().allowsHitTesting(false) }
            HStack(spacing: 2) {
                IconButton(symbol: ui.tab == .settings ? "gearshape.fill" : "gearshape",
                           help: ui.tab == .settings ? "Вернуться к подсказкам" : "Настройки (⌘,)",
                           selected: ui.tab == .settings) { ui.toggleSettings() }
                IconButton(symbol: "minus", help: "Свернуть в полоску (двойной клик по шапке)") {
                    ui.toggleCompact()
                }
                IconButton(symbol: "xmark", help: "Скрыть окно (⌘W). Вернуть — значок волны в строке меню", size: 12) {
                    ui.hide()
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            if let p = state.modelProgress {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.fg2).frame(height: 2).padding(.horizontal, 12)
            } else {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .windowDrag { ui.toggleCompact() }
    }
}

/// Two console-style meters: the call (interviewer) and the microphone.
struct ChannelMeters: View {
    @ObservedObject private var levels = AudioLevels.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            meter("headphones", levels.system, active: state.isListening || state.recording.contains(.interviewer))
            meter("mic", levels.mic, active: (state.isListening && state.settings.captureMic) || state.recording.contains(.me))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Theme.bgDeep))
        .help("Уровень звука: созвон и микрофон")
    }

    private func meter(_ symbol: String, _ level: Float, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(active ? Theme.fg2 : Theme.idle)
            LevelMeter5(level: level, active: active)
        }
    }
}

/// Level of one channel (inside a record button).
struct ChannelLevel: View {
    let speaker: Speaker
    @ObservedObject private var levels = AudioLevels.shared
    var body: some View {
        LevelMeter5(level: speaker == .interviewer ? levels.system : levels.mic)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var state: AppState
    let text: String
    let permission: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 12.5)).lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if permission {
                    Text("Если переключатель уже включён, macOS помнит прошлую версию RedCast. «Сбросить» — RedCast перезапустится, и macOS спросит доступ заново.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Сбросить и перезапустить") { Updater.resetScreenPermissionAndRelaunch() }
                            .buttonStyle(RCButtonStyle(kind: .primary, height: 26, padding: 10, fontSize: 12))
                        Button("Открыть настройки macOS") { state.openPrivacySettings("Privacy_ScreenCapture") }
                            .buttonStyle(RCButtonStyle(height: 26, padding: 10, fontSize: 12))
                    }
                }
            }
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Закрыть", size: 10, box: 24) { state.errorMessage = nil }
                .padding(.top, -4)
        }
        .padding(.leading, 12)
        .padding(.vertical, 10)
        .padding(.trailing, 6)
        .card(Theme.surface, radius: 11, stroke: Theme.warning.opacity(0.35))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.positive).frame(width: 7, height: 7)
            Text(state.isUpdating ? state.updateStatus : "Доступна версия \(state.updateAvailable?.version ?? "")")
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer()
            if state.isUpdating {
                ProgressView().controlSize(.small)
            } else {
                Button("Обновить") { Task { await state.installUpdate() } }
                    .buttonStyle(RCButtonStyle(kind: .primary, height: 26, padding: 12, fontSize: 12))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .card(radius: 11)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

// MARK: - Compact strip

struct CompactBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    private var lastLine: String {
        guard let a = state.answers.last else { return Phase.title(state) }
        if let e = a.error { return e }
        let first = a.text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
        return first.isEmpty ? Phase.title(state) : MarkdownText.plain(first)
    }

    var body: some View {
        HStack(spacing: 4) {
            Tally(on: Phase.onAir(state), starting: state.isStarting, size: 8)
                .allowsHitTesting(false)
            if settings.listenMode == .auto {
                IconButton(symbol: state.isListening ? "stop.fill" : "play.fill",
                           help: state.isListening ? "Стоп" : "Начать слушать",
                           tint: state.isListening ? Theme.accent : Theme.fg) { state.toggleListening() }
                IconButton(symbol: "bolt.fill", help: "Ответить сейчас") { state.answerNow() }
            } else {
                compactRecord(.interviewer, symbol: "headphones")
                compactRecord(.me, symbol: "mic.fill")
            }
            IconButton(symbol: "camera.viewfinder", help: "Задача со скриншота") { state.solveScreenshot() }
            Text(lastLine)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .allowsHitTesting(false)
            IconButton(symbol: "rectangle.expand.vertical", help: "Развернуть (двойной клик по полоске)") { ui.toggleCompact() }
            IconButton(symbol: "xmark", help: "Скрыть окно", size: 12) { ui.hide() }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .windowDrag { ui.toggleCompact() }
    }

    private func compactRecord(_ speaker: Speaker, symbol: String) -> some View {
        let rec = state.recording.contains(speaker)
        return IconButton(symbol: rec ? "stop.fill" : symbol,
                          help: speaker == .interviewer ? "Интервьюер: запись → ответ" : "Я: запись → подсказка",
                          tint: rec ? Theme.accent : Theme.fg2, selected: rec) { state.toggleRecord(speaker) }
    }
}

// MARK: - Feed

struct FeedView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if state.answers.isEmpty {
                        ReadinessView()
                    }
                    ForEach(state.answers) { item in
                        AnswerCard(item: item, fontSize: settings.fontSize, isCurrent: item.id == state.currentAnswerID) {
                            withAnimation(Theme.spring) { state.toggleExpanded(item.id) }
                        }
                        .id(item.id)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .onChange(of: state.answers.last?.id) {
                if let id = state.answers.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct AnswerCard: View {
    let item: AnswerItem
    let fontSize: Double
    var isCurrent = false
    var onToggle: () -> Void = {}
    @State private var copied = false

    private static func seconds(_ s: Double) -> String {
        String(format: "%.1f с", s).replacingOccurrences(of: ".", with: ",")
    }

    private var preview: String {
        let line = item.text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return line.map { MarkdownText.plain(String($0)) } ?? (item.isStreaming ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: item.expanded ? 10 : 4) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.fg3)
                        .frame(width: 10)
                    Text(item.question)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(item.expanded ? 4 : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.expanded ? "Свернуть ответ" : "Развернуть ответ")

            if item.expanded {
                if item.text.isEmpty && item.isStreaming {
                    ThinkingDots().padding(.vertical, 4).padding(.leading, 18)
                } else {
                    MarkdownText(text: item.text, fontSize: fontSize)
                }
            } else {
                Text(preview)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 18)
            }
            if let err = item.error {
                Text(err).font(.system(size: 12.5)).foregroundStyle(Theme.negative).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.expanded && (item.firstTokenSeconds != nil || item.recognitionSeconds != nil) {
                HStack(spacing: 10) {
                    if let r = item.recognitionSeconds {
                        Label(Self.seconds(r), systemImage: "waveform").help("Распознавание после конца вопроса")
                    }
                    if let t = item.firstTokenSeconds {
                        Label(Self.seconds(t), systemImage: "bolt.fill").help("Первые слова ответа после отправки вопроса")
                    }
                    Spacer()
                    if !item.isStreaming && !item.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.fg3)
                .labelStyle(CompactLabelStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, item.expanded ? 12 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isCurrent ? Theme.surface : Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isCurrent {
                // On-air rule: the answer being read right now
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3).padding(.vertical, 12)
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Readiness (empty state)

struct ReadinessView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hotkeys: HotKeyStore
    @EnvironmentObject var ui: OverlayController

    private enum Status { case ok, warn, busy, idle }

    private func key(_ a: HotKeyAction) -> String { hotkeys.combos[a]?.display ?? "—" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                checklist
                howTo
            }
        }
    }

    private var checklist: some View {
        let screen = CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        return VStack(spacing: 0) {
            row(state.modelReady ? .ok : (state.modelFailed ? .warn : .busy),
                "Распознавание речи",
                state.modelReady ? "Whisper на этом Mac · \(settings.speechLanguage.title)" : state.modelStatus) {
                if state.modelFailed {
                    Button("Скачать заново") { Task { await state.redownloadSpeechModel() } }
                        .buttonStyle(RCButtonStyle(height: 24, padding: 9, fontSize: 11.5))
                }
            }
            divider
            row(state.connectionProblem == nil ? .ok : .warn,
                "Модель ИИ",
                state.connectionProblem ?? "\(settings.backend.shortTitle) · \(settings.activeModel)") {
                if state.connectionProblem == nil {
                    Button("Проверить") { state.testConnection() }
                        .buttonStyle(RCButtonStyle(height: 24, padding: 9, fontSize: 11.5))
                } else {
                    Button("Настроить") { ui.showSettings(.model) }
                        .buttonStyle(RCButtonStyle(kind: .primary, height: 24, padding: 9, fontSize: 11.5))
                }
            }
            divider
            row(screen ? .ok : .warn, "Звук созвона",
                screen ? "Доступ к звуку системы есть" : "Нужно разрешение «Запись экрана и системного звука»") {
                if !screen {
                    Button("Разрешить") {
                        if !CGRequestScreenCaptureAccess() { state.openPrivacySettings("Privacy_ScreenCapture") }
                    }
                    .buttonStyle(RCButtonStyle(height: 24, padding: 9, fontSize: 11.5))
                }
            }
            divider
            row(mic == .authorized ? .ok : (mic == .notDetermined ? .idle : .warn), "Микрофон",
                mic == .authorized ? "Доступ есть" : (mic == .notDetermined ? "Спросим при первой записи" : "Доступ запрещён в настройках macOS")) {
                if mic == .denied || mic == .restricted {
                    Button("Открыть") { state.openPrivacySettings("Privacy_Microphone") }
                        .buttonStyle(RCButtonStyle(height: 24, padding: 9, fontSize: 11.5))
                }
            }
        }
        .card(radius: 12)
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 40) }

    private func row<Action: View>(_ status: Status, _ title: String, _ detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Group {
                switch status {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
                case .busy: ProgressView().controlSize(.small)
                case .idle: Image(systemName: "circle.dashed").foregroundStyle(Theme.fg3)
                }
            }
            .font(.system(size: 15))
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.fg3).lineLimit(2)
            }
            Spacer(minLength: 6)
            action()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.listenMode == .manual ? "Режим «По кнопкам»" : "Режим «Авто»")
                .font(.system(size: 13, weight: .semibold))
            if settings.listenMode == .manual {
                step(key(.recordInterviewer), "Интервьюер начал вопрос — нажмите. Закончил — нажмите ещё раз: ответ появится почти сразу.")
                step(key(.recordMe), "То же для вашего микрофона: повторите вопрос вслух или начните отвечать — RedCast подскажет.")
            } else {
                step(key(.toggleListening), "Начать / остановить. RedCast сам ловит вопросы интервьюера и отвечает после паузы.")
                step(key(.answerNow), "Ответить сразу, не дожидаясь паузы.")
            }
            step(key(.screenshot), "Решить задачу с экрана (live coding, тест).")
            step(key(.toggleWindow), "Спрятать / показать окно.")
            Text("Окно не видно собеседнику при демонстрации экрана. Перетаскивайте его за шапку, размер — за края.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func step(_ combo: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            KeyCap(text: combo, minWidth: 50)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Transcript

struct TranscriptDrawer: View {
    @EnvironmentObject var state: AppState
    @AppStorage("showTranscript") private var showTranscript = true

    private var lastLine: String? {
        if let p = state.partial[.interviewer] ?? state.partial[.me] { return p }
        return state.entries.last.map { "\($0.speaker.label): \($0.text)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.spring) { showTranscript.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTranscript ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text("Расшифровка").font(.system(size: 11.5, weight: .semibold))
                    if !showTranscript, let line = lastLine {
                        Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    if state.partial[.interviewer] != nil || state.partial[.me] != nil {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(Theme.fg2)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showTranscript { transcript }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if state.entries.isEmpty && state.partial.isEmpty {
                        Text(state.isListening || !state.recording.isEmpty ? "Жду речь…" : "Здесь появится текст разговора")
                            .font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(state.entries.suffix(40)) { e in
                        line(e.speaker, e.text, live: false, seconds: e.recognitionSeconds)
                    }
                    if let p = state.partial[.interviewer] { line(.interviewer, p, live: true) }
                    if let p = state.partial[.me] { line(.me, p, live: true) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.entries.count) { proxy.scrollTo("end") }
            .onChange(of: state.partial) { proxy.scrollTo("end") }
        }
        .frame(height: state.entries.isEmpty && state.partial.isEmpty ? 30 : 92)
    }

    /// The interviewer reads as primary text, «Я» as muted; live (unfinished) lines are dimmer.
    private func line(_ speaker: Speaker, _ text: String, live: Bool, seconds: Double? = nil) -> some View {
        let tag = Text(speaker == .interviewer ? "Интервьюер  " : "Я  ")
            .foregroundColor(speaker == .interviewer ? Theme.accent.opacity(live ? 0.6 : 0.9) : Theme.fg3)
            .fontWeight(.semibold)
        let body = Text(text).foregroundColor(live ? Theme.fg3 : (speaker == .interviewer ? Theme.fg : Theme.fg2))
        let time = seconds.map {
            Text(String(format: "  %.1f с", $0).replacingOccurrences(of: ".", with: ",")).foregroundColor(Theme.fg3.opacity(0.7))
        } ?? Text("")
        return (tag + body + time)
            .font(.system(size: 12.5).monospacedDigit())
            .help(seconds.map { String(format: "Распознано за %.1f с после конца фразы", $0) } ?? "")
            .lineSpacing(2)
            .textSelection(.enabled)
    }
}

// MARK: - Control dock

struct ControlDock: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hotkeys: HotKeyStore
    @State private var question = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if settings.listenMode == .manual {
                HStack(spacing: 8) {
                    RecordButton(speaker: .interviewer)
                    RecordButton(speaker: .me)
                }
            } else {
                HStack(spacing: 8) {
                    StartButton()
                    Button { state.answerNow() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "bolt.fill").foregroundStyle(Theme.warning)
                            Text("Ответить сейчас")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RCButtonStyle(height: 44, padding: 12, fontSize: 13.5, radius: 11))
                    .help("Не ждать паузы" + (hotkeys.combos[.answerNow].map { " (\($0.display))" } ?? ""))
                }
            }
            HStack(spacing: 6) {
                Segmented(selection: settings.listenMode,
                          items: ListenMode.allCases.map { (value: $0, title: $0.title) }, height: 24) { state.setMode($0) }
                    .fixedSize()
                    .help("Авто — слушает всё и отвечает сам. По кнопкам — вы отмечаете начало и конец вопроса.")
                askField
                IconButton(symbol: "camera.viewfinder",
                           help: "Решить задачу с экрана" + (hotkeys.combos[.screenshot].map { " (\($0.display))" } ?? ""),
                           size: 13, box: 30) { state.solveScreenshot() }
                IconButton(symbol: "trash", help: "Очистить подсказки и расшифровку", size: 12, box: 30) { state.clear() }
            }
        }
        .padding(10)
        .background(Theme.bgDeep)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .windowDrag()
    }

    private var askField: some View {
        HStack(spacing: 6) {
            TextField("", text: $question, prompt: Text("Спросить текстом…").foregroundColor(Theme.fg3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($askFocused)
                .onSubmit(send)
            if !question.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.fg)
                }
                .buttonStyle(.plain)
                .help("Отправить (Enter)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .card(Theme.surface, radius: 9, stroke: askFocused ? Theme.fg3 : Theme.lineStrong)
    }

    private func send() {
        state.askManual(question)
        question = ""
    }
}

/// «Авто»: the one primary action. On air it turns red with the live tally.
struct StartButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            state.toggleListening()
        } label: {
            HStack(spacing: 8) {
                if state.isStarting {
                    ProgressView().controlSize(.small)
                } else if state.isListening {
                    Tally(on: true, size: 7)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(state.isListening ? "Стоп" : (state.isStarting ? "Запуск…" : "Начать слушать"))
                if state.isListening {
                    ChannelLevel(speaker: .interviewer)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RCButtonStyle(kind: state.isListening ? .live : .primary, height: 44, padding: 12, fontSize: 13.5, radius: 11))
        .help(state.isListening ? "Остановить прослушивание" : "Начать слушать созвон")
    }
}

/// «По кнопкам»: 1st press — record this channel, 2nd press — recognise and answer.
struct RecordButton: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hotkeys: HotKeyStore
    let speaker: Speaker

    private var isRecording: Bool { state.recording.contains(speaker) }
    private var isRecognizing: Bool { state.recognizing.contains(speaker) }
    private var action: HotKeyAction { speaker == .interviewer ? .recordInterviewer : .recordMe }
    private var symbol: String { speaker == .interviewer ? "headphones" : "mic.fill" }
    private var title: String { speaker == .interviewer ? "Интервьюер" : "Я" }
    private var help: String {
        speaker == .interviewer
            ? "Нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил: получите ответ"
            : "Нажмите и говорите (например, повторите вопрос), нажмите ещё раз — получите подсказку"
    }

    var body: some View {
        Button {
            state.toggleRecord(speaker)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if isRecording {
                        Tally(on: true, size: 8)
                    } else if isRecognizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.fg2)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isRecording ? "Ответить" : title)
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        if isRecording, let since = state.recordingSince[speaker] {
                            ElapsedText(since: since).foregroundStyle(Theme.accent)
                            ChannelLevel(speaker: speaker)
                        } else if isRecognizing {
                            Text("распознаю…")
                        } else if let combo = hotkeys.combos[action]?.display {
                            KeyCap(text: combo, size: 10)
                        } else {
                            Text("нажмите, чтобы записать")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.fg3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(RCButtonStyle(kind: isRecording ? .live : .secondary, height: 58, padding: 0, radius: 11))
        .help(help)
    }
}

// MARK: - Markdown

/// Markdown for answers: paragraphs with inline formatting, headings, bullet and numbered
/// lists with hanging indents, fenced code blocks.
struct MarkdownText: View {
    let text: String
    let fontSize: Double

    private enum Kind { case paragraph(String), heading(String), item(marker: String, text: String, level: Int), code(String) }
    private struct Block: Identifiable { let id: Int; let kind: Kind }

    private var blocks: [Block] {
        var out: [Kind] = []
        let pieces = text.components(separatedBy: "```")
        for (i, piece) in pieces.enumerated() {
            if i % 2 == 1 {
                var lines = piece.components(separatedBy: "\n")
                if let first = lines.first, !first.contains(" "), lines.count > 1 { lines.removeFirst() }
                let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !code.isEmpty { out.append(.code(code)) }
                continue
            }
            var paragraph: [String] = []
            func flush() {
                let p = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.isEmpty { out.append(.paragraph(p)) }
                paragraph.removeAll()
            }
            for raw in piece.components(separatedBy: "\n") {
                let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { flush(); continue }
                if t.hasPrefix("#") {
                    flush()
                    out.append(.heading(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                    flush()
                    out.append(.item(marker: "•", text: String(t.dropFirst(2)), level: min(2, indent / 2)))
                } else if let r = t.range(of: #"^\d{1,2}[.)]\s"#, options: .regularExpression) {
                    flush()
                    out.append(.item(marker: String(t[r]).trimmingCharacters(in: .whitespaces),
                                     text: String(t[r.upperBound...]), level: min(2, indent / 2)))
                } else {
                    paragraph.append(t)
                }
            }
            flush()
        }
        return out.enumerated().map { Block(id: $0.offset, kind: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.42) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph(let s):
                    inline(s)
                case .heading(let s):
                    inline(s).font(.system(size: fontSize, weight: .semibold)).padding(.top, 2)
                case .item(let marker, let s, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker)
                            .font(.system(size: fontSize, weight: marker == "•" ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(marker == "•" ? Theme.accent.opacity(0.85) : Theme.fg3)
                            .frame(minWidth: 10, alignment: .leading)
                        inline(s)
                    }
                    .padding(.leading, CGFloat(level) * 14)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .foregroundStyle(Theme.fg)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    private func inline(_ s: String) -> some View {
        Text(Self.attributed(s, fontSize: fontSize))
            .font(.system(size: fontSize))
            .foregroundStyle(Theme.fg)
            .lineSpacing(fontSize * 0.32)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func attributed(_ s: String, fontSize: Double) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) {
                result[run.range].font = .system(size: fontSize, weight: .semibold)
            }
            if intent.contains(.code) {
                result[run.range].font = .system(size: fontSize - 1, design: .monospaced)
                result[run.range].backgroundColor = Theme.raised
            }
        }
        return result
    }

    /// Text without Markdown marks (for one-line previews).
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#-*• ").union(.whitespaces))
    }
}
