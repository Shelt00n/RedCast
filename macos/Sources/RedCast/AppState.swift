import AppKit
import Foundation
import ScreenCaptureKit

enum Speaker: String {
    case interviewer, me
    var label: String { self == .interviewer ? "Интервьюер" : "Я" }
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let date: Date
}

struct AnswerItem: Identifiable {
    let id = UUID()
    var question: String
    var text = ""
    var isStreaming = true
    var error: String?
    let startedAt = Date()
    var firstTokenSeconds: Double?
    var expanded = true
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings.shared

    @Published var entries: [TranscriptEntry] = []
    @Published var partial: [Speaker: String] = [:]
    @Published var speaking: Set<Speaker> = []
    @Published var answers: [AnswerItem] = []
    @Published var isListening = false
    @Published var status = "Готов"
    @Published var modelStatus = "Модель речи не загружена"
    @Published var modelReady = false
    @Published var modelProgress: Double?
    @Published var isStarting = false
    /// Visible error banner in the window (nil = no error).
    @Published var errorMessage: String?
    @Published var errorIsPermission = false

    // Microphone
    @Published var micLevel: Float = 0
    @Published var micTesting = false
    @Published var micDevices: [AudioInputDevice] = []

    // Updates
    @Published var updateAvailable: ReleaseInfo?
    @Published var updateStatus = ""
    @Published var isUpdating = false

    private let transcriber = Transcriber()
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let systemSegmenter = SpeechSegmenter()
    private let micSegmenter = SpeechSegmenter()
    private let systemQueue = DispatchQueue(label: "redcast.seg.system", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "redcast.seg.mic", qos: .userInitiated)

    private let apiClient = AnthropicAPIClient(apiKey: { AppSettings.shared.apiKey })
    private let cliClient = ClaudeCodeClient(customPath: { AppSettings.shared.claudePath })

    private var answerTask: Task<Void, Never>?
    private var currentAnswerID: UUID?
    private var currentQuestion: String?
    private var questionStartedAt = Date.distantPast
    private var lastInterviewerFinalAt = Date.distantPast
    private var lastMeSpeechAt = Date.distantPast
    private var forceAnswerOnNextFinal = false
    private let systemRecorder = ManualRecorder()
    private let micRecorder = ManualRecorder()
    /// «По кнопкам»: which channels are being recorded right now.
    @Published var recording: Set<Speaker> = []
    private var keepAlive: Timer?
    private var sessionStart = Date()

    private init() {
        wireAudio()
    }

    // MARK: - Setup

    private func wireAudio() {
        // These callbacks fire on audio / segmenter queues: they are @Sendable and hop to the main actor.
        let sysSeg = systemSegmenter, micSeg = micSegmenter
        let sysRec = systemRecorder, micRec = micRecorder
        let sysQ = systemQueue, micQ = micQueue

        systemCapture.onSamples = { samples in sysQ.async { sysSeg.append(samples); sysRec.append(samples) } }
        systemCapture.onError = { error in
            Task { @MainActor in AppState.shared.captureFailed(error) }
        }
        micCapture.onSamples = { samples in micQ.async { micSeg.append(samples); micRec.append(samples) } }
        micCapture.onLevel = { level in Task { @MainActor in AppState.shared.micLevel = level } }

        sysSeg.onSpeechStart = { Task { @MainActor in AppState.shared.speechStarted(.interviewer) } }
        sysSeg.onPartial = { audio in Task { @MainActor in await AppState.shared.handlePartial(.interviewer, audio) } }
        sysSeg.onFinal = { audio in Task { @MainActor in await AppState.shared.handleFinal(.interviewer, audio) } }

        micSeg.onSpeechStart = { Task { @MainActor in AppState.shared.speechStarted(.me) } }
        micSeg.onFinal = { audio in Task { @MainActor in await AppState.shared.handleFinal(.me, audio) } }

        sysRec.onPartial = { audio in Task { @MainActor in await AppState.shared.handleManualPartial(.interviewer, audio) } }
        micRec.onPartial = { audio in Task { @MainActor in await AppState.shared.handleManualPartial(.me, audio) } }
    }

    private func queue(_ speaker: Speaker) -> DispatchQueue { speaker == .interviewer ? systemQueue : micQueue }
    private func recorder(_ speaker: Speaker) -> ManualRecorder { speaker == .interviewer ? systemRecorder : micRecorder }

