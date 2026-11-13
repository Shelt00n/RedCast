import Foundation
import Security

enum Backend: String, CaseIterable, Identifiable {
    case api
    case claudeCode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .api: return "Anthropic API — ключ (самый быстрый)"
        case .claudeCode: return "Подписка Claude Pro/Max — через Claude Code"
        }
    }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case ru, uk, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .auto: return "Автоопределение (ru / uk / en)"
        }
    }
    /// Whisper language code; nil = detect
    var whisperCode: String? {
        switch self {
        case .ru: return "ru"
        case .uk: return "uk"
        case .auto: return nil
        }
    }
}

enum AnswerLanguage: String, CaseIterable, Identifiable {
    case same, ru, uk, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .same: return "На языке вопроса"
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .en: return "English"
        }
    }
    var instruction: String {
        switch self {
        case .same: return "Отвечай на том же языке, на котором задан вопрос (русский → русский, украинский → украинский, английский → английский)."
        case .ru: return "Всегда отвечай на русском языке."
        case .uk: return "Завжди відповідай українською мовою."
        case .en: return "Always answer in English."
        }
    }
}

enum ListenMode: String, CaseIterable, Identifiable {
    case auto, manual
    var id: String { rawValue }
    var title: String { self == .auto ? "Авто" : "По кнопкам" }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let title: String
}

enum Catalog {
    static let claudeModels: [ModelOption] = [
        ModelOption(id: "claude-opus-5-5", title: "Claude Opus 5.5 — самый умный (по умолчанию)"),
        ModelOption(id: "claude-sonnet-5-5", title: "Claude Sonnet 5.5 — быстрее"),
        ModelOption(id: "claude-haiku-5-5", title: "Claude Haiku 5.5 — максимально быстрый"),
    ]
    static let efforts: [ModelOption] = [
        ModelOption(id: "low", title: "low — быстрый ответ (рекомендуется)"),
        ModelOption(id: "medium", title: "medium — глубже, медленнее"),
        ModelOption(id: "high", title: "high — для сложных задач"),
    ]
    static let whisperModels: [ModelOption] = [
        ModelOption(id: "large-v3-v20240930_turbo", title: "Whisper Large v3 Turbo — лучшая точность и скорость (~1.6 ГБ)"),
        ModelOption(id: "large-v3-v20240930_626MB", title: "Whisper Large v3 Turbo сжатая (~0.6 ГБ, для 8 ГБ RAM)"),
    ]
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Claude
    @Published var backend: Backend { didSet { d.set(backend.rawValue, forKey: "backend") } }
    @Published var apiKey: String { didSet { Keychain.save(apiKey, account: "anthropic-api-key") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var effort: String { didSet { d.set(effort, forKey: "effort") } }
    @Published var fastMode: Bool { didSet { d.set(fastMode, forKey: "fastMode") } }
    @Published var claudePath: String { didSet { d.set(claudePath, forKey: "claudePath") } }

    // Speech
    @Published var speechLanguage: SpeechLanguage { didSet { d.set(speechLanguage.rawValue, forKey: "speechLanguage") } }
    @Published var whisperModel: String { didSet { d.set(whisperModel, forKey: "whisperModel") } }
    @Published var vocabulary: String { didSet { d.set(vocabulary, forKey: "vocabulary") } }
    @Published var silenceMs: Double { didSet { d.set(silenceMs, forKey: "silenceMs") } }
    @Published var captureMic: Bool { didSet { d.set(captureMic, forKey: "captureMic") } }
    @Published var autoAnswer: Bool { didSet { d.set(autoAnswer, forKey: "autoAnswer") } }
    @Published var listenMode: ListenMode { didSet { d.set(listenMode.rawValue, forKey: "listenMode") } }
    @Published var echoCancellation: Bool { didSet { d.set(echoCancellation, forKey: "echoCancellation") } }

    // Profile
    @Published var answerLanguage: AnswerLanguage { didSet { d.set(answerLanguage.rawValue, forKey: "answerLanguage") } }
    @Published var resume: String { didSet { d.set(resume, forKey: "resume") } }
    @Published var jobDescription: String { didSet { d.set(jobDescription, forKey: "jobDescription") } }
    @Published var extraInstructions: String { didSet { d.set(extraInstructions, forKey: "extraInstructions") } }

    // Overlay
    @Published var overlayOpacity: Double { didSet { d.set(overlayOpacity, forKey: "overlayOpacity") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var hideFromScreenShare: Bool { didSet { d.set(hideFromScreenShare, forKey: "hideFromScreenShare") } }

    private init() {
        backend = Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .api
        apiKey = Keychain.load(account: "anthropic-api-key") ?? ""
        model = d.string(forKey: "model") ?? "claude-opus-5-5"
        effort = d.string(forKey: "effort") ?? "low"
        fastMode = d.object(forKey: "fastMode") as? Bool ?? false
        claudePath = d.string(forKey: "claudePath") ?? ""

        speechLanguage = SpeechLanguage(rawValue: d.string(forKey: "speechLanguage") ?? "") ?? .ru
        whisperModel = d.string(forKey: "whisperModel") ?? "large-v3-v20240930_turbo"
        vocabulary = d.string(forKey: "vocabulary") ?? "Собеседование. Kubernetes, Docker, PostgreSQL, Kafka, Redis, React, TypeScript, Python, Java, Go, Swift, REST, gRPC, CI/CD, microservices, SOLID, Big O."
        silenceMs = d.object(forKey: "silenceMs") as? Double ?? 700
        captureMic = d.object(forKey: "captureMic") as? Bool ?? true
        autoAnswer = d.object(forKey: "autoAnswer") as? Bool ?? true
        listenMode = ListenMode(rawValue: d.string(forKey: "listenMode") ?? "") ?? .auto
        echoCancellation = d.object(forKey: "echoCancellation") as? Bool ?? true

        answerLanguage = AnswerLanguage(rawValue: d.string(forKey: "answerLanguage") ?? "") ?? .same
        resume = d.string(forKey: "resume") ?? ""
        jobDescription = d.string(forKey: "jobDescription") ?? ""
        extraInstructions = d.string(forKey: "extraInstructions") ?? ""

        overlayOpacity = d.object(forKey: "overlayOpacity") as? Double ?? 0.94
        fontSize = d.object(forKey: "fontSize") as? Double ?? 15
        hideFromScreenShare = d.object(forKey: "hideFromScreenShare") as? Bool ?? true
    }
}

enum Keychain {
    private static let service = "com.redcast.app"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
