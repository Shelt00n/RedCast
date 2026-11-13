import Foundation

struct LLMRequest {
    var system: String
    var text: String
    var imageJPEG: Data?
    var model: String
    var effort: String
    var fastMode: Bool

    var contentBlocks: [[String: Any]] {
        var blocks: [[String: Any]] = []
        if let img = imageJPEG {
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64EncodedString()],
            ])
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }
}

enum LLMError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case api(String)
    case refusal
    case cli(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Не задан API-ключ Anthropic (Настройки → Claude)."
        case .http(let code, let msg): return "Ошибка API \(code): \(msg)"
        case .api(let msg): return "Ошибка API: \(msg)"
        case .refusal: return "Модель отказалась отвечать на этот запрос."
        case .cli(let msg): return "Claude Code: \(msg)"
        }
    }
}

protocol LLMClient {
    func stream(_ request: LLMRequest, onText: @escaping @MainActor (String) -> Void) async throws
}

// MARK: - Anthropic Messages API (raw HTTP + SSE; Swift has no official SDK)

final class AnthropicAPIClient: LLMClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiKey: () -> String
    private let session: URLSession

    init(apiKey: @escaping () -> String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// Server-side refusal fallback is available on these models.
    private func supportsFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5-5") || model.hasPrefix("claude-sonnet-5-5") || model.hasPrefix("claude-fable")
    }

    private func makeRequest(_ r: LLMRequest, stream: Bool, maxTokens: Int, fast: Bool, withFallback: Bool) throws -> URLRequest {
        let key = apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.noAPIKey }

        var body: [String: Any] = [
            "model": r.model,
            "max_tokens": maxTokens,
            // The system prompt (instructions + resume + vacancy) is identical for every question → cache it.
            "system": [["type": "text", "text": r.system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": r.contentBlocks]],
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": r.effort],
        ]
        if stream { body["stream"] = true }
        if fast { body["speed"] = "fast" }
        let useFallback = withFallback && supportsFallback(r.model)
        if useFallback { body["fallbacks"] = "default" }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if useFallback { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Writes the system prompt into the prompt cache and opens the TLS connection,
    /// so the first real question gets the fastest possible time-to-first-token.
    func prewarm(_ r: LLMRequest) async {
        guard var req = try? makeRequest(r, stream: false, maxTokens: 0, fast: r.fastMode, withFallback: false) else { return }
        req.timeoutInterval = 30
        _ = try? await session.data(for: req)
    }

    func stream(_ r: LLMRequest, onText: @escaping @MainActor (String) -> Void) async throws {
        do {
            try await streamOnce(r, fast: r.fastMode, onText: onText)
        } catch LLMError.http(let code, _) where r.fastMode && (code == 429 || code == 400 || code == 529) {
            // Fast mode unavailable / rate-limited → retry at standard speed.
            try await streamOnce(r, fast: false, onText: onText)
        }
    }

    private func streamOnce(_ r: LLMRequest, fast: Bool, onText: @escaping @MainActor (String) -> Void) async throws {
        let req = try makeRequest(r, stream: true, maxTokens: 8000, fast: fast, withFallback: true)
        let (bytes, response) = try await session.bytes(for: req)
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
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    await onText(text)
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                    throw LLMError.refusal
                }
            case "error":
                let err = obj["error"] as? [String: Any]
                throw LLMError.api(err?["message"] as? String ?? "неизвестная ошибка")
            default:
                break
            }
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Claude Code CLI (uses the user's Claude Pro / Max subscription login)

/// Runs `claude -p` in headless mode. A process is spawned in advance and waits for its
/// prompt on stdin, so Node/CLI start-up time is not on the critical path.
final class ClaudeCodeClient: LLMClient, @unchecked Sendable {
    private struct Spawned {
        let process: Process
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe
        let key: String
    }

    private let customPath: () -> String
    private let lock = NSLock()
    private var warm: Spawned?
    private let workDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redcast-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(customPath: @escaping () -> String) {
        self.customPath = customPath
    }

    deinit {
        warm?.process.terminate()
    }

    // MARK: Executable & environment

    private static var cachedLoginPath: String?

    private static func loginShellPath() -> String {
        if let p = cachedLoginPath { return p }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "echo -n $PATH"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !s.isEmpty { path = s }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        path += ":\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin"
        cachedLoginPath = path
        return path
    }

    func executable() throws -> String {
        let fm = FileManager.default
        let custom = customPath().trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            if fm.isExecutableFile(atPath: custom) { return custom }
            throw LLMError.cli("файл \(custom) не найден")
        }
        for dir in Self.loginShellPath().split(separator: ":") {
            let candidate = "\(dir)/claude"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw LLMError.cli("команда `claude` не найдена. Установите Claude Code и выполните `claude` → /login, либо укажите путь в настройках.")
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.loginShellPath()
        // Make sure the CLI authenticates with the subscription login, not an API key.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        return env
    }

    private func arguments(_ r: LLMRequest, streamJSONInput: Bool) -> [String] {
        var args = [
            "-p",
            "--tools", "",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--model", r.model,
            "--effort", r.effort,
            "--system-prompt", r.system,
        ]
        if streamJSONInput { args += ["--input-format", "stream-json"] }
        return args
    }

    private func spawn(_ r: LLMRequest, streamJSONInput: Bool) throws -> Spawned {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try executable())
        p.arguments = arguments(r, streamJSONInput: streamJSONInput)
        p.environment = environment()
        p.currentDirectoryURL = workDir
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = e
        try p.run()
        return Spawned(process: p, stdin: i, stdout: o, stderr: e, key: Self.key(r))
    }

    private static func key(_ r: LLMRequest) -> String {
        "\(r.model)|\(r.effort)|\(r.system.hashValue)"
    }

    /// Spawn a process ahead of time for the next question.
    func prewarm(_ r: LLMRequest) {
        lock.lock()
        defer { lock.unlock() }
        if let w = warm, w.key == Self.key(r), w.process.isRunning { return }
        warm?.process.terminate()
        warm = try? spawn(r, streamJSONInput: false)
    }

    private func takeProcess(_ r: LLMRequest) throws -> Spawned {
        if r.imageJPEG != nil { return try spawn(r, streamJSONInput: true) }
        lock.lock()
        let candidate = warm
        warm = nil
        lock.unlock()
        if let c = candidate, c.key == Self.key(r), c.process.isRunning { return c }
        candidate?.process.terminate()
        return try spawn(r, streamJSONInput: false)
    }

    func stream(_ r: LLMRequest, onText: @escaping @MainActor (String) -> Void) async throws {
        let proc = try takeProcess(r)
        // Immediately prepare the next one.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.prewarm(r) }

        // Send the prompt.
        let input: Data
        if r.imageJPEG != nil {
            let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": r.contentBlocks]]
            input = try JSONSerialization.data(withJSONObject: msg) + Data("\n".utf8)
        } else {
            input = Data(r.text.utf8)
        }
        try proc.stdin.fileHandleForWriting.write(contentsOf: input)
        try proc.stdin.fileHandleForWriting.close()

        try await withTaskCancellationHandler {
            var streamed = false
            for try await line in proc.stdout.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "stream_event",
                   let event = obj["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    streamed = true
                    await onText(text)
                } else if type == "assistant", !streamed,
                          let message = obj["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "text" {
                        if let t = block["text"] as? String { await onText(t) }
                    }
                    streamed = true
                } else if type == "result" {
                    if obj["is_error"] as? Bool == true {
                        throw LLMError.cli(obj["result"] as? String ?? "ошибка выполнения")
                    }
                    break
                }
            }
            proc.process.waitUntilExit()
            if !streamed {
                let err = String(data: proc.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw LLMError.cli(err.isEmpty ? "пустой ответ (проверьте, что вы вошли: claude → /login)" : err)
            }
        } onCancel: {
            proc.process.terminate()
        }
    }
}
