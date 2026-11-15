import AppKit
import Combine
import WhisperKit
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
    /// From the end of the phrase to ready text, waiting in the queue included (shown in the transcript).
    var recognitionSeconds: Double? = nil
}

struct AnswerItem: Identifiable {
    let id = UUID()
    var question: String
    var text = ""
    var isStreaming = true
    var error: String?
    let startedAt = Date()
    /// How long speech recognition took after the question ended (nil for typed questions / screenshots).
    var recognitionSeconds: Double?
    var firstTokenSeconds: Double?
    var expanded = true
}

/// Input levels for the meters, 0…1 about 10 times a second. Separate from AppState so the
/// meters redraw on their own and the answer list is not re-rendered 10 times a second.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()
    @Published var system: Float = 0
    @Published var mic: Float = 0
}

/// Peak level of a stream, reported every ~100 ms. Use from one serial queue.
final class LevelMeter: @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    private var peak: Float = 0
    private var count = 0

    func feed(_ samples: [Float]) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        peak = max(peak, (sum / Float(max(1, samples.count))).squareRoot())
        count += samples.count
        if count >= 1_600 {
            onLevel?(min(1, peak * 8))
            peak = 0
            count = 0
        }
    }
}

/// One phrase being recognised piece by piece, while the person is still talking.
@MainActor
final class Utterance {
    let id: Int
    let speaker: Speaker
    var pieces: [Task<Recognized, Never>] = []
    /// Recognised pieces, in order (for the live caption).
    var done: [String] = []
    /// Pieces whose recognition has finished (empty ones included).
    var finished = 0
    /// Caption of the piece being spoken right now.
    var partial = ""

    init(id: Int, speaker: Speaker) {
        self.id = id
        self.speaker = speaker
    }

