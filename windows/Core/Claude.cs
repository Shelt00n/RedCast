using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace RedCast.Core;

public sealed record LLMRequest(string System, string Text, byte[]? ImageJpeg, string Model, string Effort, bool FastMode)
{
    public JsonArray ContentBlocks()
    {
        var arr = new JsonArray();
        if (ImageJpeg != null)
            arr.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = "image/jpeg",
                    ["data"] = Convert.ToBase64String(ImageJpeg),
                },
            });
        arr.Add(new JsonObject { ["type"] = "text", ["text"] = Text });
        return arr;
    }
}

public sealed class LLMException : Exception
{
    public int Status { get; }
    public LLMException(string message, int status = 0) : base(message) { Status = status; }
}

public interface ILLMClient
{
    /// <summary>Streams answer text; onText is called for each chunk (any thread).</summary>
    Task StreamAsync(LLMRequest r, Action<string> onText, CancellationToken ct);
}

/// <summary>Anthropic Messages API: raw HTTP + SSE streaming.</summary>
public sealed class AnthropicApiClient : ILLMClient
{
    static readonly Uri Endpoint = new("https://api.anthropic.com/v1/messages");
    readonly Func<string> _apiKey;
    readonly HttpClient _http;

    public AnthropicApiClient(Func<string> apiKey)
    {
        _apiKey = apiKey;
        var handler = new SocketsHttpHandler
        {
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(10),
            EnableMultipleHttp2Connections = true,
        };
        _http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    static bool SupportsFallback(string model) =>
        model.StartsWith("claude-opus-5-5") || model.StartsWith("claude-sonnet-5-5") || model.StartsWith("claude-fable");

    HttpRequestMessage Build(LLMRequest r, bool stream, int maxTokens, bool fast, bool withFallback)
    {
        var key = _apiKey().Trim();
        if (key.Length == 0) throw new LLMException("Не задан API-ключ Anthropic (вкладка «Настройки» → Claude).");

        var body = new JsonObject
        {
            ["model"] = r.Model,
            ["max_tokens"] = maxTokens,
            // Instructions + resume + vacancy are identical for every question → prompt cache.
            ["system"] = new JsonArray(new JsonObject
            {
                ["type"] = "text",
                ["text"] = r.System,
                ["cache_control"] = new JsonObject { ["type"] = "ephemeral" },
            }),
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = r.ContentBlocks() }),
            ["thinking"] = new JsonObject { ["type"] = "adaptive" },
            ["output_config"] = new JsonObject { ["effort"] = r.Effort },
        };
        if (stream) body["stream"] = true;
        if (fast) body["speed"] = "fast";
        bool fb = withFallback && SupportsFallback(r.Model);
        if (fb) body["fallbacks"] = "default";

        var req = new HttpRequestMessage(HttpMethod.Post, Endpoint)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
            Version = HttpVersion.Version20,
            VersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
        req.Headers.Add("x-api-key", key);
        req.Headers.Add("anthropic-version", "2026-10-21");
        if (fb) req.Headers.Add("anthropic-beta", "server-side-fallback-2026-07-01");
        return req;
    }

    /// <summary>Writes the system prompt into the prompt cache and opens the connection.</summary>
    public async Task PrewarmAsync(LLMRequest r)
    {
        try
        {
            using var req = Build(r, stream: false, maxTokens: 0, fast: r.FastMode, withFallback: false);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var _ = await _http.SendAsync(req, cts.Token);
        }
        catch { }
    }

    public async Task StreamAsync(LLMRequest r, Action<string> onText, CancellationToken ct)
    {
        try
        {
            await StreamOnceAsync(r, r.FastMode, onText, ct);
        }
        catch (LLMException e) when (r.FastMode && (e.Status == 400 || e.Status == 429 || e.Status == 529))
        {
            await StreamOnceAsync(r, false, onText, ct);   // fast mode unavailable → standard speed
        }
    }

    async Task StreamOnceAsync(LLMRequest r, bool fast, Action<string> onText, CancellationToken ct)
    {
        using var req = Build(r, stream: true, maxTokens: 8000, fast: fast, withFallback: true);
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var err = await resp.Content.ReadAsStringAsync(ct);
            throw new LLMException($"Ошибка API {(int)resp.StatusCode}: {ErrorMessage(err)}", (int)resp.StatusCode);
        }
        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(ct);
            if (line == null) break;
            if (!line.StartsWith("data:")) continue;
            JsonNode? obj;
            try { obj = JsonNode.Parse(line.Substring(5).Trim()); } catch { continue; }
            var type = obj?["type"]?.GetValue<string>();
            switch (type)
            {
                case "content_block_delta":
                    var delta = obj!["delta"];
                    if (delta?["type"]?.GetValue<string>() == "text_delta")
                        onText(delta["text"]?.GetValue<string>() ?? "");
                    break;
                case "message_delta":
                    if (obj!["delta"]?["stop_reason"]?.GetValue<string>() == "refusal")
                        throw new LLMException("Модель отказалась отвечать на этот запрос.");
                    break;
                case "error":
                    throw new LLMException("Ошибка API: " + (obj!["error"]?["message"]?.GetValue<string>() ?? "неизвестная"));
            }
        }
    }

    static string ErrorMessage(string body)
    {
        try { return JsonNode.Parse(body)?["error"]?["message"]?.GetValue<string>() ?? body; }
        catch { return body; }
    }
}

