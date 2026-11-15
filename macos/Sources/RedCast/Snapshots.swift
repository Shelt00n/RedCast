import AppKit
import SwiftUI

/// `RedCast --snapshot <folder>`: renders the window in typical states to PNG files
/// (design review without screen-recording permission). Developer tool only.
@MainActor
enum Snapshots {
    static func run(folder: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = AppState.shared
        let ui = OverlayController.shared
        let size = NSSize(width: 480, height: 680)

        func render(_ name: String, height: CGFloat = 680, width: CGFloat? = nil) async {
            let frame = NSRect(x: 0, y: 0, width: width ?? size.width, height: height)
            let root = MainView()
                .environmentObject(state)
                .environmentObject(AppSettings.shared)
                .environmentObject(HotKeyStore.shared)
                .environmentObject(ui)
                .background(Color(hex: 0x2A2D34))   // stands in for the blurred desktop
            let hosting = NSHostingView(rootView: root)
            hosting.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }

        let savedMode = AppSettings.shared.listenMode
        defer { AppSettings.shared.listenMode = savedMode }
        state.prepareDemo(.empty)
        await render("1-empty")
        state.prepareDemo(.recording)
        await render("2-recording")
        state.prepareDemo(.answers)
        await render("3-answers")
        state.prepareDemo(.auto)
        await render("4-auto")
        ui.tab = .settings
        for section in SettingsSection.allCases {
            ui.settingsSection = section
            await render("5-settings-\(section.rawValue)", height: 760)
        }
        ui.tab = .hints
        ui.setCompactForSnapshot(true)
        await render("6-compact", height: OverlayPanel.compactHeight)
        ui.setCompactForSnapshot(false)
        return 0
    }
}

extension OverlayController {
    func setCompactForSnapshot(_ on: Bool) { setCompactFlag(on) }
}