    private func setAutoSegmentation(_ on: Bool) {
        let silence = settings.silenceMs
        let sysSeg = systemSegmenter, micSeg = micSegmenter
        systemQueue.sync { sysSeg.reset(); sysSeg.silenceMs = silence; sysSeg.active = on }
        micQueue.sync { micSeg.reset(); micSeg.silenceMs = silence + 200; micSeg.active = on }
    }

    /// Starts the requested audio sources (keeps already running ones).
    private func ensureCaptures(system: Bool, mic: Bool, micRequired: Bool) async -> Bool {
        if system && !systemCapture.isRunning {
            do {
                try await systemCapture.start()
            } catch {
                showError("Нет доступа к звуку системы (macOS: «\(error.localizedDescription)»).",
                          permission: true)
                return false
            }
        }
        if mic && !micCapture.isRunning {
            if await MicCapture.requestAccess() {
                micCapture.echoCancellation = settings.echoCancellation
                micCapture.deviceUID = settings.micDeviceUID
                do {
                    try micCapture.start()
                } catch {
                    showError("Микрофон: \(error.localizedDescription)")
                    if micRequired { return false }
                }
            } else {
                showError(CaptureError.micDenied.localizedDescription)
                if micRequired { return false }
            }
        }
        return true
    }

    private func sessionStarted() {
        guard !isListening else { return }
        isListening = true
        sessionStart = Date()
        if settings.backend == .api && settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            showError("Подсказок не будет: не задан API-ключ. Откройте вкладку «Настройки» → Claude.")
        }
        prewarmLLM()
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { _ in
            Task { @MainActor in AppState.shared.prewarmLLM() }
        }
    }

    func loadSpeechModel() async {
        let model = settings.whisperModel
        modelReady = false
        modelProgress = Transcriber.localFolder(for: model) == nil ? 0 : nil
        modelStatus = modelProgress == nil
            ? "Загрузка модели речи в память…"
            : "Скачивание модели речи (один раз, ~1–2 ГБ)…"
        do {
            try await transcriber.load(model: model) { fraction in
                Task { @MainActor in
                    let st = AppState.shared
                    if fraction >= 1 {
                        st.modelProgress = nil
                        st.modelStatus = "Загрузка модели речи в память (до 1 минуты)…"
                    } else {
                        st.modelProgress = fraction
                        st.modelStatus = "Скачивание модели речи: \(Int(fraction * 100))%"
                    }
                }
            }
            modelReady = true
            modelProgress = nil
            modelStatus = "Распознавание готово"
        } catch {
            modelProgress = nil
            modelStatus = "Ошибка модели речи"
            showError("Не удалось загрузить модель речи: \(error.localizedDescription). Проверьте интернет и нажмите «Скачать модель заново» во вкладке «Настройки».")
        }
    }

    // MARK: - Microphone choice

    func refreshMicDevices() {
        micDevices = AudioDevices.inputs()
    }

    /// Microphone changed in Settings: switch right away if it is in use.
    func micDeviceChanged() {
        guard micCapture.isRunning else { return }
        micCapture.stop()
        Task {
            _ = await ensureCaptures(system: false, mic: true, micRequired: false)
        }
    }

    /// «Проверить»: listen to the microphone and show its level (without transcribing it).
    func toggleMicTest() async {
        if micTesting {
            micTesting = false
            if !isListening { micCapture.stop() }
            return
        }
        errorMessage = nil
        if await ensureCaptures(system: false, mic: true, micRequired: true) {
            micTesting = true
        }
    }

    /// Deletes the speech model files and downloads a clean copy.
    func redownloadSpeechModel() async {
        if isListening { stop() }
        await transcriber.reset()
        Transcriber.deleteModel(settings.whisperModel)
        errorMessage = nil
        await loadSpeechModel()
    }

    // MARK: - Updates

    func checkForUpdates(silent: Bool) async {
        if !silent { updateStatus = "Проверяю…" }
        do {
            let r = try await Updater.latest()
            if Updater.isNewer(r.version, than: Updater.currentVersion) {
                updateAvailable = r
                updateStatus = "Доступна версия \(r.version)"
            } else {
                updateAvailable = nil
                updateStatus = "У вас последняя версия (\(Updater.currentVersion))"
            }
        } catch {
            if !silent { updateStatus = "Не удалось проверить: \(error.localizedDescription)" }
        }
    }

    func installUpdate() async {
        guard let r = updateAvailable, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        if isListening { stop() }
        updateStatus = "Скачиваю версию \(r.version)…"
        do {
            let app = try await Updater.download(r)
            updateStatus = "Устанавливаю… RedCast перезапустится"
            try Updater.installAndRelaunch(app)
        } catch {
            updateStatus = "Ошибка обновления: \(error.localizedDescription)"
            showError("Не удалось обновиться: \(error.localizedDescription)")
        }
    }

    func showError(_ text: String, permission: Bool = false) {
        errorMessage = text
        errorIsPermission = permission
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Listening (mode «Авто»)

    func setMode(_ mode: ListenMode) {
        guard settings.listenMode != mode else { return }
        stop()
        settings.listenMode = mode
        status = mode == .auto ? "Готов — нажмите «Старт»" : "Готов — нажмите «Интервьюер» или «Я»"
    }

    func toggleListening() {
        Task {
            if settings.listenMode == .manual {
                if isListening { stop() } else { status = "Режим «По кнопкам»: нажмите «Интервьюер» или «Я»" }
                return
            }
            if isListening { stop() } else { await start() }
        }
    }

    func start() async {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil
        if !modelReady {
            status = "Жду модель речи — прослушивание начнётся автоматически"
            await loadSpeechModel()
        }
        guard modelReady else {
            status = "Готов"
            return
        }
        status = "Запускаю…"
        setAutoSegmentation(true)
        guard await ensureCaptures(system: true, mic: settings.captureMic, micRequired: false) else {
            status = "Готов"
            return
        }
        sessionStarted()
        status = "Слушаю…"
    }

    func stop() {
        let wasListening = isListening
        systemCapture.stop()
        micCapture.stop()
        let sysRec = systemRecorder, micRec = micRecorder
        systemQueue.sync { sysRec.cancel() }
        micQueue.sync { micRec.cancel() }
        setAutoSegmentation(false)
        keepAlive?.invalidate()
        keepAlive = nil
        isListening = false
        micTesting = false
        recording.removeAll()
        speaking.removeAll()
        partial.removeAll()
        if wasListening {
            status = "Пауза"
            saveSession()
        }
    }

    private func captureFailed(_ error: Error) {
        stop()
        showError("Захват звука остановлен: \(error.localizedDescription)")
    }

    // MARK: - Mode «По кнопкам»

    /// First press — start recording this channel, second press — recognise and answer.
    func toggleRecord(_ speaker: Speaker) {
        Task {
            if recording.contains(speaker) {
                await finishRecording(speaker)
            } else {
                await beginRecording(speaker)
            }
        }
    }

    private func beginRecording(_ speaker: Speaker) async {
        if settings.listenMode != .manual {
            stop()
            settings.listenMode = .manual
        }
        errorMessage = nil
        setAutoSegmentation(false)
        let ok = await ensureCaptures(system: speaker == .interviewer, mic: speaker == .me, micRequired: true)
        guard ok else { return }
        sessionStarted()
        let rec = recorder(speaker)
        queue(speaker).sync { rec.start() }
        recording.insert(speaker)
        status = speaker == .interviewer
            ? "● Записываю интервьюера — нажмите ещё раз, чтобы получить ответ"
            : "● Записываю вас — нажмите ещё раз, чтобы получить ответ"
        if !modelReady { Task { await loadSpeechModel() } }
    }

    private func finishRecording(_ speaker: Speaker) async {
        let rec = recorder(speaker)
        let audio = queue(speaker).sync { rec.stop() }
        recording.remove(speaker)
        partial[speaker] = nil
        status = "Распознаю…"
        if !modelReady { await loadSpeechModel() }
        let text = await transcriber.transcribe(
            audio, language: settings.speechLanguage.whisperCode, vocabulary: settings.vocabulary, urgent: true)
        status = recording.isEmpty ? "Готов — нажмите «Интервьюер» или «Я»" : status
        guard !text.isEmpty else {
            showError("Речь не распознана. Проверьте, что звук идёт, и попробуйте ещё раз.")
            return
        }
        entries.append(TranscriptEntry(speaker: speaker, text: text, date: Date()))
        currentQuestion = text
        questionStartedAt = Date()
        let ctx = context(before: Date().addingTimeInterval(-0.5))
        if speaker == .interviewer {
            ask(question: "🎧 " + text, prompt: Prompts.question(context: ctx, question: text), replaceCurrent: false)
        } else {
            ask(question: "🎤 " + text, prompt: Prompts.mine(context: ctx, text: text), replaceCurrent: false)
        }
    }

    private func handleManualPartial(_ speaker: Speaker, _ audio: [Float]) async {
        guard recording.contains(speaker) else { return }
        let text = await transcriber.transcribePartialIfIdle(
            audio, language: settings.speechLanguage.whisperCode, vocabulary: settings.vocabulary)
        if let text, !text.isEmpty, recording.contains(speaker) {
            partial[speaker] = text
        }
    }

    // MARK: - Speech events (mode «Авто»)

    private func speechStarted(_ speaker: Speaker) {
        speaking.insert(speaker)
    }

    private func handlePartial(_ speaker: Speaker, _ audio: [Float]) async {
        guard speaking.contains(speaker) else { return }
        let text = await transcriber.transcribePartialIfIdle(
            audio, language: settings.speechLanguage.whisperCode, vocabulary: settings.vocabulary)
        if let text, !text.isEmpty, speaking.contains(speaker) {
            partial[speaker] = text
        }
    }

    private func handleFinal(_ speaker: Speaker, _ audio: [Float]) async {
        speaking.remove(speaker)
        let text = await transcriber.transcribe(
            audio, language: settings.speechLanguage.whisperCode, vocabulary: settings.vocabulary,
            urgent: speaker == .interviewer)
        partial[speaker] = nil
        guard !text.isEmpty, isListening, settings.listenMode == .auto else { return }
        if speaker == .me {
            // The microphone heard the interviewer from the speakers → not my words.
            if isEcho(text) { return }
            lastMeSpeechAt = Date()
        }
        entries.append(TranscriptEntry(speaker: speaker, text: text, date: Date()))
        if speaker == .interviewer { interviewerSaid(text) }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 2 })
    }

    /// True if my "utterance" is mostly the interviewer's words (echo without headphones).
    private func isEcho(_ text: String) -> Bool {
        let mine = Self.words(text)
        let recent = entries
            .filter { $0.speaker == .interviewer && Date().timeIntervalSince($0.date) < 20 }
            .map(\.text)
            .joined(separator: " ") + " " + (partial[.interviewer] ?? "")
        let theirs = Self.words(recent)
        guard !mine.isEmpty, !theirs.isEmpty else { return false }
        let overlap = Double(mine.intersection(theirs).count) / Double(mine.count)
        return overlap >= 0.6
    }

    private func interviewerSaid(_ text: String) {
        let now = Date()
        // Same question only if the interviewer paused briefly (< 4 s) mid-sentence and I haven't spoken since.
        let continuing = currentQuestion != nil
            && lastMeSpeechAt < questionStartedAt
            && now.timeIntervalSince(lastInterviewerFinalAt) < 4
            && now.timeIntervalSince(questionStartedAt) < 30
        lastInterviewerFinalAt = now
        if continuing, let q = currentQuestion {
            currentQuestion = q + " " + text
        } else {
            currentQuestion = text
            questionStartedAt = now
        }
        let force = forceAnswerOnNextFinal
        forceAnswerOnNextFinal = false
        if settings.autoAnswer || force, let q = currentQuestion {
            ask(question: q, prompt: Prompts.question(context: context(before: questionStartedAt), question: q),
                replaceCurrent: continuing)
        }
    }

    // MARK: - Actions

    /// Hotkey «ответить сейчас»: closes the current utterance immediately, or re-answers the last question.
    func answerNow() {
        if settings.listenMode == .manual {
            toggleRecord(.interviewer)
            return
        }
        if speaking.contains(.interviewer) {
            forceAnswerOnNextFinal = true
            let seg = systemSegmenter
            systemQueue.async { seg.flush() }
        } else if let q = currentQuestion ?? entries.last(where: { $0.speaker == .interviewer })?.text {
            ask(question: q, prompt: Prompts.question(context: context(before: questionStartedAt), question: q),
                replaceCurrent: false)
        } else {
            showError("Пока нечего отвечать: вопрос интервьюера ещё не распознан. Можно ввести вопрос текстом внизу окна.")
        }
    }

    func askManual(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        currentQuestion = q
        questionStartedAt = Date()
        ask(question: q, prompt: Prompts.question(context: context(before: Date()), question: q), replaceCurrent: false)
    }

    func solveScreenshot() {
        Task {
            do {
                status = "Скриншот…"
                let jpeg = try await ScreenGrabber.captureJPEG()
                status = isListening ? "Слушаю…" : "Готов"
                ask(question: "📷 Задача с экрана", prompt: Prompts.screenshot(context: context(before: Date()),
                                                     customFormat: !settings.answerFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    image: jpeg, replaceCurrent: false)
            } catch {
                status = isListening ? "Слушаю…" : "Готов"
                showError("Скриншот не удался — нужно разрешение «Запись экрана и системного звука». \(error.localizedDescription)",
                          permission: true)
            }
        }
    }

    func stopAnswer() {
        answerTask?.cancel()
        markStopped()
    }

    func clear() {
        stopAnswer()
        entries.removeAll()
        answers.removeAll()
        partial.removeAll()
        currentQuestion = nil
        currentAnswerID = nil
    }

    // MARK: - Claude

    private func context(before date: Date) -> String {
        let recent = entries.filter { $0.date < date }.suffix(24)
        var lines = recent.map { "[\($0.speaker.label)] \($0.text)" }
        // Keep the context compact → faster time-to-first-token.
        while lines.joined(separator: "\n").count > 6000, !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private func makeRequest(text: String, image: Data? = nil) -> LLMRequest {
        LLMRequest(system: Prompts.system(settings), text: text, imageJPEG: image,
                   model: settings.model, effort: settings.effort, fastMode: settings.fastMode)
    }

    func prewarmLLM() {
        let req = makeRequest(text: "ping")
        switch settings.backend {
        case .api:
            guard !settings.apiKey.isEmpty else { return }
            let client = apiClient
            Task.detached(priority: .utility) { await client.prewarm(req) }
        case .claudeCode:
            let client = cliClient
            Task.detached(priority: .utility) { client.prewarm(req) }
        }
    }

    func toggleExpanded(_ id: UUID) {
        guard let i = answers.firstIndex(where: { $0.id == id }) else { return }
        answers[i].expanded.toggle()
    }

    private func markStopped() {
        for i in answers.indices where answers[i].isStreaming {
            answers[i].isStreaming = false
        }
    }

    private func ask(question: String, prompt: String, image: Data? = nil, replaceCurrent: Bool) {
        answerTask?.cancel()
        markStopped()

        let item = AnswerItem(question: question)
        // Older answers fold into one line so the new one gets the whole window.
        for i in answers.indices { answers[i].expanded = false }
        if replaceCurrent, let id = currentAnswerID, let idx = answers.firstIndex(where: { $0.id == id }) {
            answers[idx] = item
        } else {
            answers.append(item)
            if answers.count > 30 { answers.removeFirst(answers.count - 30) }
        }
        currentAnswerID = item.id

        let request = makeRequest(text: prompt, image: image)
        let client: LLMClient
        if settings.backend == .api { client = apiClient } else { client = cliClient }
        let id = item.id
        answerTask = Task { [weak self] in
            do {
                try await client.stream(request) { chunk in
                    self?.append(chunk, to: id)
                }
                self?.finish(id, error: nil)
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch {
                if Task.isCancelled { return }
                self?.finish(id, error: error.localizedDescription)
            }
        }
    }

    private func append(_ chunk: String, to id: UUID) {
        guard let idx = answers.firstIndex(where: { $0.id == id }) else { return }
        if answers[idx].firstTokenSeconds == nil {
            answers[idx].firstTokenSeconds = Date().timeIntervalSince(answers[idx].startedAt)
        }
        answers[idx].text += chunk
    }

    private func finish(_ id: UUID, error: String?) {
        guard let idx = answers.firstIndex(where: { $0.id == id }) else { return }
        answers[idx].isStreaming = false
        answers[idx].error = error
    }

    // MARK: - History

    private func saveSession() {
        guard !entries.isEmpty || !answers.isEmpty else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RedCast/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        var md = "# Собеседование \(f.string(from: sessionStart))\n\n## Расшифровка\n\n"
        for e in entries { md += "- `\(t.string(from: e.date))` **\(e.speaker.label):** \(e.text)\n" }
        md += "\n## Подсказки\n\n"
        for a in answers { md += "### \(a.question)\n\n\(a.text)\n\n" }
        try? md.write(to: dir.appendingPathComponent("\(f.string(from: sessionStart)).md"), atomically: true, encoding: .utf8)
    }

    static var sessionsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RedCast/Sessions", isDirectory: true)
    }
}

// MARK: - Screenshot

enum ScreenGrabber {
    enum GrabError: Error { case noDisplay, encode }

    /// Captures the display under the mouse pointer, without RedCast's own windows.
    static func captureJPEG() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw GrabError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let longEdge = Double(max(display.width, display.height))
        let scale = min(2.0, 1568.0 / longEdge)   // Claude's sweet spot for image size
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw GrabError.encode
        }
        return data
    }
}
