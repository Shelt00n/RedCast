import AppKit
import SwiftUI

@main
struct RedCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var hotkeys = HotKeyStore.shared

    private func key(_ a: HotKeyAction) -> String {
        hotkeys.combos[a].map { "   \($0.display)" } ?? ""
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Показать окно" + key(.toggleWindow)) { OverlayController.shared.show() }
            Button((state.isListening ? "Остановить прослушивание" : "Начать прослушивание") + key(.toggleListening)) {
                state.toggleListening()
            }
            Button("Ответить сейчас" + key(.answerNow)) { state.answerNow() }
            Button("Записать интервьюера → ответ" + key(.recordInterviewer)) { state.toggleRecord(.interviewer) }
            Button("Записать меня → ответ" + key(.recordMe)) { state.toggleRecord(.me) }
            Button("Решить задачу с экрана" + key(.screenshot)) { state.solveScreenshot() }
            Menu("Размер окна") {
                ForEach(OverlayController.SizePreset.allCases) { preset in
                    Button(preset.title) { OverlayController.shared.setSize(preset) }
                }
            }
            Divider()
            if let u = state.updateAvailable {
                Button("Обновить до \(u.version)") { Task { await state.installUpdate() } }
            } else {
                Button("Проверить обновления") { Task { await state.checkForUpdates(silent: false) } }
            }
            Button("Настройки…") { OverlayController.shared.showSettings() }
            Button("Выйти") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: state.isListening ? "waveform.circle.fill" : "waveform.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            Task {
                let code = await Updater.selfTest()
                exit(code)
            }
            return
        }
        MainActor.assumeIsolated {
            Updater.adoptStableSignatureIfNeeded()
            OverlayController.applyDockPolicy()
            OverlayController.shared.show()
            HotKeyStore.shared.registerAll()
            Task { await AppState.shared.loadSpeechModel() }
            AppState.shared.prewarmLLM()
            Task { await AppState.shared.checkForUpdates(silent: true) }
            Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
                Task { @MainActor in await AppState.shared.checkForUpdates(silent: true) }
            }
        }
    }

    /// Opening RedCast again (Finder, Spotlight, Launchpad, Dock) shows the hidden window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            OverlayController.shared.show()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.stop()
        }
    }
}
