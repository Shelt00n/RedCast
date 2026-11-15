import Foundation
import WhisperKit

/// What to recognise and how (built from the settings on the main actor).
struct SpeechOptions: Sendable {
    /// Whisper language code; nil = detect among ru / uk / en.
    var language: String?
    /// Terms to bias recognition towards (stack, companies, names).
    var vocabulary: String
    /// Feed the terms (and the previous piece) to Whisper as a prompt. More exact spelling of
    /// terms, but every prompt token costs one decoder pass (~13 ms on M-series): off by default,
    /// the answer model gets the terms anyway and fixes misheard words.
    var precise = false

    static let allowedLanguages: Set<String> = ["ru", "uk", "en"]
}

/// Recognised text and the language it was recognised in.
struct Recognized: Sendable {
    var text: String
    var language: String?
}

/// Thread-safe flag: lets a final result stop a live caption that is being decoded.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// On-device speech recognition (Whisper Large v3 Turbo via CoreML / Neural Engine).
/// All calls are serialized: WhisperKit must not decode two buffers at once.
actor Transcriber {
    enum State: Equatable { case notLoaded, loading, ready, failed(String) }

    private(set) var state: State = .notLoaded
    private var pipe: WhisperKit?
    private var loadedModel = ""
    private var vocabTokens: [Int] = []
    private var vocabSource: String?
    /// Last language detected in «auto» mode: used when detection picks something odd.
    private var lastLanguage = "ru"

    private var busy = false
    private var partialRunning = false
    private let abortPartial = AbortFlag()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []

    /// Each prompt token costs one decoder pass, so the prompt is kept short.
    static let maxVocabularyTokens = 32
    static let maxContextTokens = 24

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RedCast/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var isReady: Bool { state == .ready }

    /// Forget the loaded model (before re-downloading it).
    func reset() {
        pipe = nil
        loadedModel = ""
        state = .notLoaded
    }

    private var loadTask: Task<Void, Error>?

    /// Folder of an already downloaded model (so the app starts offline and instantly).
    static func localFolder(for model: String) -> URL? {
        let dir = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)", isDirectory: true)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let fm = FileManager.default
        return required.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) ? dir : nil
    }

    func load(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if pipe != nil && loadedModel == model { return }
        if let running = loadTask {
            try await running.value
            if pipe != nil && loadedModel == model { return }
        }
        let task = Task { try await self.performLoad(model: model, progress: progress) }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        state = .loading
        do {
            // Already on disk → load it right away (offline, instant). Otherwise download first:
            // the downloader skips complete files and finishes partial ones.
            var folder: URL
            if let local = Self.localFolder(for: model) {
                folder = local
            } else {
                folder = try await Self.download(model, progress: progress)
            }
            progress(1.0)
            let p: WhisperKit
            do {
                p = try await Self.makePipe(model: model, folder: folder)
            } catch {
                // Damaged model files ("Unable to load model … Compile the model …"):
                // delete them and download a clean copy once.
                Self.deleteModel(model)
                folder = try await Self.download(model, progress: progress)
                progress(1.0)
                p = try await Self.makePipe(model: model, folder: folder)
            }
            pipe = p
            loadedModel = model
            vocabSource = nil
            // Warm-up decode so the first real question is not slow.
            _ = try? await p.transcribe(audioArray: [Float](repeating: 0, count: 16_000))
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private static func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(
            variant: model,
            downloadBase: modelsDirectory,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
    }

    private static func makePipe(model: String, folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: model,
            downloadBase: modelsDirectory,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// Removes a model and its download bookkeeping so it is fetched again from scratch.
    static func deleteModel(_ model: String) {
        let repo = modelsDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: repo.appendingPathComponent("openai_whisper-\(model)", isDirectory: true))
        try? fm.removeItem(at: repo.appendingPathComponent(".cache/huggingface/download/openai_whisper-\(model)", isDirectory: true))
    }

    // MARK: - Recognition

    /// Final (accurate) recognition. Waits for its turn.
    /// `urgent` (interviewer / button press) jumps ahead of background work (my microphone).
    /// `context` — text spoken just before this audio (earlier pieces of the same phrase).
    func recognize(_ samples: [Float], options: SpeechOptions, context: String = "", urgent: Bool = false) async -> Recognized {
        // A piece recorded while the model was still loading waits for it instead of being lost.
        if pipe == nil, let loading = loadTask { _ = try? await loading.value }
        await acquire(urgent: urgent)
        defer { release() }
        return await run(samples, options: options, context: context, retries: 2, abort: nil)
    }

    func transcribe(_ samples: [Float], options: SpeechOptions, context: String = "", urgent: Bool = false) async -> String {
        await recognize(samples, options: options, context: context, urgent: urgent).text
    }

    /// Live caption: skipped if the model is busy, and stopped as soon as a final result
    /// is waiting, so it never delays one.
    func transcribePartialIfIdle(_ samples: [Float], options: SpeechOptions, context: String = "") async -> String? {
        guard !busy, pipe != nil else { return nil }
        busy = true
        partialRunning = true
        abortPartial.set(false)
        defer {
            partialRunning = false
            release()
        }
        var forced = options
        forced.language = options.language ?? lastLanguage   // no detection pass for captions
        let result = await run(samples, options: forced, context: context, retries: 0, abort: abortPartial)
        return abortPartial.isSet ? nil : result.text
    }

    // MARK: - Internals

    private func acquire(urgent: Bool) async {
        if !busy {
            busy = true
            return
        }
        if partialRunning { abortPartial.set(true) }
        await withCheckedContinuation { cont in
            if urgent { urgentWaiters.append(cont) } else { waiters.append(cont) }
        }
    }

    private func release() {
        if !urgentWaiters.isEmpty {
            urgentWaiters.removeFirst().resume()
        } else if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            busy = false
        }
    }

    private func promptTokens(options: SpeechOptions, context: String) -> [Int]? {
        guard options.precise, let tokenizer = pipe?.tokenizer else { return nil }
        let vocabulary = options.vocabulary
        let limit = tokenizer.specialTokens.specialTokenBegin
        let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != vocabSource {
            vocabSource = trimmed
            vocabTokens = trimmed.isEmpty ? [] : Array(tokenizer.encode(text: " " + trimmed).filter { $0 < limit }
                .prefix(Self.maxVocabularyTokens))
        }
        var tokens = vocabTokens
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            tokens += tokenizer.encode(text: " " + ctx).filter { $0 < limit }.suffix(Self.maxContextTokens)
        }
        return tokens.isEmpty ? nil : tokens
    }

    private struct Decoded {
        var text: String
        var language: String?
    }

    private func run(_ samples: [Float], options: SpeechOptions, context: String, retries: Int, abort: AbortFlag?) async -> Recognized {
        guard pipe != nil, !samples.isEmpty else { return Recognized(text: "", language: options.language) }
        let audio = Self.normalized(samples)
        let prompt = promptTokens(options: options, context: context)
        guard let first = await decode(audio, language: options.language, prompt: prompt, retries: retries, abort: abort) else {
            return Recognized(text: "", language: options.language)
        }
        guard options.language == nil else { return Recognized(text: first.text, language: options.language) }
        // «Auto»: only ru / uk / en make sense in this app. Anything else is a misdetection
        // on a short or noisy phrase → recognise again in the last good language.
        if let lang = first.language, SpeechOptions.allowedLanguages.contains(lang) {
            lastLanguage = lang
            return Recognized(text: first.text, language: lang)
        }
        let again = await decode(audio, language: lastLanguage, prompt: prompt, retries: retries, abort: abort)
        return Recognized(text: again?.text ?? first.text, language: lastLanguage)
    }

    private func decode(_ audio: [Float], language: String?, prompt: [Int]?, retries: Int, abort: AbortFlag?) async -> Decoded? {
        guard let pipe else { return nil }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: retries,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: prompt,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.2,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        let callback: TranscriptionCallback? = abort.map { flag in { @Sendable _ in flag.isSet ? false : nil } }
        do {
            let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options, callback: callback)
            let text = results
                .flatMap { $0.segments }
                .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -0.8) }
                .map { Self.clean($0.text) }
                .filter { !$0.isEmpty && !Self.isHallucination($0) }
                .joined(separator: " ")
            return Decoded(text: Self.collapseRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                           language: results.first?.language)
        } catch {
            return nil
        }
    }

    /// Quiet calls (a soft-spoken interviewer, a far microphone) are brought up to a normal level.
    static func normalized(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0.003, peak < 0.5 else { return samples }
        let gain = min(0.8 / peak, 8)
        return samples.map { $0 * gain }
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// «и так далее, и так далее, и так далее…» → once. Whisper loops on unclear audio.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 6 else { return text }
        var n = 1
        while n <= words.count / 3 {
            var i = 0
            var changed = false
            while i + 3 * n <= words.count {
                let a = words[i..<i + n].map { $0.lowercased() }
                let b = words[i + n..<i + 2 * n].map { $0.lowercased() }
                let c = words[i + 2 * n..<i + 3 * n].map { $0.lowercased() }
                if a == b && b == c {
                    // keep one copy, drop every following repeat
                    var j = i + n
                    while j + n <= words.count && words[j..<j + n].map({ $0.lowercased() }) == a { j += n }
                    words.removeSubrange(i + n..<j)
                    changed = true
                } else {
                    i += 1
                }
            }
            n = changed ? n : n + 1
        }
        return words.joined(separator: " ")
    }

    /// Whisper's well-known phantom phrases on silence / noise (YouTube subtitle credits etc.).
    private static let phantom: [String] = [
        "субтитр", "dimatorzok", "продолжение следует", "спасибо за просмотр",
        "подписывайтесь", "ставьте лайк", "дякую за перегляд", "підписуйтесь",
        "редактор субтитров", "корректор а.", "amara.org", "thanks for watching",
        "смотрите в следующ", "до новых встреч", "музыкальная заставка", "[музыка]", "♪",
        "субтитри", "редактор субтитрів",
    ]

    /// Whole utterances Whisper invents on silence, breathing or clicks.
    private static let phantomExact: Set<String> = [
        "you", "thank you", "thanks", "bye", "okay", "ok", "so", "uh", "um", "hmm", "mm",
        "thank you for watching", "спасибо за внимание", "дякую", "аплодисменты", "смех", "музыка",
        "дякую за увагу",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        let core = t.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if core.isEmpty { return true }
        if phantomExact.contains(core) { return true }
        if phantom.contains(where: { t.contains($0) }) { return true }
        return false
    }

    // MARK: - Benchmark (`RedCast --bench <folder>`)

    /// Measures recognition of every .wav in a folder: one pass over the whole clip
    /// versus the piece-by-piece pipeline the app uses. Prints a table to stdout.
    func benchmark(folder: URL, model: String, vocabulary: String) async -> Int32 {
        do {
            try await load(model: model) { _ in }
        } catch {
            print("load failed: \(error)")
            return 1
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: file.path) else { continue }
            let auto = ProcessInfo.processInfo.environment["RC_AUTO"] != nil
            let lang: String? = auto ? nil : (file.lastPathComponent.hasPrefix("uk") ? "uk" : "ru")
            let opts = SpeechOptions(language: lang, vocabulary: vocabulary)
            let seconds = Double(samples.count) / 16_000
            print("\n■ \(file.lastPathComponent)  (\(String(format: "%.1f", seconds)) с)")

            // A: legacy — whole clip after the end, long vocabulary prompt, 3 retries.
            let legacyPrompt: [Int]? = pipe?.tokenizer.map { t in
                Array(t.encode(text: " " + vocabulary).filter { $0 < t.specialTokens.specialTokenBegin }.suffix(120))
            }
            var t0 = Date()
            let a = await legacyDecode(samples, language: lang, prompt: legacyPrompt)
            print(String(format: "  было:  %.2f с  «%@»", Date().timeIntervalSince(t0), a))

            // B: new options, whole clip, no prompt.
            t0 = Date()
            let b = await run(samples, options: opts, context: "", retries: 2, abort: nil).text
            print(String(format: "  целиком, без подсказки: %.2f с  «%@»", Date().timeIntervalSince(t0), b))

            for precise in [false, true] {
                var o = opts
                o.precise = precise
                let (secs, n, text) = await pieces(samples, options: o)
                print(String(format: "  по кускам%@: %.2f с после конца речи (%d) «%@»",
                             precise ? " + словарь" : "", secs, n, text))
            }
        }
        return 0
    }

    /// Piece-by-piece, paced like real speech: only the tail is left after the end.
    private func pieces(_ samples: [Float], options: SpeechOptions) async -> (Double, Int, String) {
        let recorder = ManualRecorder()
        let collector = PieceCollector()
        recorder.onPiece = { _, piece in collector.add(piece) }
        recorder.start(id: 1)
        var tasks: [Task<String, Never>] = []
        var offset = 0
        let started = Date()
        func enqueue(_ piece: [Float]) {
            let previous = tasks.last
            tasks.append(Task {
                let ctx = await previous?.value ?? ""
                return await self.transcribe(piece, options: options, context: ctx, urgent: true)
            })
        }
        while offset < samples.count {
            let end = min(samples.count, offset + 1_600)
            recorder.append(Array(samples[offset..<end]))
            offset = end
            collector.take().forEach(enqueue)
            let wait = started.addingTimeInterval(Double(offset) / 16_000).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        let stop = recorder.stop()
        let t0 = Date()
        if stop.hasVoice { enqueue(stop.tail) }
        var parts: [String] = []
        for t in tasks { parts.append(await t.value) }
        return (Date().timeIntervalSince(t0), tasks.count, parts.filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func legacyDecode(_ audio: [Float], language: String?, prompt: [Int]?) async -> String {
        guard let pipe else { return "" }
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: language, temperature: 0, temperatureFallbackCount: 3,
            usePrefillPrompt: true, detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true,
            promptTokens: prompt, suppressBlank: true, compressionRatioThreshold: 2.4, logProbThreshold: -1.0,
            noSpeechThreshold: 0.6, chunkingStrategy: .vad)
        let r = (try? await pipe.transcribe(audioArray: audio, decodeOptions: options)) ?? []
        return r.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Collects pieces emitted on the recorder's thread (benchmark only).
private final class PieceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [[Float]] = []
    func add(_ p: [Float]) { lock.lock(); pieces.append(p); lock.unlock() }
    func take() -> [[Float]] { lock.lock(); defer { lock.unlock() }; let p = pieces; pieces.removeAll(); return p }
}
