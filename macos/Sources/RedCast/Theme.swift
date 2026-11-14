import SwiftUI

// MARK: - Tokens

/// Graphite ramp + one accent: the on-air tally red of the logo. Same values as windows/App.xaml.
enum Theme {
    static let bg = Color(hex: 0x141415, opacity: 0.96)
    static let bgDeep = Color(hex: 0x0F0F10)
    static let surface = Color(hex: 0x1B1B1D)
    static let raised = Color(hex: 0x242426)
    static let hover = Color(hex: 0x2C2C2F)
    static let line = Color(hex: 0xEDEDED, opacity: 0.08)
    static let lineStrong = Color(hex: 0xEDEDED, opacity: 0.15)
    static let fg = Color(hex: 0xEDEDED)
    static let fg2 = Color(hex: 0xA1A1A6)
    static let fg3 = Color(hex: 0x85858B)
    static let idle = Color(hex: 0x5C5C61)
    static let onFg = Color(hex: 0x141415)
    static let accent = Color(hex: 0xE3141F)
    static let accentSoft = Color(hex: 0xE3141F, opacity: 0.35)
    static let positive = Color(hex: 0x4CC38A)
    static let warning = Color(hex: 0xE8B04B)
    static let negative = Color(hex: 0xF07075)

    static let ease = Animation.easeOut(duration: 0.14)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Buttons

/// primary — off-white fill (one per screen); secondary — raised surface + hairline; ghost — no fill until hover.
/// `live` lights a red hairline (recording / on air), `selected` marks a segment.
struct RCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary
    var live = false
    var selected = false
    var height: CGFloat = 32
    var padding: CGFloat = 12
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        RCButtonBody(configuration: configuration, style: self)
    }
}

private struct RCButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: RCButtonStyle
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    private var fill: Color {
        switch style.kind {
        case .primary: return hover ? .white : Theme.fg
        case .secondary: return hover ? Theme.hover : Theme.raised
        case .ghost: return style.selected ? Theme.hover : (hover ? Theme.raised : .clear)
        }
    }

    private var foreground: Color {
        switch style.kind {
        case .primary: return Theme.onFg
        case .secondary: return Theme.fg
        case .ghost: return style.selected || hover ? Theme.fg : Theme.fg2
        }
    }

    private var stroke: Color {
        if style.live { return Theme.accentSoft }
        switch style.kind {
        case .primary: return .clear
        case .secondary: return Theme.line
        case .ghost: return style.selected ? Theme.line : .clear
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: style.fontSize, weight: style.kind == .primary ? .medium : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, style.padding)
            .frame(minHeight: style.height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hover = $0 }
            .animation(Theme.ease, value: hover)
            .animation(Theme.ease, value: configuration.isPressed)
    }
}

/// 32×32 ghost button with one SF Symbol.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(tint ?? Theme.fg2)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(RCButtonStyle(kind: .ghost, padding: 0))
        .help(help)
    }
}

/// Icon + label for secondary buttons; the icon stays in the muted role.
struct IconLabel: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.fg2)
            Text(title)
        }
    }
}

/// Segmented control drawn in the graphite ramp (the system one is tinted blue).
struct Segmented<T: Hashable>: View {
    let selection: T
    let items: [(value: T, title: String)]
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button(items[i].title) { onSelect(items[i].value) }
                    .buttonStyle(RCButtonStyle(kind: .ghost, selected: items[i].value == selection, height: 28))
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bgDeep))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: - Signature

/// The on-air tally: red while RedCast listens or records. The ring means the interviewer is speaking right now.
struct Tally: View {
    var on: Bool
    var starting = false
    var ring = false

    var body: some View {
        ZStack {
            if ring {
                Circle().strokeBorder(Theme.accentSoft, lineWidth: 2)
            }
            Circle()
                .fill(on ? Theme.accent : (starting ? Theme.warning : Theme.idle))
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
    }
}

/// Keyboard shortcut drawn as a keycap.
struct KeyCap: View {
    let text: String
    var active = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(active ? Theme.fg : Theme.fg2)
            .padding(.horizontal, 8)
            .frame(minWidth: 144, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(active ? Theme.fg2 : Theme.lineStrong, lineWidth: 1))
            .overlay(alignment: .bottom) {
                // a slightly heavier bottom edge, like a physical key
                Rectangle().fill(Theme.lineStrong).frame(height: 1).padding(.horizontal, 4)
            }
    }
}
