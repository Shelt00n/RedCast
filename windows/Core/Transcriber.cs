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

/// <summary>Recognised text and the language it was recognised in.</summary>
public sealed record Recognized(string Text, string? Language);

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
                if (useGpu) VulkanGpu.PreferDiscrete();   // before the first native load: otherwise the integrated GPU is used
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
                Device = useGpu && lib.Contains("Vulkan", StringComparison.OrdinalIgnoreCase)
                    ? (VulkanGpu.Chosen is string gpu ? $"видеокарта {gpu} (Vulkan)" : "видеокарта (Vulkan)")
                    : "процессор";
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

    /// <summary>Last language detected in «auto» mode: used when detection picks something odd.</summary>
    string _lastLanguage = "ru";
    static readonly HashSet<string> AllowedLanguages = new() { "ru", "uk", "en" };
    CancellationTokenSource? _partialCts;

    /// <summary>
    /// Final recognition. urgent (interviewer / button) jumps ahead of my microphone.
    /// language null = «auto»: only ru / uk / en, anything else is recognised again in the last good language.
    /// prompt = terms + the previous piece (only with «точное написание терминов»).
    /// </summary>
    public async Task<Recognized> RecognizeAsync(float[] samples, string? language, string prompt, bool urgent)
    {
        // A final result stops a live caption that is being decoded right now.
        try { _partialCts?.Cancel(); } catch { }
        if (urgent) Interlocked.Increment(ref _urgentWaiting);
        else
            while (Volatile.Read(ref _urgentWaiting) > 0) await Task.Delay(20);
        await _gate.WaitAsync();
        if (urgent) Interlocked.Decrement(ref _urgentWaiting);
        try
        {
            var audio = Normalized(samples);
            var first = await RunAsync(audio, language, prompt, fallback: true, CancellationToken.None);
            if (language != null) return new Recognized(first.Text, language);
            if (first.Language != null && AllowedLanguages.Contains(first.Language))
            {
                _lastLanguage = first.Language;
                return first;
            }
            var again = await RunAsync(audio, _lastLanguage, prompt, fallback: true, CancellationToken.None);
            return new Recognized(again.Text.Length > 0 ? again.Text : first.Text, _lastLanguage);
        }
        finally { _gate.Release(); }
    }

    public async Task<string> TranscribeAsync(float[] samples, string? language, string prompt, bool urgent)
        => (await RecognizeAsync(samples, language, prompt, urgent)).Text;

    /// <summary>Live caption: skipped if busy, and cancelled as soon as a final result needs the model.</summary>
    public async Task<string?> TranscribePartialAsync(float[] samples, string? language, string prompt)
    {
        if (Volatile.Read(ref _urgentWaiting) > 0 || !_gate.Wait(0)) return null;
        var cts = new CancellationTokenSource();
        _partialCts = cts;
        try
        {
            var r = await RunAsync(Normalized(samples), language ?? _lastLanguage, prompt, fallback: false, cts.Token);
            return cts.IsCancellationRequested ? null : r.Text;
        }
        catch (OperationCanceledException) { return null; }
        finally
        {
            _partialCts = null;
            cts.Dispose();
            _gate.Release();
        }
    }

    async Task<Recognized> RunAsync(float[] samples, string? language, string prompt, bool fallback, CancellationToken ct)
    {
        var factory = _factory;
        if (factory == null || samples.Length == 0) return new Recognized("", language);
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
        if (!fallback) b = b.WithTemperatureInc(0f);   // captions: one pass, never a slow retry
        b = language == null ? b.WithLanguageDetection() : b.WithLanguage(language);
        if (!string.IsNullOrWhiteSpace(prompt)) b = b.WithPrompt(prompt.Trim());
        if (!_gpu)
        {
            // CPU speed-up: whisper always encodes 30 s; shrink the window for short phrases.
            // Not on the GPU: there it saves only ~0.2 s and, with some prompts, makes Whisper repeat the phrase twice.
            double seconds = samples.Length / 16000.0;
            int ctx = (int)Math.Clamp(seconds * 50 + 160, 512, 1500);
            b = b.WithAudioContextSize(ctx);
        }

        using var proc = b.Build();
        var sb = new StringBuilder();
        string? detected = language;
        try
        {
            await foreach (var seg in proc.ProcessAsync(samples, ct))
            {
                if (!string.IsNullOrEmpty(seg.Language)) detected ??= seg.Language;
                var t = Clean(seg.Text);
                if (t.Length == 0 || IsHallucination(t)) continue;
                if (sb.Length > 0) sb.Append(' ');
                sb.Append(t);
            }
        }
        catch (OperationCanceledException) { throw; }
        catch { return new Recognized("", language); }
        return new Recognized(CollapseRepeats(sb.ToString().Trim()), detected);
    }

    /// <summary>Quiet calls (a soft-spoken interviewer, a far microphone) are brought up to a normal level.</summary>
    static float[] Normalized(float[] samples)
    {
        float peak = 0;
        foreach (var s in samples) peak = Math.Max(peak, Math.Abs(s));
        if (peak <= 0.003f || peak >= 0.5f) return samples;
        float gain = Math.Min(0.8f / peak, 8f);
        var o = new float[samples.Length];
        for (int i = 0; i < samples.Length; i++) o[i] = samples[i] * gain;
        return o;
    }

    /// <summary>«и так далее, и так далее, и так далее…» → once. Whisper loops on unclear audio.</summary>
    public static string CollapseRepeats(string text)
    {
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count < 6) return text;
        int n = 1;
        while (n <= words.Count / 3)
        {
            bool changed = false;
            int i = 0;
            while (i + 3 * n <= words.Count)
            {
                bool Same(int a, int b2)
                {
                    for (int k = 0; k < n; k++)
                        if (!string.Equals(words[a + k], words[b2 + k], StringComparison.OrdinalIgnoreCase)) return false;
                    return true;
                }
                if (Same(i, i + n) && Same(i + n, i + 2 * n))
                {
                    int j = i + n;
                    while (j + n <= words.Count && Same(i, j)) j += n;
                    words.RemoveRange(i + n, j - (i + n));
                    changed = true;
                }
                else i++;
            }
            if (!changed) n++;
        }
        return string.Join(" ", words);
    }

    static string Clean(string s) => Regex.Replace(s ?? "", @"\[[^\]]*\]|\([^)]*\)|<\|[^|]*\|>", "").Trim();

    static readonly string[] Phantom =
    {
        "субтитр", "dimatorzok", "продолжение следует", "спасибо за просмотр", "подписывайтесь", "ставьте лайк",
        "дякую за перегляд", "підписуйтесь", "редактор субтитров", "корректор а.", "amara.org", "thanks for watching",
        "смотрите в следующ", "до новых встреч", "музыкальная заставка", "♪", "субтитри", "редактор субтитрів",
    };

    /// <summary>Whole utterances Whisper invents on silence, breathing or clicks.</summary>
    static readonly HashSet<string> PhantomExact = new()
    {
        "you", "thank you", "thanks", "bye", "okay", "ok", "so", "uh", "um", "hmm", "mm",
        "thank you for watching", "спасибо за внимание", "дякую", "аплодисменты", "смех", "музыка", "дякую за увагу",
    };

    static bool IsHallucination(string text)
    {
        var t = text.ToLowerInvariant();
        var core = t.Trim().Trim('.', ',', '!', '?', '…', ' ');
        if (core.Length == 0 || PhantomExact.Contains(core)) return true;
        if (Phantom.Any(t.Contains)) return true;
        return t.All(c => char.IsPunctuation(c) || char.IsWhiteSpace(c));
    }

    public void Dispose() => _factory?.Dispose();
}
