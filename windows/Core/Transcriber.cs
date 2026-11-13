using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace RedCast.Core;

/// <summary>Local speech recognition (whisper.cpp via Whisper.net). Vulkan GPU if available, else CPU.</summary>
public sealed class Transcriber : IDisposable
{
    WhisperFactory? _factory;
    string _loaded = "";
    bool _gpu;
    readonly SemaphoreSlim _gate = new(1, 1);
    readonly SemaphoreSlim _loadGate = new(1, 1);
    int _urgentWaiting;

    public bool IsReady => _factory != null;
    public string Device { get; private set; } = "";

    public static string ModelsDir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RedCast", "Models");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static string ModelPath(string model) => Path.Combine(ModelsDir, $"ggml-{model}.bin");
    public static bool IsDownloaded(string model) => File.Exists(ModelPath(model));

    static string ModelUrl(string model) => $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{model}.bin";

    public async Task LoadAsync(string model, bool useGpu, IProgress<double> progress, CancellationToken ct = default)
    {
        await _loadGate.WaitAsync(ct);
        try
        {
            if (_factory != null && _loaded == model && _gpu == useGpu) return;
            var path = ModelPath(model);
            if (!File.Exists(path)) await DownloadAsync(model, path, progress, ct);
            progress.Report(1);

            await _gate.WaitAsync(ct);
            try
            {
                _factory?.Dispose();
                _factory = null;
                RuntimeOptions.RuntimeLibraryOrder = useGpu
                    ? new List<RuntimeLibrary> { RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx }
                    : new List<RuntimeLibrary> { RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx };
                try
                {
                    _factory = await Task.Run(() => WhisperFactory.FromPath(path, new WhisperFactoryOptions { UseGpu = useGpu }), ct);
                }
                catch when (useGpu)
                {
                    // GPU driver problem → run on the CPU.
                    useGpu = false;
                    _factory = await Task.Run(() => WhisperFactory.FromPath(path, new WhisperFactoryOptions { UseGpu = false }), ct);
                }
                _loaded = model;
                _gpu = useGpu;
                var lib = RuntimeOptions.LoadedLibrary?.ToString() ?? "";
                Device = useGpu && lib.Contains("Vulkan", StringComparison.OrdinalIgnoreCase) ? "видеокарта (Vulkan)" : "процессор";
            }
            finally { _gate.Release(); }

            // Warm-up so the first real question is fast.
            await TranscribeAsync(new float[16000], "ru", "", urgent: true);
        }
        finally { _loadGate.Release(); }
    }

    static async Task DownloadAsync(string model, string path, IProgress<double> progress, CancellationToken ct)
    {
        var tmp = path + ".part";
        using var http = new HttpClient { Timeout = TimeSpan.FromHours(2) };
        using var resp = await http.GetAsync(ModelUrl(model), HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        long total = resp.Content.Headers.ContentLength ?? -1;
        await using (var src = await resp.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(tmp))
        {
            var buf = new byte[1 << 20];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                if (total > 0) progress.Report(Math.Min(0.999, (double)done / total));
            }
        }
        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>Final transcription. urgent (interviewer / button) jumps ahead of my microphone.</summary>
    public async Task<string> TranscribeAsync(float[] samples, string? language, string vocabulary, bool urgent)
    {
        if (urgent) Interlocked.Increment(ref _urgentWaiting);
        else
            while (Volatile.Read(ref _urgentWaiting) > 0) await Task.Delay(20);
        await _gate.WaitAsync();
        if (urgent) Interlocked.Decrement(ref _urgentWaiting);
        try { return await RunAsync(samples, language, vocabulary); }
        finally { _gate.Release(); }
    }

    /// <summary>Live caption: skipped if busy, so it never delays a final result.</summary>
    public async Task<string?> TranscribePartialAsync(float[] samples, string? language, string vocabulary)
    {
        if (Volatile.Read(ref _urgentWaiting) > 0 || !_gate.Wait(0)) return null;
        try { return await RunAsync(samples, language, vocabulary); }
        finally { _gate.Release(); }
    }

    async Task<string> RunAsync(float[] samples, string? language, string vocabulary)
    {
        var factory = _factory;
        if (factory == null || samples.Length == 0) return "";
        if (samples.Length < 16000)
        {
            var padded = new float[16000];
            Array.Copy(samples, padded, samples.Length);
            samples = padded;
        }

        var b = factory.CreateBuilder()
            .WithThreads(Math.Max(2, Math.Min(8, Environment.ProcessorCount - 1)))
            .WithTemperature(0f)
            .WithNoSpeechThreshold(0.6f)
            .WithNoContext();
        b = language == null ? b.WithLanguageDetection() : b.WithLanguage(language);
        if (!string.IsNullOrWhiteSpace(vocabulary)) b = b.WithPrompt(vocabulary.Trim());
        if (!_gpu)
        {
            // CPU speed-up: whisper always encodes 30 s; shrink the window for short phrases.
            double seconds = samples.Length / 16000.0;
            int ctx = (int)Math.Clamp(seconds * 50 + 160, 512, 1500);
            b = b.WithAudioContextSize(ctx);
        }

        using var proc = b.Build();
        var sb = new StringBuilder();
        try
        {
            await foreach (var seg in proc.ProcessAsync(samples))
            {
                var t = Clean(seg.Text);
                if (t.Length == 0 || IsHallucination(t)) continue;
                if (sb.Length > 0) sb.Append(' ');
                sb.Append(t);
            }
        }
        catch { return ""; }
        return sb.ToString().Trim();
    }

    static string Clean(string s) => Regex.Replace(s ?? "", @"\[[^\]]*\]|\([^)]*\)|<\|[^|]*\|>", "").Trim();

    static readonly string[] Phantom =
    {
        "субтитр", "dimatorzok", "продолжение следует", "спасибо за просмотр", "подписывайтесь", "ставьте лайк",
        "дякую за перегляд", "підписуйтесь", "редактор субтитров", "корректор а.", "amara.org", "thanks for watching",
        "смотрите в следующ", "до новых встреч", "музыкальная заставка", "♪",
    };

    /// <summary>Whole utterances Whisper invents on silence, breathing or clicks.</summary>
    static readonly HashSet<string> PhantomExact = new()
    {
        "you", "thank you", "thanks", "bye", "okay", "ok", "so", "uh", "um", "hmm", "mm",
        "thank you for watching", "спасибо за внимание", "дякую", "аплодисменты", "смех", "музыка",
    };

    static bool IsHallucination(string text)
    {
        var t = text.ToLowerInvariant();
        var core = t.Trim().Trim('.', ',', '!', '?', '…', ' ');
        if (PhantomExact.Contains(core)) return true;
        if (Phantom.Any(t.Contains)) return true;
        return t.All(c => char.IsPunctuation(c) || char.IsWhiteSpace(c));
    }

    public void Dispose() => _factory?.Dispose();
}
