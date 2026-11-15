using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace RedCast.Core;

/// <summary>
/// A model provider with an OpenAI-compatible Chat Completions API
/// (OpenAI, xAI, Gemini, OpenRouter, DeepSeek, Mistral, Groq, Ollama, LM Studio).
/// </summary>
public sealed record Provider(
    string Id,
    string Title,
    string BaseUrl,
    string KeyHint,
    bool NeedsKey = true,
    bool Local = false,
    bool MaxCompletionTokens = false,
    bool Reasoning = false);

public static class Providers
{
    public static readonly Provider[] All =
    {
        new("openai", "ChatGPT — OpenAI API (ключ)", "https://api.openai.com/v1",
            "Ключ: platform.openai.com → API keys. Оплата по факту, отдельно от подписки ChatGPT Plus.",
            MaxCompletionTokens: true, Reasoning: true),
        new("xai", "Grok — xAI API (ключ)", "https://api.x.ai/v1",
            "Ключ: console.x.ai → API Keys. Оплата по факту, отдельно от подписки X Premium.",
            Reasoning: true),
        new("gemini", "Gemini — Google AI Studio (ключ)", "https://generativelanguage.googleapis.com/v1beta/openai",
            "Ключ: aistudio.google.com → Get API key. Есть бесплатный лимит.",
            Reasoning: true),
        new("openrouter", "OpenRouter — сотни моделей по одному ключу", "https://openrouter.ai/api/v1",
            "Ключ: openrouter.ai → Keys. Один ключ открывает модели OpenAI, Google, xAI, Meta, DeepSeek, Mistral и других.",
            Reasoning: true),
        new("deepseek", "DeepSeek (ключ)", "https://api.deepseek.com/v1",
            "Ключ: platform.deepseek.com → API keys."),
        new("mistral", "Mistral (ключ)", "https://api.mistral.ai/v1",
            "Ключ: console.mistral.ai → API Keys."),
        new("groq", "Groq — очень быстрые открытые модели (ключ)", "https://api.groq.com/openai/v1",
            "Ключ: console.groq.com → API Keys. Есть бесплатный лимит.",
            Reasoning: true),
        new("ollama", "Ollama — локальная модель на этом компьютере", "http://localhost:11434/v1",
            "Ключ не нужен, вопросы не покидают компьютер. Установите Ollama и скачайте модель: ollama pull <модель>.",
            NeedsKey: false, Local: true),
        new("lmstudio", "LM Studio — локальная модель на этом компьютере", "http://localhost:1234/v1",
            "Ключ не нужен, вопросы не покидают компьютер. В LM Studio загрузите модель и запустите локальный сервер.",
            NeedsKey: false, Local: true),
    };

    public static Provider? Find(string id) => All.FirstOrDefault(p => p.Id == id);
}

/// <summary>OpenAI-compatible Chat Completions: raw HTTP + SSE streaming.</summary>
public sealed class OpenAICompatClient : ILLMClient
{
    static readonly HttpClient Http = new(new SocketsHttpHandler { PooledConnectionIdleTimeout = TimeSpan.FromMinutes(10) })
    {
        Timeout = Timeout.InfiniteTimeSpan,
    };

    readonly Provider _p;
    readonly string _key, _baseUrl;

    public OpenAICompatClient(Provider provider, string key, string baseUrl)
    {
        _p = provider;
        _key = key.Trim();
        _baseUrl = (string.IsNullOrWhiteSpace(baseUrl) ? provider.BaseUrl : baseUrl.Trim()).TrimEnd('/');
    }

    HttpRequestMessage Build(HttpMethod method, string path, JsonObject? body)
    {
        if (_p.NeedsKey && _key.Length == 0)
            throw new LLMException($"Не задан API-ключ ({_p.Title.Split(" — ")[0]}): вкладка «Настройки» → 1. Подключение модели.");
        var req = new HttpRequestMessage(method, _baseUrl + path);
        if (_key.Length > 0) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _key);
        if (_p.Id == "openrouter") req.Headers.Add("X-Title", "RedCast");
        if (body != null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        return req;
    }

    static JsonNode UserContent(LLMRequest r)
    {
        if (r.ImageJpeg == null) return JsonValue.Create(r.Text)!;
        return new JsonArray
        {
            new JsonObject { ["type"] = "text", ["text"] = r.Text },
            new JsonObject
            {
                ["type"] = "image_url",
                ["image_url"] = new JsonObject { ["url"] = "data:image/jpeg;base64," + Convert.ToBase64String(r.ImageJpeg) },
            },
        };
    }