    var caption: String {
        (done + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }
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
    /// Short transient note in the header (nil = derive the label from the state).
    @Published var note: String?
    @Published var modelStatus = "Модель речи не загружена"
    @Published var modelReady = false
    @Published var modelFailed = false
    @Published var modelProgress: Double?
    @Published var isStarting = false
    /// Visible error banner in the window (nil = no error).
    @Published var errorMessage: String?
    @Published var errorIsPermission = false
    /// Phrases whose final text is being recognised right now.
    @Published var recognizing: Set<Speaker> = []

    // Microphone
    @Published var micTesting = false
    @Published var micDevices: [AudioInputDevice] = []

    // Updates
    @Published var updateAvailable: ReleaseInfo?
    @Published var updateStatus = ""
    @Published var isUpdating = false

    /// «По кнопкам»: which channels are being recorded right now, and since when.
    @Published var recording: Set<Speaker> = []
    @Published var recordingSince: [Speaker: Date] = [:]

    private let transcriber = Transcriber()
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let systemSegmenter = SpeechSegmenter()
    private let micSegmenter = SpeechSegmenter()
    private let systemRecorder = ManualRecorder()
    private let micRecorder = ManualRecorder()
    private let systemMeter = LevelMeter()
    private let systemQueue = DispatchQueue(label: "redcast.seg.system", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "redcast.seg.mic", qos: .userInitiated)

    private let apiClient = AnthropicAPIClient(apiKey: { AppSettings.shared.apiKey })
    let cliClient = ClaudeCodeClient(customPath: { AppSettings.shared.claudePath })

    private var answerTask: Task<Void, Never>?
    /// The answer being read right now (the view marks it with the red on-air rule).
    private(set) var currentAnswerID: UUID?
    private var currentQuestion: String?
    private var questionStartedAt = Date.distantPast
    private var lastInterviewerFinalAt = Date.distantPast
    private var lastMeSpeechAt = Date.distantPast
    private var forceAnswerOnNextFinal = false
    private var keepAlive: Timer?
    private var sessionStart = Date()
    private var utterances: [Speaker: Utterance] = [:]
    private var manualID = 1_000_000
    private var settingsWatch: AnyCancellable?
    private var lastWarmKey = ""

    private init() {
        wireAudio()
        // A changed resume / model / connection: prepare the model connection again in the background.
        settingsWatch = settings.objectWillChange
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { _ in Task { @MainActor in AppState.shared.prewarmIfChanged() } }
    }

    // MARK: - Setup

    private func wireAudio() {
        // These callbacks fire on audio / segmenter queues: they are @Sendable and hop to the main actor.
        let sysSeg = systemSegmenter, micSeg = micSegmenter
        let sysRec = systemRecorder, micRec = micRecorder
        let sysQ = systemQueue, micQ = micQueue
        let meter = systemMeter

        systemCapture.onSamples = { samples in
            sysQ.async { sysSeg.append(samples); sysRec.append(samples); meter.feed(samples) }
        }
        systemCapture.onError = { error in
            Task { @MainActor in AppState.shared.captureFailed(error) }
        }
        meter.onLevel = { level in Task { @MainActor in AudioLevels.shared.system = level } }
        micCapture.onSamples = { samples in micQ.async { micSeg.append(samples); micRec.append(samples) } }
        micCapture.onLevel = { level in Task { @MainActor in AudioLevels.shared.mic = level } }

        for (seg, speaker) in [(sysSeg, Speaker.interviewer), (micSeg, Speaker.me)] {
            seg.onSpeechStart = { id in Task { @MainActor in AppState.shared.speechStarted(speaker, id: id) } }
            seg.onPartial = { id, audio in Task { @MainActor in await AppState.shared.handlePartial(speaker, id: id, audio) } }
            seg.onPiece = { id, audio in Task { @MainActor in AppState.shared.handlePiece(speaker, id: id, audio) } }
            seg.onFinal = { id, tail, voice in
                Task { @MainActor in await AppState.shared.handleFinal(speaker, id: id, tail: tail, hasVoice: voice) }
            }
            seg.onDiscard = { id in Task { @MainActor in AppState.shared.discard(speaker, id: id) } }
        }
        for (rec, speaker) in [(sysRec, Speaker.interviewer), (micRec, Speaker.me)] {
            rec.onPartial = { id, audio in Task { @MainActor in await AppState.shared.handlePartial(speaker, id: id, audio) } }
            rec.onPiece = { id, audio in Task { @MainActor in AppState.shared.handlePiece(speaker, id: id, audio) } }
        }
    }

    private func queue(_ speaker: Speaker) -> DispatchQueue { speaker == .interviewer ? systemQueue : micQueue }
    private func recorder(_ speaker: Speaker) -> ManualRecorder { speaker == .interviewer ? systemRecorder : micRecorder }

    private var speechOptions: SpeechOptions {
        SpeechOptions(language: settings.speechLanguage.whisperCode, vocabulary: settings.vocabulary,
                      precise: settings.preciseTerms)
    }

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

    /// Problem that blocks answers right now (shown in the readiness checklist), nil = fine.
    var connectionProblem: String? {
        if settings.backend == .api && settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Не задан API-ключ Anthropic"
        }
        if let p = settings.backend.provider, p.needsKey, settings.providerKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Не задан API-ключ \(p.shortName)"
        }
        if settings.backend.provider != nil, settings.providerModel.isEmpty {
            return "Не выбрана модель"
        }
        if settings.backend == .claudeCode && !cliClient.isInstalled {
            return "Claude Code не найден"
        }
        return nil
    }

    private func sessionStarted() {
        guard !isListening else { return }
        isListening = true
        sessionStart = Date()
        if let problem = connectionProblem {
            showError("Подсказок не будет: \(problem.lowercased()). Откройте настройки (⚙︎) → «Модель ИИ».")
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
        modelFailed = false
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
            modelFailed = true
            modelStatus = "Ошибка модели речи"
            showError("Не удалось загрузить модель речи: \(error.localizedDescription). Проверьте интернет и нажмите «Скачать модель заново» в настройках → «Речь».")
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
            if !isListening && recording.isEmpty { micCapture.stop() }
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
    }

    func toggleListening() {
        Task {
            if settings.listenMode == .manual {
                if isListening { stop() } else { note = "Режим «По кнопкам»: нажмите «Интервьюер» или «Я»" }
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
        note = nil
        if !modelReady {
            note = "Жду модель речи — прослушивание начнётся само"
            await loadSpeechModel()
            note = nil
        }
        guard modelReady else { return }
        setAutoSegmentation(true)
        guard await ensureCaptures(system: true, mic: settings.captureMic, micRequired: false) else { return }
        sessionStarted()
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
        recordingSince.removeAll()
        speaking.removeAll()
        partial.removeAll()
        utterances.removeAll()
        AudioLevels.shared.system = 0
        AudioLevels.shared.mic = 0
        if wasListening { saveSession() }
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
        note = nil
        setAutoSegmentation(false)
        let ok = await ensureCaptures(system: speaker == .interviewer, mic: speaker == .me, micRequired: true)
        guard ok else { return }
        sessionStarted()
        manualID += 1
        let id = manualID
        utterances[speaker] = Utterance(id: id, speaker: speaker)
        let rec = recorder(speaker)
        queue(speaker).sync { rec.start(id: id) }
        recording.insert(speaker)
        recordingSince[speaker] = Date()
        if !modelReady { Task { await loadSpeechModel() } }
    }

    private func finishRecording(_ speaker: Speaker) async {
        let rec = recorder(speaker)
        let stopped = queue(speaker).sync { rec.stop() }
        recording.remove(speaker)
        recordingSince[speaker] = nil
        guard let u = utterances[speaker] else { return }
        recognizing.insert(speaker)
        let result = await finish(u, tail: stopped.tail, hasVoice: stopped.hasVoice, urgent: true)
        recognizing.remove(speaker)
        partial[speaker] = utterances[speaker]?.caption.nilIfEmpty
        guard !result.text.isEmpty else {
            showError("Речь не распознана. Проверьте, что звук идёт, и попробуйте ещё раз.")
            return
        }
        entries.append(TranscriptEntry(speaker: speaker, text: result.text, date: Date(), recognitionSeconds: result.seconds))
        currentQuestion = result.text
        questionStartedAt = Date()
        let ctx = context(before: Date().addingTimeInterval(-0.5))
        if speaker == .interviewer {
            ask(question: result.text, prompt: Prompts.question(context: ctx, question: result.text),
                recognition: result.seconds, replaceCurrent: false)
        } else {
            ask(question: "Я: " + result.text, prompt: Prompts.mine(context: ctx, text: result.text),
                recognition: result.seconds, replaceCurrent: false)
        }
    }

    // MARK: - Piece-by-piece recognition (both modes)

    /// Recognises one finished piece of a phrase in the background. Pieces are chained:
    /// each starts after the previous one and gets its text as context.
    private func addPiece(_ u: Utterance, _ audio: [Float], urgent: Bool) {
        let previous = u.pieces.last
        let tr = transcriber
        let options = speechOptions
        let task = Task<Recognized, Never> {
            let before = await previous?.value
            var opts = options
            // «Авто»: one phrase stays in one language — the one its first piece was recognised in.
            if opts.language == nil, let lang = before?.language { opts.language = lang }
            return await tr.recognize(audio, options: opts, context: before?.text ?? "", urgent: urgent)
        }
        u.pieces.append(task)
        u.partial = ""
        Task { [weak self] in
            let text = await task.value.text
            guard let self else { return }
            u.finished += 1
            if !text.isEmpty { u.done.append(text) }
            if self.utterances[u.speaker] === u { self.partial[u.speaker] = u.caption.nilIfEmpty }
        }
    }

    /// The phrase ended: recognise the tail and join all pieces.
    private func finish(_ u: Utterance, tail: [Float], hasVoice: Bool, urgent: Bool) async -> (text: String, seconds: Double) {
        let started = Date()
        if hasVoice && !tail.isEmpty { addPiece(u, tail, urgent: urgent) }
        if utterances[u.speaker] === u { utterances[u.speaker] = nil }
        var texts: [String] = []
        for piece in u.pieces { texts.append(await piece.value.text) }
        let text = texts.filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (Transcriber.collapseRepeats(text), Date().timeIntervalSince(started))
    }

    private func speechStarted(_ speaker: Speaker, id: Int) {
        speaking.insert(speaker)
        utterances[speaker] = Utterance(id: id, speaker: speaker)
    }

    private func handlePiece(_ speaker: Speaker, id: Int, _ audio: [Float]) {
        guard let u = utterances[speaker], u.id == id else { return }
        addPiece(u, audio, urgent: speaker == .interviewer || settings.listenMode == .manual)
    }

    private func handlePartial(_ speaker: Speaker, id: Int, _ audio: [Float]) async {
        guard let u = utterances[speaker], u.id == id else { return }
        let text = await transcriber.transcribePartialIfIdle(audio, options: speechOptions, context: u.done.last ?? "")
        guard let text, !text.isEmpty, utterances[speaker] === u, u.pieces.count == u.finished else { return }
        u.partial = text
        partial[speaker] = u.caption
    }

    private func discard(_ speaker: Speaker, id: Int) {
        guard let u = utterances[speaker], u.id == id else { return }
        utterances[speaker] = nil
        speaking.remove(speaker)
        partial[speaker] = nil
    }

    // MARK: - Speech events (mode «Авто»)

    private func handleFinal(_ speaker: Speaker, id: Int, tail: [Float], hasVoice: Bool) async {
        speaking.remove(speaker)
        guard let u = utterances[speaker], u.id == id else { return }
        if speaker == .interviewer { recognizing.insert(speaker) }
        let result = await finish(u, tail: tail, hasVoice: hasVoice, urgent: speaker == .interviewer)
        recognizing.remove(speaker)
        partial[speaker] = utterances[speaker]?.caption.nilIfEmpty
        guard !result.text.isEmpty, isListening, settings.listenMode == .auto else { return }
        if speaker == .me {
            // The microphone heard the interviewer from the speakers → not my words.
            if isEcho(result.text) { return }
            lastMeSpeechAt = Date()
        }
        entries.append(TranscriptEntry(speaker: speaker, text: result.text, date: Date(), recognitionSeconds: result.seconds))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        if speaker == .interviewer { interviewerSaid(result.text, recognition: result.seconds) }
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

    private func interviewerSaid(_ text: String, recognition: Double) {
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
                recognition: recognition, replaceCurrent: continuing)
        }
    }

    // MARK: - Actions

    /// Hotkey «ответить сейчас»: closes the current phrase immediately, or re-answers the last question.
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

    func testConnection() {
        ask(question: "Проверка связи", prompt: "Тест связи: ответь одним словом «работает».", replaceCurrent: false)
    }

    func solveScreenshot() {
        Task {
            do {
                note = "Скриншот…"
                let jpeg = try await ScreenGrabber.captureJPEG()
                note = nil
                ask(question: "Задача с экрана", prompt: Prompts.screenshot(context: context(before: Date()),
                                                     customFormat: !settings.answerFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    image: jpeg, replaceCurrent: false)
            } catch {
                note = nil
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

    // MARK: - Model

    private func context(before date: Date) -> String {
        let recent = entries.filter { $0.date < date }.suffix(24)
        var lines = recent.map { "[\($0.speaker.label)] \($0.text)" }
        // Keep the context compact → faster time-to-first-token.
        while lines.joined(separator: "\n").count > 6000, !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    private func makeRequest(text: String, image: Data? = nil) -> LLMRequest {
        LLMRequest(system: Prompts.system(settings), text: text, imageJPEG: image,
                   model: settings.activeModel, effort: settings.effort, fastMode: settings.fastMode)
    }

    /// Client for the current connection: Claude API, Claude Code or an OpenAI-compatible provider.
    private var currentClient: LLMClient {
        if let p = settings.backend.provider {
            return OpenAICompatClient(provider: p, key: settings.providerKey, baseURL: settings.providerURL)
        }
        return settings.backend == .api ? apiClient : cliClient
    }

    /// Warms whatever the current connection needs: the prompt cache (API), a waiting CLI
    /// process (subscription) or the TLS connection (other providers).
    func prewarmLLM() {
        let req = makeRequest(text: "ping")
        lastWarmKey = warmKey
        switch settings.backend {
        case .api:
            guard !settings.apiKey.isEmpty else { return }
            let client = apiClient
            Task.detached(priority: .utility) { await client.prewarm(req) }
        case .claudeCode:
            let client = cliClient
            Task.detached(priority: .utility) { client.prewarm(req) }
        default:
            guard let p = settings.backend.provider else { return }
            let client = OpenAICompatClient(provider: p, key: settings.providerKey, baseURL: settings.providerURL)
            Task.detached(priority: .utility) { await client.prewarm() }
        }
    }

    private var warmKey: String {
        "\(settings.backend.rawValue)|\(settings.activeModel)|\(settings.effort)|\(settings.fastMode)|\(Prompts.system(settings).hashValue)"
    }

    private func prewarmIfChanged() {
        if warmKey != lastWarmKey { prewarmLLM() }
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

    private func ask(question: String, prompt: String, image: Data? = nil, recognition: Double? = nil, replaceCurrent: Bool) {
        answerTask?.cancel()
        markStopped()

        var item = AnswerItem(question: question)
        item.recognitionSeconds = recognition
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
        let client = currentClient
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
        let dir = Self.sessionsFolder
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

    // MARK: - Demo content (`--snapshot`)

    enum DemoKind { case empty, recording, answers, auto }

    func prepareDemo(_ kind: DemoKind) {
        modelReady = true
        modelProgress = nil
        modelStatus = "Распознавание готово"
        errorMessage = nil
        note = nil
        isListening = false
        recording = []
        recordingSince = [:]
        speaking = []
        partial = [:]
        recognizing = []
        entries = []
        answers = []
        currentAnswerID = nil
        func answer(_ q: String, _ t: String, expanded: Bool, streaming: Bool = false) -> AnswerItem {
            var a = AnswerItem(question: q)
            a.text = t
            a.isStreaming = streaming
            a.expanded = expanded
            a.recognitionSeconds = 0.6
            a.firstTokenSeconds = streaming && t.isEmpty ? nil : 1.1
            return a
        }
        let old1 = answer("Добрый день! Расскажите немного о себе.",
                          "**Я бэкенд-разработчик, пять лет в финтехе: платежи и высоконагруженные API.**\n- Последние два года — тимлид команды из 4 человек.", expanded: false)
        let old2 = answer("Почему уходите с текущего места?",
                          "**Хочу расти в архитектуре распределённых систем — в текущей компании задачи стали однотипными.**", expanded: false)
        let main = answer("Чем процесс отличается от потока?", """
        **Процесс — изолированная программа со своей памятью, поток — единица выполнения внутри процесса.**
        - Потоки одного процесса делят память, поэтому переключаться между ними дешевле.
        - Процессы изолированы: падение одного не роняет остальные.
        - Общение: у потоков — общая память и `mutex`, у процессов — IPC (сокеты, пайпы).
        - Пример: воркеры я запускал горутинами, а обработку видео — отдельными процессами.
        """, expanded: true)
        let lines: [(Speaker, String, Double)] = [
            (.interviewer, "Добрый день! Расскажите немного о себе.", 0.6),
            (.me, "Да, конечно. Я бэкенд-разработчик, пять лет в финтехе.", 0.5),
            (.interviewer, "Чем процесс отличается от потока?", 0.6),
        ]
        entries = lines.map { TranscriptEntry(speaker: $0.0, text: $0.1, date: Date(), recognitionSeconds: $0.2) }
        switch kind {
        case .empty:
            entries = []
            settings.listenMode = .manual
        case .recording:
            settings.listenMode = .manual
            answers = [old1, old2]
            recording = [.interviewer]
            recordingSince = [.interviewer: Date().addingTimeInterval(-7)]
            partial = [.interviewer: "Как бы вы спроектировали систему уведомлений, если пользователей"]
        case .answers:
            settings.listenMode = .manual
            answers = [old1, old2, main]
            currentAnswerID = main.id
        case .auto:
            settings.listenMode = .auto
            isListening = true
            speaking = [.interviewer]
            answers = [old1, answer("Как бы вы спроектировали систему уведомлений?", "", expanded: true, streaming: true)]
            currentAnswerID = answers.last?.id
            partial = [.interviewer: "И сколько сообщений в секунду она должна"]
        }
    }

    // MARK: - End-to-end replay (`--replay <file.wav>`)

    /// Plays a recorded question through the «По кнопкам» pipeline (pieces while «recording»,
    /// tail after the second press) and the configured model, and prints the timings.
    func replay(file: URL) async -> Int32 {
        guard let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: file.path) else { return 1 }
        await loadSpeechModel()
        guard modelReady else { print("model failed"); return 1 }
        print("backend: \(settings.backend.rawValue) · model: \(settings.activeModel) · effort: \(settings.effort)")
        prewarmLLM()
        try? await Task.sleep(nanoseconds: 5_000_000_000)   // the CLI / connection is warm, like during a call
        settings.listenMode = .manual
        isListening = true
        manualID += 1
        let id = manualID
        utterances[.interviewer] = Utterance(id: id, speaker: .interviewer)
        let rec = systemRecorder
        systemQueue.sync { rec.start(id: id) }
        recording.insert(.interviewer)
        let started = Date()
        var offset = 0
        while offset < samples.count {
            let chunk = Array(samples[offset..<min(samples.count, offset + 1_600)])
            offset += chunk.count
            systemQueue.async { rec.append(chunk) }
            let wait = started.addingTimeInterval(Double(offset) / 16_000).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        let pressed = Date()
        await finishRecording(.interviewer)
        guard let item = answers.last else { print("no answer: \(errorMessage ?? "")"); return 1 }
        print(String(format: "распознано за %.2f с: «%@»", item.recognitionSeconds ?? -1, entries.last?.text ?? ""))
        while answers.last?.isStreaming == true { try? await Task.sleep(nanoseconds: 50_000_000) }
        let a = answers.last!
        print(String(format: "первые слова ответа: %.2f с после распознавания, %.2f с после второго нажатия",
                     a.firstTokenSeconds ?? -1, (a.firstTokenSeconds ?? 0) + (a.recognitionSeconds ?? 0)))
        print("ответ: \(a.error ?? a.text)")
        _ = pressed
        cliClient.shutdown()
        return a.error == nil ? 0 : 1
    }

    // MARK: - Benchmark

    func runBenchmark(folder: URL) async -> Int32 {
        await transcriber.benchmark(folder: folder, model: settings.whisperModel, vocabulary: settings.vocabulary)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
