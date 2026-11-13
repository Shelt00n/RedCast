import Foundation
import WhisperKit

/// On-device speech recognition (Whisper Large v3 Turbo via CoreML / Neural Engine).
/// All calls are serialized: WhisperKit must not decode two buffers at once.
actor Transcriber {
    enum State: Equatable { case notLoaded, loading, ready, failed(String) }

    private(set) var state: State = .notLoaded
    private var pipe: WhisperKit?
    private var loadedModel = ""
    private var promptTokens: [Int]?
    private var promptSource = ""

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RedCast/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var isReady: Bool { state == .ready }

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
            let folder: URL
            if let local = Self.localFolder(for: model) {
                folder = local
            } else {
                folder = try await WhisperKit.download(
                    variant: model,
                    downloadBase: Transcriber.modelsDirectory,
                    progressCallback: { p in progress(p.fractionCompleted) }
                )
            }
            progress(1.0)
            let config = WhisperKitConfig(
                model: model,
                downloadBase: Transcriber.modelsDirectory,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let p = try await WhisperKit(config)
            pipe = p
            loadedModel = model
            promptTokens = nil
            promptSource = ""
            // Warm-up decode so the first real question is not slow.
            _ = try? await p.transcribe(audioArray: [Float](repeating: 0, count: 16_000))
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Final (accurate) transcription. Waits for its turn.
    /// `urgent` (interviewer / button press) jumps ahead of background work (my microphone).
    func transcribe(_ samples: [Float], language: String?, vocabulary: String, urgent: Bool = false) async -> String {
        await acquire(urgent: urgent)
        defer { release() }
        return await run(samples, language: language, vocabulary: vocabulary)
    }

    /// Live caption: skipped if the model is busy so it never delays a final result.
    func transcribePartialIfIdle(_ samples: [Float], language: String?, vocabulary: String) async -> String? {
        guard !busy, pipe != nil else { return nil }
        busy = true
        defer { release() }
        return await run(samples, language: language, vocabulary: vocabulary)
    }

    // MARK: - Internals

    private func acquire(urgent: Bool) async {
        if !busy {
            busy = true
            return
        }
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

    private func tokens(for vocabulary: String) -> [Int]? {
        let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == promptSource { return promptTokens }
        promptSource = trimmed
        guard !trimmed.isEmpty, let tokenizer = pipe?.tokenizer else {
            promptTokens = nil
            return nil
        }
        let ids = tokenizer.encode(text: " " + trimmed)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        promptTokens = ids.isEmpty ? nil : Array(ids.suffix(120))
        return promptTokens
    }

    private func run(_ samples: [Float], language: String?, vocabulary: String) async -> String {
        guard let pipe, !samples.isEmpty else { return "" }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: tokens(for: vocabulary),
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results
                .flatMap { $0.segments }
                .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -0.8) }
                .map { Self.clean($0.text) }
                .filter { !$0.isEmpty && !Self.isHallucination($0) }
                .joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's well-known phantom phrases on silence / noise (YouTube subtitle credits etc.).
    private static let phantom: [String] = [
        "субтитр", "dimatorzok", "продолжение следует", "спасибо за просмотр",
        "подписывайтесь", "ставьте лайк", "дякую за перегляд", "підписуйтесь",
        "редактор субтитров", "корректор а.", "amara.org", "thanks for watching",
        "смотрите в следующ", "до новых встреч", "музыкальная заставка", "[музыка]", "♪",
    ]

    private static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        if phantom.contains(where: { t.contains($0) }) { return true }
        // Pure punctuation / ellipsis
        if t.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)).isEmpty { return true }
        return false
    }
}
