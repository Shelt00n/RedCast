import SwiftUI

// MARK: - Tokens

/// «Broadcast console»: smoked graphite glass + one on-air tally red. Same values as windows/App.xaml.
enum Theme {
    static let glass = Color(hex: 0x121214, opacity: 0.82)   // tint over the blurred desktop
    static let bgDeep = Color(hex: 0x0C0C0E, opacity: 0.55)  // dock / inset wells
    static let surface = Color(hex: 0x1C1C20)
    static let raised = Color(hex: 0x26262B)
    static let hover = Color(hex: 0x303036)
    static let line = Color(hex: 0xFFFFFF, opacity: 0.07)
    static let lineStrong = Color(hex: 0xFFFFFF, opacity: 0.13)
    static let fg = Color(hex: 0xF2F2F4)
    static let fg2 = Color(hex: 0xA9A9B2)
    static let fg3 = Color(hex: 0x76767F)
    static let idle = Color(hex: 0x55555C)
    static let onFg = Color(hex: 0x121214)
    static let accent = Color(hex: 0xEE2B36)
    static let accentSoft = Color(hex: 0xEE2B36, opacity: 0.16)
    static let accentLine = Color(hex: 0xEE2B36, opacity: 0.55)
    static let positive = Color(hex: 0x3DD68C)
    static let warning = Color(hex: 0xF5B54A)
    static let negative = Color(hex: 0xFF6B6B)

    static let radius: CGFloat = 14
    static let ease = Animation.easeOut(duration: 0.14)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)
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

extension View {
    /// Rounded surface card with a hairline.
    func card(_ fill: Color = Theme.surface, radius: CGFloat = 12, stroke: Color = Theme.line) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

// MARK: - Buttons

/// primary — light fill (one per screen); secondary — raised surface; ghost — no fill until hover;
/// live — on-air red tint (recording). `selected` marks a segment.
struct RCButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, live }
    var kind: Kind = .secondary
    var selected = false
    var height: CGFloat = 32
    var padding: CGFloat = 12
    var fontSize: CGFloat = 13
    var radius: CGFloat = 9

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
        case .live: return hover ? Color(hex: 0xEE2B36, opacity: 0.24) : Theme.accentSoft
        }
    }

    private var foreground: Color {
        switch style.kind {
        case .primary: return Theme.onFg
        case .secondary, .live: return Theme.fg
        case .ghost: return style.selected || hover ? Theme.fg : Theme.fg2
        }
    }

    private var stroke: Color {
        switch style.kind {
        case .primary: return .clear
        case .secondary: return Theme.line
        case .ghost: return style.selected ? Theme.line : .clear
        case .live: return Theme.accentLine
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        configuration.label
            .font(.system(size: style.fontSize, weight: style.kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, style.padding)
            .frame(minHeight: style.height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hover = $0 }
            .animation(Theme.ease, value: hover)
            .animation(Theme.ease, value: configuration.isPressed)
    }
}

/// Ghost button with one SF Symbol.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var box: CGFloat = 30
    var tint: Color? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? (selected ? Theme.fg : Theme.fg2))
                .frame(width: box, height: box)
        }
        .buttonStyle(RCButtonStyle(kind: .ghost, selected: selected, height: box, padding: 0, radius: 8))
        .help(help)
    }
}

/// Icon + label; the icon stays in the muted role.
struct IconLabel: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(Theme.fg2)
            Text(title)
        }
    }
}

/// Segmented control drawn in the graphite ramp (the system one is tinted blue).
struct Segmented<T: Hashable>: View {
    let selection: T
    let items: [(value: T, title: String)]
    var height: CGFloat = 26
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Button(items[i].title) { onSelect(items[i].value) }
                    .buttonStyle(RCButtonStyle(kind: .ghost, selected: items[i].value == selection,
                                               height: height, padding: 10, fontSize: 12, radius: 7))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bgDeep))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: - Signature

/// The on-air tally: red while RedCast listens or records, with a slow pulse; amber while starting.
struct Tally: View {
    var on: Bool
    var starting = false
    var size: CGFloat = 9
    @State private var pulse = false

    var body: some View {
        ZStack {
            if on {
                Circle()
                    .fill(Theme.accent.opacity(0.35))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(pulse ? 1 : 0.45)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(on ? Theme.accent : (starting ? Theme.warning : Theme.idle))
                .frame(width: size, height: size)
                .shadow(color: on ? Theme.accent.opacity(0.7) : .clear, radius: 4)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { animate() }
        .onChange(of: on) { animate() }
    }

    private func animate() {
        pulse = false
        guard on else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
    }
}

/// A short horizontal level meter (5 segments, like a console channel strip).
struct LevelMeter5: View {
    var level: Float
    var active = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let lit = active && level > Float(i) * 0.17 + 0.03
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (i == 4 ? Theme.warning : Theme.positive) : Theme.lineStrong)
                    .frame(width: 3, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// Keyboard shortcut drawn as a small keycap.
struct KeyCap: View {
    let text: String
    var active = false
    var minWidth: CGFloat = 0
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(active ? Theme.fg : Theme.fg2)
            .padding(.horizontal, 6)
            .frame(minWidth: minWidth, minHeight: size + 9)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(active ? Theme.fg2 : Theme.lineStrong, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.lineStrong).frame(height: 1).padding(.horizontal, 3)
            }
    }
}

/// Three dots while the model thinks.
struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.fg2)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

/// mm:ss since a date, ticking every half second.
struct ElapsedText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 0.5)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit()
        }
    }
}