    JsonObject Body(LLMRequest r, bool reasoning)
    {
        var body = new JsonObject
        {
            ["model"] = r.Model,
            ["stream"] = true,
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = r.System },
                new JsonObject { ["role"] = "user", ["content"] = UserContent(r) },
            },
        };
        body[_p.MaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = 8000;
        if (reasoning) body["reasoning_effort"] = r.Effort;
        return body;
    }

    /// <summary>Opens the TLS connection before the first question (GET /models costs no tokens).</summary>
    public async Task PrewarmAsync()
    {
        if (_p.NeedsKey && _key.Length == 0) return;
        try
        {
            using var req = Build(HttpMethod.Get, "/models", null);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            using var _ = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        }
        catch { }
    }

    public async Task StreamAsync(LLMRequest r, Action<string> onText, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(r.Model))
            throw new LLMException("Не выбрана модель: «Настройки» → 1. Подключение модели → «Список моделей».");
        try
        {
            await StreamOnceAsync(r, _p.Reasoning, onText, ct);
        }
        catch (LLMException e) when (_p.Reasoning && e.Status == 400 && e.Message.Contains("reasoning", StringComparison.OrdinalIgnoreCase))
        {
            await StreamOnceAsync(r, false, onText, ct);   // this model has no reasoning_effort → plain request
        }
    }

    async Task StreamOnceAsync(LLMRequest r, bool reasoning, Action<string> onText, CancellationToken ct)
    {
        using var req = Build(HttpMethod.Post, "/chat/completions", Body(r, reasoning));
        HttpResponseMessage resp;
        try
        {
            resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (HttpRequestException e) when (_p.Local)
        {
            throw new LLMException($"Нет связи с {_baseUrl}: запущен ли {_p.Title.Split(" — ")[0]}? ({e.Message})");
        }
        using (resp)
        {
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
                var payload = line.Substring(5).Trim();
                if (payload == "[DONE]") break;
                JsonNode? obj;
                try { obj = JsonNode.Parse(payload); } catch { continue; }
                if (obj?["error"] is JsonNode e)
                    throw new LLMException("Ошибка API: " + (e["message"]?.ToString() ?? e.ToJsonString()));
                var choice = obj?["choices"]?[0];
                if (choice == null) continue;
                if (choice["delta"]?["content"] is JsonValue v && v.TryGetValue(out string? text) && text.Length > 0)
                    onText(text);
                if (choice["finish_reason"]?.ToString() == "content_filter")
                    throw new LLMException("Модель отказалась отвечать на этот запрос.");
            }
        }
    }

    // Embeddings, speech, images and moderation are useless for answers.
    static readonly string[] NotChat =
    {
        "embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "audio", "realtime",
        "image", "imagen", "veo", "rerank", "guard", "aqa", "speech",
    };

    /// <summary>Chat models the key can use (GET /models), sorted by id.</summary>
    public async Task<List<string>> ListModelsAsync(CancellationToken ct = default)
    {
        using var req = Build(HttpMethod.Get, "/models", null);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        HttpResponseMessage resp;
        try
        {
            resp = await Http.SendAsync(req, cts.Token);
        }
        catch (HttpRequestException e)
        {
            throw new LLMException(_p.Local ? $"Нет связи с {_baseUrl}: запущен ли {_p.Title.Split(" — ")[0]}?" : "Нет связи: " + e.Message);
        }
        using (resp)
        {
            var text = await resp.Content.ReadAsStringAsync(cts.Token);
            if (!resp.IsSuccessStatusCode)
                throw new LLMException($"Ошибка API {(int)resp.StatusCode}: {ErrorMessage(text)}", (int)resp.StatusCode);
            var data = JsonNode.Parse(text)?["data"] as JsonArray ?? new JsonArray();
            return data
                .Select(m => m?["id"]?.ToString() ?? "")
                .Select(id => id.StartsWith("models/") ? id["models/".Length..] : id)
                .Where(id => id.Length > 0 && !NotChat.Any(x => id.Contains(x, StringComparison.OrdinalIgnoreCase)))
                .Distinct()
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }

    static string ErrorMessage(string body)
    {
        try
        {
            var node = JsonNode.Parse(body);
            if (node is JsonArray arr) node = arr.FirstOrDefault();   // Gemini wraps errors in an array
            var msg = node?["error"]?["message"]?.ToString() ?? node?["message"]?.ToString();
            if (!string.IsNullOrWhiteSpace(msg)) return msg;
        }
        catch { }
        return body.Length > 300 ? body[..300] + "…" : body;
    }
}