/// <summary>
/// Claude Code CLI in headless mode — uses the Claude Pro/Max subscription login.
/// A process is started in advance and waits for the question on stdin, so the CLI start-up
/// (1–2 s) is not on the critical path. stdin is stream-json: with plain text input the CLI gives up
/// after 3 s without data («no stdin data received in 3s») and exits, so the pre-started process was
/// always dead by the time the question came and every answer paid the full cold start.
/// </summary>
public sealed class ClaudeCodeClient : ILLMClient
{
    sealed record Spawned(Process Proc, string Key);

    readonly Func<string> _customPath;
    readonly object _lock = new();
    Spawned? _warm;
    readonly string _workDir;

    public ClaudeCodeClient(Func<string> customPath)
    {
        _customPath = customPath;
        _workDir = Path.Combine(Path.GetTempPath(), "redcast-claude");
        Directory.CreateDirectory(_workDir);
        // The prompt files hold the resume: remove the ones left by earlier runs (killed processes, crashes).
        // RedCast is single-instance, so at this point none of them is in use.
        foreach (var f in Directory.GetFiles(_workDir, "system-*.txt"))
            TryDelete(f);
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    public string Executable()
    {
        var custom = _customPath().Trim().Trim('"');
        if (custom.Length > 0)
        {
            if (File.Exists(custom)) return custom;
            throw new LLMException($"Claude Code: файл {custom} не найден.");
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new List<string>
        {
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(home, ".claude", "local", "claude.exe"),
        };
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(dir.Trim(), "claude.exe"));
            candidates.Add(Path.Combine(dir.Trim(), "claude.cmd"));
        }
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "claude.cmd"));
        foreach (var c in candidates)
            if (File.Exists(c)) return c;
        throw new LLMException("Claude Code не найден. Установите его (см. README) и войдите: claude → /login.");
    }

    static string Key(LLMRequest r) => $"{r.Model}|{r.Effort}|{r.System.GetHashCode()}";

    Spawned Spawn(LLMRequest r)
    {
        var exe = Executable();
        var sysFile = Path.Combine(_workDir, $"system-{Guid.NewGuid():N}.txt");
        File.WriteAllText(sysFile, r.System, new UTF8Encoding(false));

        var args = new List<string>
        {
            "-p", "--tools", "", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--no-session-persistence", "--strict-mcp-config", "--model", r.Model, "--effort", r.Effort,
            "--system-prompt-file", sysFile, "--input-format", "stream-json",
        };

        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _workDir,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (exe.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            psi.FileName = "cmd.exe";
            psi.Arguments = "/c \"\"" + exe + "\" " + string.Join(" ", args.Select(QuoteForCmd)) + "\"";
        }
        else
        {
            psi.FileName = exe;
            foreach (var a in args) psi.ArgumentList.Add(a);
        }
        // Use the subscription login, never an API key from the environment.
        psi.Environment.Remove("ANTHROPIC_API_KEY");
        psi.Environment.Remove("ANTHROPIC_AUTH_TOKEN");

        Process p;
        try
        {
            p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            // Claude Code may read the file at any time while it runs: delete it only once the process is gone.
            p.Exited += (_, _) => TryDelete(sysFile);
            if (!p.Start()) throw new LLMException("Claude Code: не удалось запустить процесс.");
        }
        catch
        {
            TryDelete(sysFile);
            throw;
        }
        p.StandardInput.AutoFlush = true;
        return new Spawned(p, Key(r));
    }

    static string QuoteForCmd(string a) => a.Length == 0 ? "\"\"" : (a.Contains(' ') ? "\"" + a + "\"" : a);

    public void Prewarm(LLMRequest r)
    {
        lock (_lock)
        {
            if (_warm != null && _warm.Key == Key(r) && !_warm.Proc.HasExited) return;
            try { _warm?.Proc.Kill(true); } catch { }
            try { _warm = Spawn(r); } catch { _warm = null; }
        }
    }

    /// <summary>Is Claude Code installed (readiness checklist)?</summary>
    public bool IsInstalled { get { try { Executable(); return true; } catch { return false; } } }

    /// <summary>Stop the waiting process (app quits).</summary>
    public void Shutdown()
    {
        lock (_lock)
        {
            try { _warm?.Proc.Kill(true); } catch { }
            _warm = null;
        }
    }

    Spawned Take(LLMRequest r)
    {
        Spawned? c;
        lock (_lock) { c = _warm; _warm = null; }
        if (c != null && c.Key == Key(r) && !c.Proc.HasExited) return c;
        try { c?.Proc.Kill(true); } catch { }
        return Spawn(r);
    }

    public async Task StreamAsync(LLMRequest r, Action<string> onText, CancellationToken ct)
    {
        var sp = Take(r);
        _ = Task.Run(() => Prewarm(r));   // prepare the next one right away
        using var reg = ct.Register(() => { try { sp.Proc.Kill(true); } catch { } });

        // The question as one stream-json user message, then close stdin: the CLI answers and exits.
        var msg = new JsonObject
        {
            ["type"] = "user",
            ["message"] = new JsonObject { ["role"] = "user", ["content"] = r.ContentBlocks() },
        };
        try
        {
            await sp.Proc.StandardInput.WriteLineAsync(msg.ToJsonString());
            sp.Proc.StandardInput.Close();
        }
        catch (IOException)
        {
            throw new LLMException("Claude Code завершился раньше времени. Проверьте вход: claude → /login.");
        }

        var stderrTask = sp.Proc.StandardError.ReadToEndAsync();
        bool streamed = false;
        while (true)
        {
            var line = await sp.Proc.StandardOutput.ReadLineAsync();
            if (line == null) break;
            ct.ThrowIfCancellationRequested();
            JsonNode? obj;
            try { obj = JsonNode.Parse(line); } catch { continue; }
            var type = obj?["type"]?.GetValue<string>();
            if (type == "stream_event")
            {
                var ev = obj!["event"];
                if (ev?["type"]?.GetValue<string>() == "content_block_delta" &&
                    ev["delta"]?["type"]?.GetValue<string>() == "text_delta")
                {
                    streamed = true;
                    onText(ev["delta"]?["text"]?.GetValue<string>() ?? "");
                }
            }
            else if (type == "assistant" && !streamed)
            {
                if (obj!["message"]?["content"] is JsonArray content)
                    foreach (var block in content)
                        if (block?["type"]?.GetValue<string>() == "text")
                            onText(block["text"]?.GetValue<string>() ?? "");
                streamed = true;
            }
            else if (type == "result")
            {
                if (obj!["is_error"]?.GetValue<bool>() == true)
                    throw new LLMException("Claude Code: " + (obj["result"]?.GetValue<string>() ?? "ошибка выполнения"));
                break;
            }
        }
        ct.ThrowIfCancellationRequested();
        if (!streamed)
        {
            var err = await stderrTask;
            throw new LLMException("Claude Code: " + (string.IsNullOrWhiteSpace(err)
                ? "пустой ответ (войдите в аккаунт: claude → /login)"
                : err.Trim()));
        }
    }
}
