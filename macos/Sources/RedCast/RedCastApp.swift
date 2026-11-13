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
            Divider()
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
        MainActor.assumeIsolated {
            OverlayController.shared.show()
            HotKeyStore.shared.registerAll()
            Task { await AppState.shared.loadSpeechModel() }
            AppState.shared.prewarmLLM()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.stop()
        }
    }
}
