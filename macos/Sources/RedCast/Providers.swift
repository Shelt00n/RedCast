import Foundation

/// A model provider with an OpenAI-compatible Chat Completions API
/// (OpenAI, xAI, Gemini, OpenRouter, DeepSeek, Mistral, Groq, Ollama, LM Studio). Same list as windows/Core/Providers.cs.
struct Provider: Identifiable, Hashable {
    let id: String
    let title: String
    let baseURL: String
    let keyHint: String
    var needsKey = true
    var local = false
    var maxCompletionTokens = false
    var reasoning = false

    /// «ChatGPT», «Ollama»… — the part of the title before the dash.
    var shortName: String { title.components(separatedBy: " — ").first ?? title }
}

enum Providers {
    static let all: [Provider] = [
        Provider(id: "openai", title: "ChatGPT — OpenAI API (ключ)", baseURL: "https://api.openai.com/v1",
                 keyHint: "Ключ: platform.openai.com → API keys. Оплата по факту, отдельно от подписки ChatGPT Plus.",
                 maxCompletionTokens: true, reasoning: true),
        Provider(id: "xai", title: "Grok — xAI API (ключ)", baseURL: "https://api.x.ai/v1",
                 keyHint: "Ключ: console.x.ai → API Keys. Оплата по факту, отдельно от подписки X Premium.",
                 reasoning: true),
        Provider(id: "gemini", title: "Gemini — Google AI Studio (ключ)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                 keyHint: "Ключ: aistudio.google.com → Get API key. Есть бесплатный лимит.",
                 reasoning: true),
        Provider(id: "openrouter", title: "OpenRouter — сотни моделей по одному ключу", baseURL: "https://openrouter.ai/api/v1",
                 keyHint: "Ключ: openrouter.ai → Keys. Один ключ открывает модели OpenAI, Google, xAI, Meta, DeepSeek, Mistral и других.",
                 reasoning: true),
        Provider(id: "deepseek", title: "DeepSeek (ключ)", baseURL: "https://api.deepseek.com/v1",
                 keyHint: "Ключ: platform.deepseek.com → API keys."),
        Provider(id: "mistral", title: "Mistral (ключ)", baseURL: "https://api.mistral.ai/v1",
                 keyHint: "Ключ: console.mistral.ai → API Keys."),
        Provider(id: "groq", title: "Groq — очень быстрые открытые модели (ключ)", baseURL: "https://api.groq.com/openai/v1",
                 keyHint: "Ключ: console.groq.com → API Keys. Есть бесплатный лимит.",
                 reasoning: true),
        Provider(id: "ollama", title: "Ollama — локальная модель на этом компьютере", baseURL: "http://localhost:11434/v1",
                 keyHint: "Ключ не нужен, вопросы не покидают компьютер. Установите Ollama и скачайте модель: ollama pull <модель>.",
                 needsKey: false, local: true),
        Provider(id: "lmstudio", title: "LM Studio — локальная модель на этом компьютере", baseURL: "http://localhost:1234/v1",
                 keyHint: "Ключ не нужен, вопросы не покидают компьютер. В LM Studio загрузите модель и запустите локальный сервер.",
                 needsKey: false, local: true),
    ]

    static func find(_ id: String) -> Provider? { all.first { $0.id == id } }
}

/// OpenAI-compatible Chat Completions: raw HTTP + SSE streaming.
final class OpenAICompatClient: LLMClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private let provider: Provider
    private let key: String
    private let baseURL: String

    init(provider: Provider, key: String, baseURL: String) {
        self.provider = provider
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = url.isEmpty ? provider.baseURL : url
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
    }

    private func makeRequest(_ method: String, _ path: String, body: [String: Any]?) throws -> URLRequest {
        if provider.needsKey && key.isEmpty {
            throw LLMError.message("Не задан API-ключ (\(provider.shortName)): «Настройки» → 1. Подключение модели.")
        }
        guard let url = URL(string: baseURL + path) else {
            throw LLMError.message("Неверный адрес сервера: \(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if provider.id == "openrouter" { req.setValue("RedCast", forHTTPHeaderField: "X-Title") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func body(_ r: LLMRequest, reasoning: Bool) -> [String: Any] {
        let user: Any
        if let img = r.imageJPEG {
            user = [
                ["type": "text", "text": r.text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]],
            ]
        } else {
            user = r.text
        }
        var body: [String: Any] = [
            "model": r.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": r.system],
                ["role": "user", "content": user],
            ],
        ]
        body[provider.maxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = 8000
        if reasoning { body["reasoning_effort"] = r.effort }
        return body
    }

    func stream(_ r: LLMRequest, onText: @escaping @MainActor (String) -> Void) async throws {
        guard !r.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError.message("Не выбрана модель: «Настройки» → 1. Подключение модели → «Список моделей».")
        }
        do {
            try await streamOnce(r, reasoning: provider.reasoning, onText: onText)
        } catch LLMError.http(let code, let msg) where provider.reasoning && code == 400
                    && msg.localizedCaseInsensitiveContains("reasoning") {
            // This model has no reasoning_effort → plain request.
            try await streamOnce(r, reasoning: false, onText: onText)
        }
    }

    private func streamOnce(_ r: LLMRequest, reasoning: Bool, onText: @escaping @MainActor (String) -> Void) async throws {
        let req = try makeRequest("POST", "/chat/completions", body: body(r, reasoning: reasoning))
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            let result = try await Self.session.bytes(for: req)
            bytes = result.0
            response = result.1
        } catch let e as URLError where provider.local && e.code != .cancelled {
            throw LLMError.message("Нет связи с \(baseURL): запущен ли \(provider.shortName)?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw LLMError.http(status, Self.errorMessage(data))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw LLMError.api(err["message"] as? String ?? "неизвестная ошибка")
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                await onText(text)
            }
            if choice["finish_reason"] as? String == "content_filter" { throw LLMError.refusal }
        }
    }

    // Embeddings, speech, images and moderation are useless for answers.
    private static let notChat = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "audio", "realtime",
                                  "image", "imagen", "veo", "rerank", "guard", "aqa", "speech"]

    /// Chat models the key can use (GET /models), sorted by id.
    func listModels() async throws -> [String] {
        var req = try makeRequest("GET", "/models", body: nil)
        req.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            let result = try await Self.session.data(for: req)
            data = result.0
            response = result.1
        } catch let e as URLError {
            throw LLMError.message(provider.local ? "Нет связи с \(baseURL): запущен ли \(provider.shortName)?"
                                                  : "Нет связи: \(e.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status, Self.errorMessage(data)) }
        let list = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        var ids = Set<String>()
        for m in list {
            guard var id = m["id"] as? String else { continue }
            if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)) }
            let lower = id.lowercased()
            if !id.isEmpty && !Self.notChat.contains(where: { lower.contains($0) }) { ids.insert(id) }
        }
        return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func errorMessage(_ data: Data) -> String {
        var obj = try? JSONSerialization.jsonObject(with: data)
        if let arr = obj as? [Any] { obj = arr.first }   // Gemini wraps errors in an array
        if let dict = obj as? [String: Any] {
            if let err = dict["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = dict["message"] as? String { return msg }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}
