import AppKit
import Carbon
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings live inside the main window (tab «Настройки»), not in a separate window.
struct SettingsPane: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var hotkeys: HotKeyStore

    var body: some View {
        Form {
            claudeSection
            speechSection
            profileSection
            windowSection
            hotkeySection
            updateSection
            Section {
                HStack {
                    Button("Открыть папку с записями собеседований") {
                        try? FileManager.default.createDirectory(at: AppState.sessionsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppState.sessionsFolder)
                    }
                    Spacer()
                    Button("Выйти из RedCast") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Claude

    private var claudeSection: some View {
        Section("1. Подключение Claude") {
            Picker("Способ", selection: $settings.backend) {
                ForEach(Backend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if settings.backend == .api {
                SecureField("API-ключ", text: $settings.apiKey, prompt: Text("sk-ant-…"))
                hint("Ключ: platform.claude.com → API Keys. Оплата по факту, отдельно от подписки. Хранится в Связке ключей.")
                Toggle("Fast mode — ещё быстрее вывод (только Opus 5.5, цена ×2)", isOn: $settings.fastMode)
            } else {
                TextField("Путь к claude", text: $settings.claudePath, prompt: Text("пусто = найти автоматически"))
                hint("Один раз в Терминале: claude → /login. Расходует лимит вашей подписки.")
            }

            Picker("Модель", selection: $settings.model) {
                ForEach(Catalog.claudeModels) { Text($0.title).tag($0.id) }
            }
            Picker("Глубина размышлений", selection: $settings.effort) {
                ForEach(Catalog.efforts) { Text($0.title).tag($0.id) }
            }
            Button("Проверить соединение") {
                state.askManual("Тест связи: ответь одним словом «работает».")
                OverlayController.shared.tab = .hints
            }
        }
    }

    // MARK: Speech

    private var speechSection: some View {
        Section("2. Распознавание речи") {
            Picker("Язык собеседования", selection: $settings.speechLanguage) {
                ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker("Модель", selection: $settings.whisperModel) {
                ForEach(Catalog.whisperModels) { Text($0.title).tag($0.id) }
            }
            HStack {
                Text(state.modelStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Перезагрузить") { Task { await state.loadSpeechModel() } }
                Button("Скачать модель заново") { Task { await state.redownloadSpeechModel() } }
                    .help("Если модель повреждена: удалить её и скачать чистую копию (~1,6 ГБ)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Словарь терминов (технологии, компании, имена)")
                TextEditor(text: $settings.vocabulary)
                    .font(.system(size: 12))
                    .frame(height: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $settings.silenceMs, in: 400...1500, step: 50) {
                    Text("Пауза конца вопроса: \(Int(settings.silenceMs)) мс")
                }
                hint("Меньше — быстрее подсказка, но вопрос чаще разбивается на части.")
            }
            Picker("Режим", selection: Binding(get: { settings.listenMode }, set: { state.setMode($0) })) {
                ForEach(ListenMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            hint("Авто — RedCast сам слышит вопросы и отвечает. По кнопкам — две кнопки «Интервьюер» и «Я»: первое нажатие начинает запись, второе даёт ответ. Никакой путаницы и ответов на старые вопросы.")
            Toggle("Авто: отвечать на каждую реплику интервьюера", isOn: $settings.autoAnswer)
            Toggle("Авто: распознавать мой микрофон (чтобы понимать, что я уже ответил)", isOn: $settings.captureMic)
            Toggle("Эхоподавление микрофона (если вы без наушников)", isOn: $settings.echoCancellation)
            hint("Убирает из микрофона голос интервьюера из динамиков, чтобы его слова не записывались как ваши. Лучше всего — наушники.")
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("3. Профиль кандидата") {
            Picker("Язык подсказок", selection: $settings.answerLanguage) {
                ForEach(AnswerLanguage.allCases) { Text($0.title).tag($0) }
            }
            editor("Резюме", text: $settings.resume, height: 110, importable: true)
            editor("Вакансия", text: $settings.jobDescription, height: 80, importable: true)
            editor("Указания (грейд, стиль, что подчеркнуть)", text: $settings.extraInstructions, height: 50, importable: false)
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat, importable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                if importable {
                    Button("Из файла…") { importText(into: text) }.controlSize(.small)
                }
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .frame(height: height)
        }
    }

    private func importText(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .rtf, .pdf]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "pdf" {
            binding.wrappedValue = PDFDocument(url: url)?.string ?? binding.wrappedValue
        } else if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            binding.wrappedValue = attr.string
        } else if let s = try? String(contentsOf: url, encoding: .utf8) {
            binding.wrappedValue = s
        }
    }

    // MARK: Window

    private var windowSection: some View {
        Section("4. Окно") {
            Toggle("Скрывать окно при демонстрации экрана", isOn: $settings.hideFromScreenShare)
            Toggle("Показывать иконку в Dock", isOn: $settings.showInDock)
            hint("Клик по иконке возвращает скрытое окно. Полезно, если значок в строке меню спрятан под «чёлкой» MacBook. Учтите: при показе всего экрана Dock виден собеседнику.")
            hint("Проверьте тестовым звонком: окна не должно быть видно у собеседника.")
            Slider(value: $settings.overlayOpacity, in: 0.4...1.0) { Text("Непрозрачность") }
            Slider(value: $settings.fontSize, in: 11...24, step: 1) { Text("Шрифт: \(Int(settings.fontSize))") }
        }
    }

    // MARK: Hotkeys

    private var hotkeySection: some View {
        Section {
            ForEach(HotKeyAction.allCases) { action in
                HotKeyRow(action: action)
            }
            HStack {
                hint("Нажмите на сочетание и введите новое. Esc — отмена. Нужен хотя бы один модификатор (⌃ ⌥ ⇧ ⌘), кроме F1–F12.")
                Spacer()
                Button("Сбросить") { hotkeys.resetDefaults() }.controlSize(.small)
            }
        } header: {
            Text("5. Горячие клавиши (работают в любом приложении)")
        }
    }

    // MARK: Updates

    private var updateSection: some View {
        Section("6. Обновления") {
            HStack {
                Text("Установлена версия \(Updater.currentVersion)")
                Spacer()
                Button("Проверить обновления") { Task { await state.checkForUpdates(silent: false) } }
                    .disabled(state.isUpdating)
            }
            if !state.updateStatus.isEmpty {
                hint(state.updateStatus)
            }
            HStack {
                if Updater.isRunningAppLocallySigned {
                    hint("🔐 Подпись постоянная: разрешения macOS сохраняются после обновлений.")
                } else {
                    hint("⚠️ Подпись временная: после обновлений macOS может снова спрашивать доступ." + (Updater.lastSigningError.map { " Ошибка: \($0)" } ?? ""))
                }
                Spacer()
                Button("Сбросить разрешение на звук") { Updater.resetScreenPermissionAndRelaunch() }
                    .controlSize(.small)
            }
            if let u = state.updateAvailable {
                HStack {
                    Button {
                        Task { await state.installUpdate() }
                    } label: {
                        Label(state.isUpdating ? "Обновляю…" : "Обновить до \(u.version)", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isUpdating)
                    if state.isUpdating { ProgressView().controlSize(.small) }
                }
                hint("RedCast скачает новую версию с GitHub, заменит себя и перезапустится. Настройки, резюме и модель речи сохранятся.")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct HotKeyRow: View {
    let action: HotKeyAction
    @EnvironmentObject var hotkeys: HotKeyStore
    @State private var recording = false
    @State private var monitor: Any?

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    var body: some View {
        HStack {
            Text(action.title)
            if hotkeys.failed.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .help("Это сочетание уже занято другой программой — выберите другое")
            }
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Нажмите сочетание…" : (hotkeys.combos[action]?.display ?? "не задано"))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 150)
            }
            .tint(recording ? .accentColor : nil)
            Button {
                hotkeys.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать сочетание")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        hotkeys.suspend()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return nil
            }
            let mods = HotKeyCombo.carbonModifiers(event.modifierFlags)
            if mods == 0 && !Self.functionKeys.contains(Int(event.keyCode)) {
                NSSound.beep()
                return nil
            }
            let combo = HotKeyCombo(keyCode: Int(event.keyCode), modifiers: mods, keyLabel: HotKeyCombo.label(for: event))
            hotkeys.set(combo, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording {
            recording = false
            hotkeys.registerAll()
        }
    }
}
