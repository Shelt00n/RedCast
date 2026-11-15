import AppKit
import Carbon
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case model, speech, answers, window, keys, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: return "ИИ"
        case .speech: return "Речь"
        case .answers: return "Ответы"
        case .window: return "Окно"
        case .keys: return "Клавиши"
        case .about: return "О программе"
        }
    }
    var symbol: String {
        switch self {
        case .model: return "sparkles"
        case .speech: return "waveform"
        case .answers: return "text.quote"
        case .window: return "macwindow"
        case .keys: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

/// Settings live inside the main window (gear in the header), one section at a time.
struct SettingsPane: View {
    @EnvironmentObject var ui: OverlayController

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                sectionBar(icons: true)
                sectionBar(icons: false)
                ScrollView(.horizontal, showsIndicators: false) { sectionBar(icons: false) }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch ui.settingsSection {
                    case .model: ModelSettings()
                    case .speech: SpeechSettings()
                    case .answers: AnswerSettings()
                    case .window: WindowSettings()
                    case .keys: HotKeySettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension SettingsPane {
    func sectionBar(icons: Bool) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "К подсказкам", size: 12, box: 28) { ui.tab = .hints }
            ForEach(SettingsSection.allCases) { s in
                Button { ui.settingsSection = s } label: {
                    HStack(spacing: 5) {
                        if icons { Image(systemName: s.symbol).font(.system(size: 11)) }
                        Text(s.title)
                    }
                }
                .buttonStyle(RCButtonStyle(kind: .ghost, selected: ui.settingsSection == s,
                                           height: 28, padding: 8, fontSize: 12, radius: 8))
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Building blocks

struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.fg3)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: 12)
            if let footer { Hint(text: footer).padding(.horizontal, 4) }
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let hint { Hint(text: hint) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct Hint: View {
    let text: String
    var warning = false
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? Theme.warning : Theme.fg3)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// Multi-line editor on a dark well.
struct TextArea: View {
    @Binding var text: String
    var height: CGFloat
    var placeholder = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder).font(.system(size: 12.5)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
        }
        .frame(height: height)
        .card(Theme.bgDeep, radius: 8, stroke: Theme.lineStrong)
    }
}

extension View {
    /// One-line field look (TextField / SecureField with `.plain` style).
    func fieldStyle(mono: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .card(Theme.bgDeep, radius: 8, stroke: Theme.lineStrong)
    }
}

// MARK: - Model

struct ModelSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ui: OverlayController

    private static let modelNotes: [String: String] = [
        "claude-opus-5-5": "Самый умный. Первые слова примерно через 2 с",
        "claude-sonnet-5-5": "Быстрый и умный: ~1 с. Лучший выбор для живого собеседования",
        "claude-haiku-5-5": "Самый быстрый и дешёвый, проще в рассуждениях",
    ]

    var body: some View {
        SettingsCard(title: "Подключение") {
            Picker("", selection: $settings.backend) {
                ForEach(Backend.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)

            if let p = settings.backend.provider {
                ProviderSettings(provider: p)
            } else if settings.backend == .api {
                SecureField("", text: $settings.apiKey, prompt: Text("Ключ sk-ant-…").foregroundColor(Theme.fg3))
                    .fieldStyle(mono: true)
                Hint(text: "platform.claude.com → API Keys. Оплата по факту, отдельно от подписки. Хранится в Связке ключей.")
                SettingRow(title: "Fast mode", hint: "Вывод до 2,5× быстрее, только Opus 5.5, цена ×2") {
                    Toggle("", isOn: $settings.fastMode).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: state.cliClient.isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(state.cliClient.isInstalled ? Theme.positive : Theme.warning)
                    Text(state.cliClient.isInstalled ? "Claude Code найден" : "Claude Code не найден")
                        .font(.system(size: 12.5))
                }
                if !state.cliClient.isInstalled {
                    Hint(text: "Установите в Терминале: curl -fsSL https://claude.ai/install.sh | bash, затем выполните claude → /login.")
                }
                TextField("", text: $settings.claudePath, prompt: Text("Путь к claude — пусто: найти автоматически").foregroundColor(Theme.fg3))
                    .fieldStyle(mono: true)
                Hint(text: "Расходует лимит вашей подписки Pro/Max. RedCast держит Claude Code заранее запущенным, чтобы ответ начинался сразу.")
            }
        }

        if settings.backend.provider == nil {
            SettingsCard(title: "Модель") {
                VStack(spacing: 2) {
                    ForEach(Catalog.claudeModels) { m in
                        let selected = settings.model == m.id
                        Button { settings.model = m.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(selected ? Theme.fg : Theme.fg3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title.components(separatedBy: " —").first ?? m.title)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(Self.modelNotes[m.id] ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.fg3)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.raised : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        SettingsCard(title: "Глубина размышлений",
                     footer: "«Быстро» — ответ начинается сразу. Глубже — точнее на сложных задачах, но дольше.") {
            Segmented(selection: settings.effort, items: Catalog.efforts.map { (value: $0.id, title: $0.title) }) {
                settings.effort = $0
            }
        }

        Button {
            ui.tab = .hints
            state.testConnection()
        } label: {
            IconLabel(symbol: "bolt.horizontal", title: "Проверить соединение")
        }
        .buttonStyle(RCButtonStyle(kind: .secondary, height: 32, padding: 12))
    }
}

/// Key, server address and model of an OpenAI-compatible provider (ChatGPT, Grok, Gemini, OpenRouter…).
struct ProviderSettings: View {
    let provider: Provider
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState
    @State private var models: [String] = []
    @State private var loading = false

    var body: some View {
        if provider.needsKey {
            SecureField("", text: $settings.providerKey, prompt: Text("Ключ \(provider.shortName)").foregroundColor(Theme.fg3))
                .fieldStyle(mono: true)
        }
        Hint(text: provider.keyHint + (provider.needsKey ? " Хранится в Связке ключей." : ""))
        if provider.local {
            TextField("", text: Binding(get: { settings.providerURL }, set: { settings.providerURL = $0 }),
                      prompt: Text("Адрес сервера").foregroundColor(Theme.fg3))
                .fieldStyle(mono: true)
        }
        HStack(spacing: 8) {
            TextField("", text: Binding(get: { settings.providerModel }, set: { settings.providerModel = $0 }),
                      prompt: Text("ID модели").foregroundColor(Theme.fg3))
                .fieldStyle(mono: true)
            if loading {
                ProgressView().controlSize(.small)
            } else if models.isEmpty {
                Button("Список моделей") { Task { await load() } }
                    .buttonStyle(RCButtonStyle(height: 30, padding: 10, fontSize: 12))
                    .help("Загрузить модели, доступные по этому ключу")
            } else {
                Menu("Выбрать") {
                    ForEach(models, id: \.self) { id in
                        Button(id) { settings.providerModel = id }
                    }
                }
                .fixedSize()
            }
        }
        Hint(text: "Для задач со скриншота нужна модель, которая понимает изображения. Для скорости берите «быстрые» версии (flash, mini, turbo).")
            .onChange(of: provider.id) { models = [] }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await OpenAICompatClient(provider: provider, key: settings.providerKey,
                                                    baseURL: settings.providerURL).listModels()
            if list.isEmpty {
                state.showError(provider.local
                    ? "Сервер не вернул ни одной модели. Скачайте или загрузите модель и попробуйте снова."
                    : "Провайдер не вернул ни одной модели для этого ключа.")
            }
            models = list
        } catch {
            state.showError("Список моделей: " + error.localizedDescription)
        }
    }
}

// MARK: - Speech

struct SpeechSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingsCard(title: "Распознавание") {
            SettingRow(title: "Язык собеседования") {
                Picker("", selection: $settings.speechLanguage) {
                    ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SettingRow(title: "Модель Whisper") {
                Picker("", selection: $settings.whisperModel) {
                    ForEach(Catalog.whisperModels) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .onChange(of: settings.whisperModel) { Task { await state.loadSpeechModel() } }
            }
            HStack(spacing: 8) {
                Image(systemName: state.modelReady ? "checkmark.circle.fill" : (state.modelFailed ? "exclamationmark.circle.fill" : "clock"))
                    .foregroundStyle(state.modelReady ? Theme.positive : (state.modelFailed ? Theme.warning : Theme.fg3))
                Text(state.modelStatus).font(.system(size: 12)).foregroundStyle(Theme.fg2)
                Spacer()
                Button("Перезагрузить") { Task { await state.loadSpeechModel() } }
                    .buttonStyle(RCButtonStyle(kind: .ghost, height: 26, padding: 8, fontSize: 12))
                Button("Скачать заново") { Task { await state.redownloadSpeechModel() } }
                    .buttonStyle(RCButtonStyle(kind: .ghost, height: 26, padding: 8, fontSize: 12))
                    .help("Если модель повреждена: удалить её и скачать чистую копию")
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Словарь терминов").font(.system(size: 13))
                TextArea(text: $settings.vocabulary, height: 58, placeholder: "Стек, компании, имена: Kubernetes, PostgreSQL, Kafka…")
                Hint(text: "Модель ИИ знает эти слова и понимает их, даже если распознавание записало их на слух («куборнетис»).")
            }
            SettingRow(title: "Точное написание терминов",
                       hint: "Термины латиницей прямо в расшифровке, но каждая фраза распознаётся на ~0,4 с дольше") {
                Toggle("", isOn: $settings.preciseTerms).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
            }
        }

        SettingsCard(title: "Режим") {
            Segmented(selection: settings.listenMode, items: ListenMode.allCases.map { (value: $0, title: $0.title) }) {
                state.setMode($0)
            }
            Hint(text: settings.listenMode == .auto
                 ? "RedCast сам слышит вопросы интервьюера и отвечает после паузы."
                 : "Две кнопки: «Интервьюер» и «Я». Первое нажатие начинает запись, второе даёт ответ. Пока идёт запись, речь уже распознаётся — ответ приходит почти сразу.")
            if settings.listenMode == .auto {
                SettingRow(title: "Отвечать на каждую реплику интервьюера") {
                    Toggle("", isOn: $settings.autoAnswer).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
                }
                SettingRow(title: "Слушать мой микрофон", hint: "Чтобы понимать, что вы уже ответили") {
                    Toggle("", isOn: $settings.captureMic).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Пауза конца вопроса").font(.system(size: 13))
                        Spacer()
                        Text("\(Int(settings.silenceMs)) мс").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.fg2)
                    }
                    Slider(value: $settings.silenceMs, in: 400...1500, step: 50)
                    Hint(text: "Меньше — подсказка раньше, но вопрос чаще делится на части.")
                }
            }
        }

        SettingsCard(title: "Микрофон") {
            HStack(spacing: 6) {
                Picker("", selection: $settings.micDeviceUID) {
                    Text("Системный" + (AudioDevices.defaultInputName().map { " (\($0))" } ?? "")).tag("")
                    ForEach(state.micDevices) { Text($0.name).tag($0.id) }
                    if !settings.micDeviceUID.isEmpty && !state.micDevices.contains(where: { $0.id == settings.micDeviceUID }) {
                        Text("Отключён: выбранный ранее микрофон").tag(settings.micDeviceUID)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                IconButton(symbol: "arrow.clockwise", help: "Обновить список (подключили наушники или USB-микрофон)", size: 12, box: 28) {
                    state.refreshMicDevices()
                }
            }
            HStack(spacing: 10) {
                Button(state.micTesting ? "Остановить" : "Проверить") { Task { await state.toggleMicTest() } }
                    .buttonStyle(RCButtonStyle(kind: state.micTesting ? .live : .secondary, height: 28, padding: 10, fontSize: 12))
                MicLevelBar(active: state.micTesting)
            }
            Hint(text: state.micTesting
                 ? "Скажите что-нибудь: полоска должна двигаться. Стоит на месте — выберите другой микрофон."
                 : "Нажмите «Проверить», чтобы убедиться, что RedCast вас слышит.")
            SettingsDivider()
            SettingRow(title: "Эхоподавление", hint: "Если вы без наушников: убирает голос интервьюера из динамиков") {
                Toggle("", isOn: $settings.echoCancellation).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
            }
        }
        .onAppear { state.refreshMicDevices() }
        .onChange(of: settings.micDeviceUID) { state.micDeviceChanged() }
    }
}

struct MicLevelBar: View {
    var active: Bool
    @ObservedObject private var levels = AudioLevels.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bgDeep)
                Capsule()
                    .fill(levels.mic > 0.85 ? Theme.warning : Theme.positive)
                    .frame(width: geo.size.width * CGFloat(active ? levels.mic : 0))
                    .animation(.linear(duration: 0.1), value: levels.mic)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Answers & profile

struct AnswerSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsCard(title: "Формат ответа") {
            HStack(spacing: 4) {
                ForEach(AnswerFormatPreset.all) { p in
                    let selected = settings.answerFormat == p.text
                    Button(Self.shortTitle(p)) { settings.answerFormat = p.text }
                        .buttonStyle(RCButtonStyle(kind: .ghost, selected: selected, height: 24, padding: 7, fontSize: 11.5, radius: 7))
                        .fixedSize()
                        .help(p.text.isEmpty ? "Главный тезис, 2–5 пунктов, код при необходимости" : p.text)
                }
            }
            TextArea(text: $settings.answerFormat, height: 84, placeholder: "Пусто — стандартный формат: главный тезис, 2–5 пунктов, код при необходимости")
            Hint(text: "Опишите своими словами, как отвечать: длина, стиль, списки или сплошной текст, нужен ли код. Применяется ко всем ответам, включая задачи и скриншоты.")
            SettingsDivider()
            SettingRow(title: "Язык подсказок") {
                Picker("", selection: $settings.answerLanguage) {
                    ForEach(AnswerLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }

        SettingsCard(title: "Профиль", footer: "Ответы опираются на ваш реальный опыт. Резюме и вакансия кэшируются у модели и не замедляют ответы.") {
            editor("Резюме", text: $settings.resume, height: 110, importable: true)
            editor("Вакансия", text: $settings.jobDescription, height: 80, importable: true)
            editor("Дополнительно о себе", text: $settings.extraInstructions, height: 50, importable: false,
                   placeholder: "Грейд, что подчеркнуть, о чём не говорить…")
        }
    }

    private static func shortTitle(_ p: AnswerFormatPreset) -> String {
        switch p.id {
        case "speak": return "Вслух"
        case "standard": return "Стандарт"
        default: return p.title.components(separatedBy: " (").first ?? p.title
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat, importable: Bool, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if importable {
                    Button("Из файла…") { importText(into: text) }
                        .buttonStyle(RCButtonStyle(kind: .ghost, height: 24, padding: 8, fontSize: 11.5))
                }
            }
            TextArea(text: text, height: height, placeholder: placeholder)
        }
    }

    private func importText(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .rtf, .pdf]
        panel.allowsMultipleSelection = false
        let response = OverlayController.shared.runModal { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "pdf" {
            binding.wrappedValue = PDFDocument(url: url)?.string ?? binding.wrappedValue
        } else if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            binding.wrappedValue = attr.string
        } else if let s = try? String(contentsOf: url, encoding: .utf8) {
            binding.wrappedValue = s
        }
    }
}

// MARK: - Window

struct WindowSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: OverlayController

    var body: some View {
        SettingsCard(title: "Видимость", footer: "Проверьте тестовым звонком: окна не должно быть видно у собеседника.") {
            SettingRow(title: "Скрывать при демонстрации экрана") {
                Toggle("", isOn: $settings.hideFromScreenShare).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
            }
            SettingRow(title: "Иконка в Dock",
                       hint: "Клик по ней возвращает скрытое окно. При показе всего экрана Dock виден собеседнику.") {
                Toggle("", isOn: $settings.showInDock).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.positive)
            }
        }

        SettingsCard(title: "Вид") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Непрозрачность").font(.system(size: 13))
                    Spacer()
                    Text("\(Int(settings.overlayOpacity * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.fg2)
                }
                Slider(value: $settings.overlayOpacity, in: 0.4...1.0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Размер текста ответов").font(.system(size: 13))
                    Spacer()
                    Text("\(Int(settings.fontSize))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.fg2)
                }
                Slider(value: $settings.fontSize, in: 11...24, step: 1)
                Text("**Главная мысль ответа** и пояснение обычным текстом.")
                    .font(.system(size: settings.fontSize))
                    .padding(.top, 2)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Размер окна").font(.system(size: 13))
                HStack(spacing: 6) {
                    ForEach(OverlayController.SizePreset.allCases) { p in
                        Button(p.title) { ui.setSize(p) }
                            .buttonStyle(RCButtonStyle(height: 26, padding: 8, fontSize: 11.5, radius: 7))
                    }
                }
                Hint(text: "Окно тянется за левый, правый и нижний край. Перемещается за шапку и пустое место внизу.")
            }
        }
    }
}

// MARK: - Hotkeys

struct HotKeySettings: View {
    @EnvironmentObject var hotkeys: HotKeyStore

    var body: some View {
        SettingsCard(title: "Горячие клавиши",
                     footer: "Работают в любом приложении. Нажмите на сочетание и введите новое, Esc — отмена. Нужен хотя бы один модификатор (⌃ ⌥ ⇧ ⌘), кроме F1–F12.") {
            VStack(spacing: 0) {
                ForEach(Array(HotKeyAction.allCases.enumerated()), id: \.element) { i, action in
                    if i > 0 { SettingsDivider().padding(.vertical, 6) }
                    HotKeyRow(action: action)
                }
            }
        }
        Button("Вернуть стандартные") { hotkeys.resetDefaults() }
            .buttonStyle(RCButtonStyle(height: 28, padding: 10, fontSize: 12))
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(.system(size: 12.5))
                if hotkeys.failed.contains(action) {
                    Text("Занято другой программой — выберите другое")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                KeyCap(text: recording ? "Нажмите сочетание…" : (hotkeys.combos[action]?.display ?? "не задано"),
                       active: recording, minWidth: 96, size: 11.5)
            }
            .buttonStyle(.plain)
            IconButton(symbol: "xmark", help: "Убрать сочетание", size: 9, box: 22) {
                hotkeys.set(nil, for: action)
            }
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

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingsCard(title: "Обновления") {
            SettingRow(title: "RedCast \(Updater.currentVersion)", hint: state.updateStatus.isEmpty ? nil : state.updateStatus) {
                Button("Проверить") { Task { await state.checkForUpdates(silent: false) } }
                    .buttonStyle(RCButtonStyle(height: 28, padding: 10, fontSize: 12))
                    .disabled(state.isUpdating)
            }
            if let u = state.updateAvailable {
                HStack(spacing: 8) {
                    Button(state.isUpdating ? "Обновляю…" : "Обновить до \(u.version)") { Task { await state.installUpdate() } }
                        .buttonStyle(RCButtonStyle(kind: .primary, height: 32, padding: 14))
                        .disabled(state.isUpdating)
                    if state.isUpdating { ProgressView().controlSize(.small) }
                }
                Hint(text: "RedCast скачает новую версию с GitHub, заменит себя и перезапустится. Настройки, резюме и модель речи сохранятся.")
            }
        }

        SettingsCard(title: "Разрешения macOS") {
            if Updater.isRunningAppLocallySigned {
                Hint(text: "Подпись постоянная: разрешения сохраняются после обновлений.")
            } else {
                Hint(text: "Подпись временная: после обновлений macOS может снова спрашивать доступ." + (Updater.lastSigningError.map { " Ошибка: \($0)" } ?? ""),
                     warning: true)
            }
            HStack(spacing: 6) {
                Button("Сбросить разрешение на звук") { Updater.resetScreenPermissionAndRelaunch() }
                    .buttonStyle(RCButtonStyle(height: 28, padding: 10, fontSize: 12))
                Button("Настройки конфиденциальности") { state.openPrivacySettings("Privacy_ScreenCapture") }
                    .buttonStyle(RCButtonStyle(kind: .ghost, height: 28, padding: 10, fontSize: 12))
            }
        }

        SettingsCard {
            HStack {
                Button {
                    try? FileManager.default.createDirectory(at: AppState.sessionsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppState.sessionsFolder)
                } label: { IconLabel(symbol: "folder", title: "Записи собеседований") }
                    .buttonStyle(RCButtonStyle(height: 28, padding: 10, fontSize: 12))
                Spacer()
                Button("Выйти из RedCast") { NSApp.terminate(nil) }
                    .buttonStyle(RCButtonStyle(kind: .ghost, height: 28, padding: 10, fontSize: 12))
            }
        }
    }
}
