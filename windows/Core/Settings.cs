using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace RedCast.Core;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnChanged(name);
        return true;
    }

    protected void OnChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public record Option(string Id, string Title)
{
    public override string ToString() => Title;
}

public static class Catalog
{
    public static readonly Option[] Backends =
    {
        new("api", "Anthropic API — ключ (самый быстрый)"),
        new("claudecode", "Подписка Claude Pro/Max — через Claude Code"),
    };

    public static readonly Option[] Models =
    {
        new("claude-opus-5-5", "Claude Opus 5.5 — самый умный (по умолчанию)"),
        new("claude-sonnet-5-5", "Claude Sonnet 5.5 — быстрее"),
        new("claude-haiku-5-5", "Claude Haiku 5.5 — максимально быстрый"),
    };

    public static readonly Option[] Efforts =
    {
        new("low", "low — быстрый ответ (рекомендуется)"),
        new("medium", "medium — глубже, медленнее"),
        new("high", "high — для сложных задач"),
    };

    public static readonly Option[] SpeechLanguages =
    {
        new("ru", "Русский"),
        new("uk", "Українська"),
        new("auto", "Автоопределение (ru / uk / en)"),
    };

    public static readonly Option[] AnswerLanguages =
    {
        new("same", "На языке вопроса"),
        new("ru", "Русский"),
        new("uk", "Українська"),
        new("en", "English"),
    };

    public static readonly Option[] WhisperModels =
    {
        new("large-v3-turbo-q5_0", "Whisper Large v3 Turbo (сжатая, 0.6 ГБ) — рекомендуется"),
        new("large-v3-turbo", "Whisper Large v3 Turbo (полная, 1.6 ГБ) — максимум точности, нужна видеокарта"),
        new("small", "Whisper Small (0.5 ГБ) — для слабых ПК, точность ниже"),
    };
}

public sealed class AppSettings : Observable
{
    public static AppSettings Shared { get; } = Load();

    static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RedCast");
    static string FilePath => Path.Combine(Dir, "settings.json");

    readonly DispatcherTimer _saveTimer;

    public AppSettings()
    {
        _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); Save(); };
        PropertyChanged += (_, _) => { _saveTimer.Stop(); _saveTimer.Start(); };
    }

    // Claude
    string _backend = "api";
    public string Backend { get => _backend; set => Set(ref _backend, value); }

    string _apiKeyProtected = "";
    public string ApiKeyProtected { get => _apiKeyProtected; set => Set(ref _apiKeyProtected, value); }

    [JsonIgnore]
    public string ApiKey
    {
        get => Unprotect(ApiKeyProtected);
        set { ApiKeyProtected = Protect(value.Trim()); OnChanged(); }
    }

    string _model = "claude-opus-5-5";
    public string Model { get => _model; set => Set(ref _model, value); }

    string _effort = "low";
    public string Effort { get => _effort; set => Set(ref _effort, value); }

    bool _fastMode;
    public bool FastMode { get => _fastMode; set => Set(ref _fastMode, value); }

    string _claudePath = "";
    public string ClaudePath { get => _claudePath; set => Set(ref _claudePath, value); }

    // Speech
    string _speechLanguage = "ru";
    public string SpeechLanguage { get => _speechLanguage; set => Set(ref _speechLanguage, value); }

    string _whisperModel = "large-v3-turbo-q5_0";
    public string WhisperModel { get => _whisperModel; set => Set(ref _whisperModel, value); }

    bool _useGpu = true;
    public bool UseGpu { get => _useGpu; set => Set(ref _useGpu, value); }

    string _vocabulary = "Собеседование. Kubernetes, Docker, PostgreSQL, Kafka, Redis, React, TypeScript, Python, Java, Go, C#, .NET, REST, gRPC, CI/CD, microservices, SOLID, Big O.";
    public string Vocabulary { get => _vocabulary; set => Set(ref _vocabulary, value); }

    double _silenceMs = 700;
    public double SilenceMs { get => _silenceMs; set => Set(ref _silenceMs, value); }

    bool _captureMic = true;
    public bool CaptureMic { get => _captureMic; set => Set(ref _captureMic, value); }

    string _micDeviceId = "";
    /// <summary>WASAPI endpoint id of the chosen microphone; "" = Windows default.</summary>
    public string MicDeviceId { get => _micDeviceId; set => Set(ref _micDeviceId, value); }

    bool _autoAnswer = true;
    public bool AutoAnswer { get => _autoAnswer; set => Set(ref _autoAnswer, value); }

    string _listenMode = "auto";
    public string ListenMode { get => _listenMode; set { if (Set(ref _listenMode, value)) OnChanged(nameof(IsManual)); } }

    [JsonIgnore]
    public bool IsManual => ListenMode == "manual";

    // Profile
    string _answerLanguage = "same";
    public string AnswerLanguage { get => _answerLanguage; set => Set(ref _answerLanguage, value); }

    string _resume = "";
    public string Resume { get => _resume; set => Set(ref _resume, value); }

    string _jobDescription = "";
    public string JobDescription { get => _jobDescription; set => Set(ref _jobDescription, value); }

    string _extraInstructions = "";
    public string ExtraInstructions { get => _extraInstructions; set => Set(ref _extraInstructions, value); }

    // Window
    double _opacity = 0.95;
    public double Opacity { get => _opacity; set => Set(ref _opacity, value); }

    double _fontSize = 15;
    public double FontSize { get => _fontSize; set => Set(ref _fontSize, value); }

    bool _hideFromCapture = true;
    public bool HideFromCapture { get => _hideFromCapture; set => Set(ref _hideFromCapture, value); }

    double _left = double.NaN, _top = double.NaN, _width = 560, _height = 720;
    public double WindowLeft { get => _left; set => Set(ref _left, value); }
    public double WindowTop { get => _top; set => Set(ref _top, value); }
    public double WindowWidth { get => _width; set => Set(ref _width, value); }
    public double WindowHeight { get => _height; set => Set(ref _height, value); }

    // Hotkeys: action id → "mods|vk|label" ("" = disabled). Missing = default.
    public Dictionary<string, string> HotKeys { get; set; } = new();

    public void TouchHotKeys() => OnChanged(nameof(HotKeys));

    // MARK: persistence

    static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions);
                if (s != null) return s;
            }
        }
        catch { /* broken file → defaults */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
        }
        catch { }
    }

    static string Protect(string plain)
    {
        if (string.IsNullOrEmpty(plain)) return "";
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(bytes);
    }

    static string Unprotect(string b64)
    {
        if (string.IsNullOrEmpty(b64)) return "";
        try
        {
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(b64), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch { return ""; }
    }

    public string AnswerLanguageInstruction => AnswerLanguage switch
    {
        "ru" => "Всегда отвечай на русском языке.",
        "uk" => "Завжди відповідай українською мовою.",
        "en" => "Always answer in English.",
        _ => "Отвечай на том же языке, на котором задан вопрос (русский → русский, украинский → украинский, английский → английский).",
    };

    public string? WhisperLanguage => SpeechLanguage == "auto" ? null : SpeechLanguage;
}
