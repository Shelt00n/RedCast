import AppKit
import Carbon

// MARK: - Model

struct HotKeyCombo: Equatable {
    var keyCode: Int
    var modifiers: Int      // Carbon modifier mask (cmdKey | optionKey | …)
    var keyLabel: String

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + keyLabel
    }

    var serialized: String { "\(keyCode)|\(modifiers)|\(keyLabel)" }

    init(keyCode: Int, modifiers: Int, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(serialized: String) {
        let p = serialized.components(separatedBy: "|")
        guard p.count == 3, let k = Int(p[0]), let m = Int(p[1]) else { return nil }
        self.init(keyCode: k, modifiers: m, keyLabel: p[2])
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let c = event.charactersIgnoringModifiers ?? "?"
            return c.uppercased()
        }
    }
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case toggleListening, recordInterviewer, recordMe, answerNow, screenshot, toggleWindow, toggleCompact
    case scrollUp, scrollDown, stopAnswer, clickThrough, clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleListening: return "Авто: старт / стоп"
        case .recordInterviewer: return "По кнопкам: записать интервьюера → ответ"
        case .recordMe: return "По кнопкам: записать меня → ответ"
        case .answerNow: return "Ответить сейчас"
        case .screenshot: return "Скриншот → решение задачи"
        case .toggleWindow: return "Скрыть / показать окно"
        case .toggleCompact: return "Свернуть / развернуть окно"
        case .scrollUp: return "Прокрутить подсказку вверх"
        case .scrollDown: return "Прокрутить подсказку вниз"
        case .stopAnswer: return "Остановить ответ"
        case .clickThrough: return "Сквозные клики"
        case .clear: return "Очистить"
        }
    }

    var defaultCombo: HotKeyCombo {
        let m = controlKey | optionKey
        switch self {
        case .toggleListening: return HotKeyCombo(keyCode: kVK_ANSI_L, modifiers: m, keyLabel: "L")
        case .recordInterviewer: return HotKeyCombo(keyCode: kVK_ANSI_1, modifiers: m, keyLabel: "1")
        case .recordMe: return HotKeyCombo(keyCode: kVK_ANSI_2, modifiers: m, keyLabel: "2")
        case .answerNow: return HotKeyCombo(keyCode: kVK_Space, modifiers: m, keyLabel: "Space")
        case .screenshot: return HotKeyCombo(keyCode: kVK_ANSI_S, modifiers: m, keyLabel: "S")
        case .toggleWindow: return HotKeyCombo(keyCode: kVK_ANSI_H, modifiers: m, keyLabel: "H")
        case .toggleCompact: return HotKeyCombo(keyCode: kVK_ANSI_M, modifiers: m, keyLabel: "M")
        case .scrollUp: return HotKeyCombo(keyCode: kVK_UpArrow, modifiers: m, keyLabel: "↑")
        case .scrollDown: return HotKeyCombo(keyCode: kVK_DownArrow, modifiers: m, keyLabel: "↓")
        case .stopAnswer: return HotKeyCombo(keyCode: kVK_ANSI_Period, modifiers: m, keyLabel: ".")
        case .clickThrough: return HotKeyCombo(keyCode: kVK_ANSI_T, modifiers: m, keyLabel: "T")
        case .clear: return HotKeyCombo(keyCode: kVK_ANSI_X, modifiers: m, keyLabel: "X")
        }
    }

    @MainActor
    func perform() {
        let state = AppState.shared
        let overlay = OverlayController.shared
        switch self {
        case .toggleListening: state.toggleListening()
        case .recordInterviewer: state.toggleRecord(.interviewer)
        case .recordMe: state.toggleRecord(.me)
        case .answerNow: state.answerNow()
        case .screenshot: state.solveScreenshot()
        case .toggleWindow: overlay.toggleVisible()
        case .toggleCompact: overlay.toggleCompact()
        case .scrollUp: overlay.scroll(by: -140)
        case .scrollDown: overlay.scroll(by: 140)
        case .stopAnswer: state.stopAnswer()
        case .clickThrough: overlay.toggleClickThrough()
        case .clear: state.clear()
        }
    }
}

// MARK: - Store (UserDefaults) + registration

@MainActor
final class HotKeyStore: ObservableObject {
    static let shared = HotKeyStore()

    @Published private(set) var combos: [HotKeyAction: HotKeyCombo] = [:]
    @Published private(set) var failed: Set<HotKeyAction> = []

    private init() {
        for action in HotKeyAction.allCases {
            if let s = UserDefaults.standard.string(forKey: "hotkey.\(action.rawValue)") {
                combos[action] = s.isEmpty ? nil : HotKeyCombo(serialized: s)
            } else {
                combos[action] = action.defaultCombo
            }
        }
    }

    func set(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        // One combo — one action.
        if let combo {
            for (other, c) in combos where other != action && c == combo {
                combos[other] = nil
                UserDefaults.standard.set("", forKey: "hotkey.\(other.rawValue)")
            }
        }
        combos[action] = combo
        UserDefaults.standard.set(combo?.serialized ?? "", forKey: "hotkey.\(action.rawValue)")
        registerAll()
    }

    func resetDefaults() {
        for action in HotKeyAction.allCases {
            combos[action] = action.defaultCombo
            UserDefaults.standard.removeObject(forKey: "hotkey.\(action.rawValue)")
        }
        registerAll()
    }

    func registerAll() {
        HotKeyCenter.shared.unregisterAll()
        var bad: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let c = combos[action] else { continue }
            if !HotKeyCenter.shared.register(keyCode: c.keyCode, modifiers: c.modifiers, handler: { action.perform() }) {
                bad.insert(action)
            }
        }
        failed = bad
    }

    /// While the user records a new shortcut, global hotkeys must not fire.
    func suspend() { HotKeyCenter.shared.unregisterAll() }
}

/// System-wide hotkeys via Carbon (works without Accessibility permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5244_4353), id: id) // 'RDCS'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        handlers[id] = handler
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
