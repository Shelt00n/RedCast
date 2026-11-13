using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace RedCast.Core;

public enum Speaker { Interviewer, Me }

public sealed class TranscriptEntry
{
    public TranscriptEntry(Speaker speaker, string text) { Speaker = speaker; Text = text; Date = DateTime.Now; }
    public Speaker Speaker { get; }
    public string Text { get; }
    public DateTime Date { get; }
    public string Label => Speaker == Speaker.Interviewer ? "Интервьюер: " : "Я: ";
    public bool IsInterviewer => Speaker == Speaker.Interviewer;
}

public sealed class AnswerItem : Observable
{
    public AnswerItem(string question) { Question = question; }
    public Guid Id { get; } = Guid.NewGuid();
    public DateTime Started { get; } = DateTime.Now;
    public string Question { get; }

    string _text = "";
    public string Text { get => _text; set { if (Set(ref _text, value)) OnChanged(nameof(ShowSpinner)); } }

    bool _streaming = true;
    public bool IsStreaming { get => _streaming; set { if (Set(ref _streaming, value)) OnChanged(nameof(ShowSpinner)); } }

    string? _error;
    public string? Error { get => _error; set { if (Set(ref _error, value)) OnChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrEmpty(Error);

    string _latency = "";
    public string Latency { get => _latency; set => Set(ref _latency, value); }

    public bool ShowSpinner => IsStreaming && Text.Length == 0;
}

/// <summary>The whole session logic (view model of the main window).</summary>
public sealed class AppState : Observable
{
    public static AppState Shared { get; } = new();

    public AppSettings Settings => AppSettings.Shared;
    public ObservableCollection<TranscriptEntry> Entries { get; } = new();
    public ObservableCollection<AnswerItem> Answers { get; } = new();

    readonly Transcriber _transcriber = new();
    readonly AudioSource _system = new(loopback: true);
    readonly AudioSource _mic = new(loopback: false);
    readonly SerialQueue _sysQ = new("redcast-system");
    readonly SerialQueue _micQ = new("redcast-mic");
    readonly SpeechSegmenter _sysSeg = new() { Active = false };
    readonly SpeechSegmenter _micSeg = new() { Active = false };
    readonly ManualRecorder _sysRec = new();
    readonly ManualRecorder _micRec = new();
    readonly AnthropicApiClient _api;
    readonly ClaudeCodeClient _cli;
    readonly Dispatcher _ui;

    CancellationTokenSource? _answerCts;
    Guid? _currentAnswerId;
    string? _currentQuestion;
    DateTime _questionStartedAt = DateTime.MinValue, _lastInterviewerFinalAt = DateTime.MinValue, _lastMeAt = DateTime.MinValue;
    bool _forceAnswerOnNextFinal;
    DispatcherTimer? _keepAlive;
    DateTime _sessionStart = DateTime.Now;

    AppState()
    {
        _ui = Application.Current.Dispatcher;
        _api = new AnthropicApiClient(() => Settings.ApiKey);
        _cli = new ClaudeCodeClient(() => Settings.ClaudePath);

        _system.Samples += s => _sysQ.Post(() => { _sysSeg.Append(s); _sysRec.Append(s); });
        _mic.Samples += s => _micQ.Post(() => { _micSeg.Append(s); _micRec.Append(s); });
        _system.Failed += m => Ui(() => { Stop(); ShowError("Захват звука остановлен: " + m); });
        _mic.Failed += m => Ui(() => ShowError("Микрофон: " + m));

        _sysSeg.OnSpeechStart = () => Ui(() => InterviewerSpeaking = true);
        _sysSeg.OnPartial = a => Ui(() => _ = HandlePartial(Speaker.Interviewer, a));
        _sysSeg.OnFinal = a => Ui(() => _ = HandleFinal(Speaker.Interviewer, a));
        _micSeg.OnFinal = a => Ui(() => _ = HandleFinal(Speaker.Me, a));
        _sysRec.OnPartial = a => Ui(() => _ = HandleManualPartial(Speaker.Interviewer, a));
        _micRec.OnPartial = a => Ui(() => _ = HandleManualPartial(Speaker.Me, a));
    }

    void Ui(Action a) => _ui.BeginInvoke(a);

    // MARK: - Bindable state

    string _status = "Готов";
    public string Status { get => _status; set => Set(ref _status, value); }

    string _modelStatus = "Модель речи не загружена";
    public string ModelStatus { get => _modelStatus; set => Set(ref _modelStatus, value); }

    double _modelProgress;
    public double ModelProgress { get => _modelProgress; set => Set(ref _modelProgress, value); }

    bool _showProgress;
    public bool ShowProgress { get => _showProgress; set => Set(ref _showProgress, value); }

    bool _modelReady;
    public bool ModelReady { get => _modelReady; set => Set(ref _modelReady, value); }

    bool _isListening;
    public bool IsListening { get => _isListening; set { if (Set(ref _isListening, value)) OnChanged(nameof(StartLabel)); } }

    bool _isStarting;
    public bool IsStarting { get => _isStarting; set { if (Set(ref _isStarting, value)) OnChanged(nameof(StartLabel)); } }

    public string StartLabel => IsListening ? "■  Стоп" : IsStarting ? "Запуск…" : "▶  Старт";

    bool _interviewerSpeaking;
    public bool InterviewerSpeaking { get => _interviewerSpeaking; set => Set(ref _interviewerSpeaking, value); }

    bool _recInterviewer, _recMe;
    public bool RecordingInterviewer { get => _recInterviewer; set { if (Set(ref _recInterviewer, value)) OnChanged(nameof(IsRecording)); } }
    public bool RecordingMe { get => _recMe; set { if (Set(ref _recMe, value)) OnChanged(nameof(IsRecording)); } }
    public bool IsRecording => RecordingInterviewer || RecordingMe;

    string _partialInterviewer = "", _partialMe = "";
    public string PartialInterviewer { get => _partialInterviewer; set => Set(ref _partialInterviewer, value); }
    public string PartialMe { get => _partialMe; set => Set(ref _partialMe, value); }

    string? _error;
    public string? ErrorMessage { get => _error; set { if (Set(ref _error, value)) OnChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    public void ShowError(string text) => ErrorMessage = text;

    // MARK: - Updates

    public string CurrentVersion => Updater.CurrentVersion;

    ReleaseInfo? _update;
    public ReleaseInfo? UpdateAvailable
    {
        get => _update;
        set { if (Set(ref _update, value)) { OnChanged(nameof(HasUpdate)); OnChanged(nameof(UpdateButtonText)); } }
    }
    public bool HasUpdate => UpdateAvailable != null;
    public string UpdateButtonText => UpdateAvailable == null ? "" : $"⬇  Обновить до {UpdateAvailable.Version}";

    string _updateStatus = "";
    public string UpdateStatus { get => _updateStatus; set => Set(ref _updateStatus, value); }

    bool _isUpdating;
    public bool IsUpdating { get => _isUpdating; set { if (Set(ref _isUpdating, value)) OnChanged(nameof(NotUpdating)); } }
    public bool NotUpdating => !IsUpdating;

    double _updateProgress;
    public double UpdateProgress { get => _updateProgress; set => Set(ref _updateProgress, value); }

    public async Task CheckForUpdates(bool silent)
    {
        if (!silent) UpdateStatus = "Проверяю…";
        try
        {
            var r = await Task.Run(Updater.LatestAsync);
            if (Updater.IsNewer(r.Version, Updater.CurrentVersion))
            {
                UpdateAvailable = r;
                UpdateStatus = $"Доступна версия {r.Version}";
            }
            else
            {
                UpdateAvailable = null;
                UpdateStatus = $"У вас последняя версия ({Updater.CurrentVersion})";
            }
        }
        catch (Exception ex)
        {
            if (!silent) UpdateStatus = "Не удалось проверить: " + ex.Message;
        }
    }

    public async Task InstallUpdate()
    {
        var r = UpdateAvailable;
        if (r == null || IsUpdating) return;
        if (!Updater.CanWriteAppDir())
        {
            ShowError($"Нет прав на запись в папку {Updater.AppDir}. Переместите папку RedCast, например, в C:\\RedCast или в «Документы» и запустите оттуда.");
            return;
        }
        IsUpdating = true;
        try
        {
            if (IsListening) Stop();
            UpdateStatus = $"Скачиваю версию {r.Version}…";
            var progress = new Progress<double>(f => { UpdateProgress = f * 100; UpdateStatus = $"Скачиваю версию {r.Version}: {(int)(f * 100)}%"; });
            var dir = await Task.Run(() => Updater.DownloadAsync(r, progress));
            UpdateStatus = "Устанавливаю… RedCast перезапустится";
            Updater.Install(dir, Updater.AppDir, Environment.ProcessId, relaunch: true, wait: false);
            ((App)Application.Current).Quit();
        }
        catch (Exception ex)
        {
            UpdateStatus = "Ошибка обновления: " + ex.Message;
            ShowError("Не удалось обновиться: " + ex.Message);
        }
        finally { IsUpdating = false; }
    }

    // MARK: - Speech model

    public async Task LoadSpeechModel()
    {
        var model = Settings.WhisperModel;
        ModelReady = false;
        bool download = !Transcriber.IsDownloaded(model);
        ShowProgress = download;
        ModelProgress = 0;
        ModelStatus = download ? "Скачивание модели речи (один раз)…" : "Загрузка модели речи…";
        var progress = new Progress<double>(f =>
        {
            if (f >= 1) { ShowProgress = false; ModelStatus = "Загрузка модели речи в память…"; }
            else { ModelProgress = f * 100; ModelStatus = $"Скачивание модели речи: {(int)(f * 100)}%"; }
        });
        try
        {
            await Task.Run(() => _transcriber.LoadAsync(model, Settings.UseGpu, progress));
            ModelReady = true;
            ShowProgress = false;
            ModelStatus = "Распознавание готово · " + _transcriber.Device;
        }
        catch (Exception ex)
        {
            ShowProgress = false;
            ModelStatus = "Ошибка модели речи";
            ShowError("Не удалось загрузить модель речи: " + ex.Message +
                      ". Проверьте интернет и нажмите «Перезагрузить модель» в настройках.");
        }
    }

    // MARK: - Captures

    void SetAutoSegmentation(bool on)
    {
        var silence = Settings.SilenceMs;
        _sysQ.Invoke(() => { _sysSeg.Reset(); _sysSeg.SilenceMs = silence; _sysSeg.Active = on; });
        _micQ.Invoke(() => { _micSeg.Reset(); _micSeg.SilenceMs = silence + 200; _micSeg.Active = on; });
    }

    bool EnsureCaptures(bool system, bool mic, bool micRequired)
    {
        if (system && !_system.IsRunning)
        {
            try { _system.Start(); }
            catch (Exception ex) { ShowError("Не удалось захватить звук системы: " + ex.Message); return false; }
        }
        if (mic && !_mic.IsRunning)
        {
            try { _mic.Start(); }
            catch (Exception ex)
            {
                ShowError("Микрофон недоступен: " + ex.Message +
                          ". Проверьте: Параметры Windows → Конфиденциальность → Микрофон → «Разрешить классическим приложениям».");
                if (micRequired) return false;
            }
        }
        return true;
    }

    void SessionStarted()
    {
        if (IsListening) return;
        IsListening = true;
        _sessionStart = DateTime.Now;
        if (Settings.Backend == "api" && string.IsNullOrWhiteSpace(Settings.ApiKey))
            ShowError("Подсказок не будет: не задан API-ключ. Откройте вкладку «Настройки» → Claude.");
        PrewarmLLM();
        _keepAlive?.Stop();
        _keepAlive = new DispatcherTimer { Interval = TimeSpan.FromMinutes(4) };
        _keepAlive.Tick += (_, _) => PrewarmLLM();
        _keepAlive.Start();
    }

    // MARK: - Mode «Авто»

    public void SetMode(string mode)
    {
        if (Settings.ListenMode == mode) return;
        Stop();
        Settings.ListenMode = mode;
        Status = mode == "auto" ? "Готов — нажмите «Старт»" : "Готов — нажмите «Интервьюер» или «Я»";
    }

    public async void ToggleListening()
    {
        if (Settings.IsManual)
        {
            if (IsListening) Stop(); else Status = "Режим «По кнопкам»: нажмите «Интервьюер» или «Я»";
            return;
        }
        if (IsListening) Stop(); else await Start();
    }

    public async Task Start()
    {
        if (IsListening || IsStarting) return;
        IsStarting = true;
        try
        {
            ErrorMessage = null;
            if (!ModelReady)
            {
                Status = "Жду модель речи — прослушивание начнётся автоматически";
                await LoadSpeechModel();
            }
            if (!ModelReady) { Status = "Готов"; return; }
            Status = "Запускаю…";
            SetAutoSegmentation(true);
            if (!EnsureCaptures(true, Settings.CaptureMic, false)) { Status = "Готов"; return; }
            SessionStarted();
            Status = "Слушаю…";
        }
        finally { IsStarting = false; }
    }

    public void Stop()
    {
        bool was = IsListening;
        _system.Stop();
        _mic.Stop();
        _sysQ.Invoke(() => _sysRec.Cancel());
        _micQ.Invoke(() => _micRec.Cancel());
        SetAutoSegmentation(false);
        _keepAlive?.Stop();
        IsListening = false;
        RecordingInterviewer = RecordingMe = false;
        InterviewerSpeaking = false;
        PartialInterviewer = PartialMe = "";
        if (was) { Status = "Пауза"; SaveSession(); }
    }

    async Task HandlePartial(Speaker sp, float[] audio)
    {
        if (sp == Speaker.Interviewer && !InterviewerSpeaking) return;
        var text = await Task.Run(() => _transcriber.TranscribePartialAsync(audio, Settings.WhisperLanguage, Settings.Vocabulary));
        if (!string.IsNullOrEmpty(text) && InterviewerSpeaking) PartialInterviewer = text;
    }

    async Task HandleFinal(Speaker sp, float[] audio)
    {
        if (sp == Speaker.Interviewer) InterviewerSpeaking = false;
        var lang = Settings.WhisperLanguage;
        var vocab = Settings.Vocabulary;
        var text = await Task.Run(() => _transcriber.TranscribeAsync(audio, lang, vocab, sp == Speaker.Interviewer));
        if (sp == Speaker.Interviewer) PartialInterviewer = "";
        if (string.IsNullOrEmpty(text) || !IsListening || Settings.IsManual) return;
        if (sp == Speaker.Me)
        {
            if (IsEcho(text)) return;   // the mic heard the interviewer from the speakers
            _lastMeAt = DateTime.Now;
        }
        Entries.Add(new TranscriptEntry(sp, text));
        TrimEntries();
        if (sp == Speaker.Interviewer) InterviewerSaid(text);
    }

    static HashSet<string> Words(string s) =>
        new(new string(s.ToLowerInvariant().Select(c => char.IsLetter(c) ? c : ' ').ToArray())
            .Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length > 2));

    bool IsEcho(string text)
    {
        var mine = Words(text);
        var recent = string.Join(" ", Entries.Where(e => e.IsInterviewer && (DateTime.Now - e.Date).TotalSeconds < 20).Select(e => e.Text))
                     + " " + PartialInterviewer;
        var theirs = Words(recent);
        if (mine.Count == 0 || theirs.Count == 0) return false;
        return (double)mine.Count(theirs.Contains) / mine.Count >= 0.6;
    }

    void InterviewerSaid(string text)
    {
        var now = DateTime.Now;
        // Same question only if the interviewer paused briefly (< 4 s) and I haven't spoken since.
        bool continuing = _currentQuestion != null
                          && _lastMeAt < _questionStartedAt
                          && (now - _lastInterviewerFinalAt).TotalSeconds < 4
                          && (now - _questionStartedAt).TotalSeconds < 30;
        _lastInterviewerFinalAt = now;
        if (continuing) _currentQuestion += " " + text;
        else { _currentQuestion = text; _questionStartedAt = now; }
        bool force = _forceAnswerOnNextFinal;
        _forceAnswerOnNextFinal = false;
        if ((Settings.AutoAnswer || force) && _currentQuestion != null)
            Ask(_currentQuestion, Prompts.Question(Context(_questionStartedAt), _currentQuestion), null, continuing);
    }

    // MARK: - Mode «По кнопкам»

    public async void ToggleRecord(Speaker sp)
    {
        bool rec = sp == Speaker.Interviewer ? RecordingInterviewer : RecordingMe;
        if (rec) await FinishRecording(sp); else BeginRecording(sp);
    }

    void BeginRecording(Speaker sp)
    {
        if (!Settings.IsManual) { Stop(); Settings.ListenMode = "manual"; }
        ErrorMessage = null;
        SetAutoSegmentation(false);
        if (!EnsureCaptures(sp == Speaker.Interviewer, sp == Speaker.Me, true)) return;
        SessionStarted();
        if (sp == Speaker.Interviewer) { _sysQ.Invoke(() => _sysRec.Start()); RecordingInterviewer = true; }
        else { _micQ.Invoke(() => _micRec.Start()); RecordingMe = true; }
        Status = sp == Speaker.Interviewer
            ? "● Записываю интервьюера — нажмите ещё раз, чтобы получить ответ"
            : "● Записываю вас — нажмите ещё раз, чтобы получить ответ";
        if (!ModelReady) _ = LoadSpeechModel();
    }

    async Task FinishRecording(Speaker sp)
    {
        float[] audio;
        if (sp == Speaker.Interviewer) { audio = _sysQ.Invoke(() => _sysRec.Stop()); RecordingInterviewer = false; PartialInterviewer = ""; }
        else { audio = _micQ.Invoke(() => _micRec.Stop()); RecordingMe = false; PartialMe = ""; }
        Status = "Распознаю…";
        if (!ModelReady) await LoadSpeechModel();
        var lang = Settings.WhisperLanguage;
        var vocab = Settings.Vocabulary;
        var text = await Task.Run(() => _transcriber.TranscribeAsync(audio, lang, vocab, true));
        if (!IsRecording) Status = "Готов — нажмите «Интервьюер» или «Я»";
        if (string.IsNullOrEmpty(text))
        {
            ShowError("Речь не распознана. Проверьте, что звук идёт, и попробуйте ещё раз.");
            return;
        }
        Entries.Add(new TranscriptEntry(sp, text));
        TrimEntries();
        _currentQuestion = text;
        _questionStartedAt = DateTime.Now;
        var ctx = Context(DateTime.Now.AddSeconds(-0.5));
        if (sp == Speaker.Interviewer) Ask("🎧 " + text, Prompts.Question(ctx, text), null, false);
        else Ask("🎤 " + text, Prompts.Mine(ctx, text), null, false);
    }

    async Task HandleManualPartial(Speaker sp, float[] audio)
    {
        bool rec = sp == Speaker.Interviewer ? RecordingInterviewer : RecordingMe;
        if (!rec) return;
        var text = await Task.Run(() => _transcriber.TranscribePartialAsync(audio, Settings.WhisperLanguage, Settings.Vocabulary));
        if (string.IsNullOrEmpty(text)) return;
        if (sp == Speaker.Interviewer && RecordingInterviewer) PartialInterviewer = text;
        if (sp == Speaker.Me && RecordingMe) PartialMe = text;
    }

    // MARK: - Actions

    public void AnswerNow()
    {
        if (Settings.IsManual) { ToggleRecord(Speaker.Interviewer); return; }
        if (InterviewerSpeaking)
        {
            _forceAnswerOnNextFinal = true;
            _sysQ.Post(() => _sysSeg.Flush());
        }
        else
        {
            var q = _currentQuestion ?? Entries.LastOrDefault(e => e.IsInterviewer)?.Text;
            if (q != null) Ask(q, Prompts.Question(Context(_questionStartedAt), q), null, false);
            else ShowError("Пока нечего отвечать: вопрос интервьюера ещё не распознан. Можно ввести вопрос текстом внизу окна.");
        }
    }

    public void AskManual(string text)
    {
        var q = text.Trim();
        if (q.Length == 0) return;
        _currentQuestion = q;
        _questionStartedAt = DateTime.Now;
        Ask(q, Prompts.Question(Context(DateTime.Now), q), null, false);
    }

    public async void SolveScreenshot()
    {
        try
        {
            var jpeg = await Task.Run(ScreenGrabber.CaptureJpeg);
            Ask("📷 Задача с экрана", Prompts.Screenshot(Context(DateTime.Now)), jpeg, false);
        }
        catch (Exception ex) { ShowError("Скриншот не удался: " + ex.Message); }
    }

    public void StopAnswer()
    {
        _answerCts?.Cancel();
        foreach (var a in Answers) a.IsStreaming = false;
    }

    public void Clear()
    {
        StopAnswer();
        Entries.Clear();
        Answers.Clear();
        PartialInterviewer = PartialMe = "";
        _currentQuestion = null;
        _currentAnswerId = null;
    }

    void TrimEntries() { while (Entries.Count > 200) Entries.RemoveAt(0); }

    // MARK: - Claude

    string Context(DateTime before)
    {
        var lines = Entries.Where(e => e.Date < before).TakeLast(24).Select(e => $"[{e.Label.TrimEnd(':', ' ')}] {e.Text}").ToList();
        while (lines.Count > 0 && string.Join("\n", lines).Length > 6000) lines.RemoveAt(0);
        return string.Join("\n", lines);
    }

    LLMRequest MakeRequest(string text, byte[]? image) =>
        new(Prompts.System(Settings), text, image, Settings.Model, Settings.Effort, Settings.FastMode);

    ILLMClient Client => Settings.Backend == "api" ? _api : _cli;

    public void PrewarmLLM()
    {
        var req = MakeRequest("ping", null);
        if (Settings.Backend == "api")
        {
            if (string.IsNullOrWhiteSpace(Settings.ApiKey)) return;
            _ = Task.Run(() => _api.PrewarmAsync(req));
        }
        else _ = Task.Run(() => _cli.Prewarm(req));
    }

    void Ask(string question, string prompt, byte[]? image, bool replaceCurrent)
    {
        _answerCts?.Cancel();
        foreach (var a in Answers) a.IsStreaming = false;

        var item = new AnswerItem(question);
        var idx = replaceCurrent && _currentAnswerId != null ? Answers.ToList().FindIndex(a => a.Id == _currentAnswerId) : -1;
        if (idx >= 0) Answers[idx] = item;
        else
        {
            Answers.Add(item);
            while (Answers.Count > 30) Answers.RemoveAt(0);
        }
        _currentAnswerId = item.Id;

        var cts = new CancellationTokenSource();
        _answerCts = cts;
        var req = MakeRequest(prompt, image);
        var client = Client;
        var sb = new StringBuilder();
        bool first = true;
        _ = Task.Run(async () =>
        {
            try
            {
                await client.StreamAsync(req, chunk =>
                {
                    if (cts.IsCancellationRequested) return;
                    lock (sb) sb.Append(chunk);
                    bool f = first;
                    first = false;
                    Ui(() =>
                    {
                        if (cts.IsCancellationRequested) return;
                        if (f) item.Latency = $"{(DateTime.Now - item.Started).TotalSeconds:0.0} с";
                        string snapshot;
                        lock (sb) snapshot = sb.ToString();
                        item.Text = snapshot;
                    });
                }, cts.Token);
                Ui(() => item.IsStreaming = false);
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                if (cts.IsCancellationRequested) return;
                Ui(() => { item.IsStreaming = false; item.Error = ex.Message; });
            }
        });
    }

    // MARK: - History

    public static string SessionsFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "RedCast Sessions");

    void SaveSession()
    {
        if (Entries.Count == 0 && Answers.Count == 0) return;
        try
        {
            Directory.CreateDirectory(SessionsFolder);
            var sb = new StringBuilder($"# Собеседование {_sessionStart:yyyy-MM-dd HH:mm}\n\n## Расшифровка\n\n");
            foreach (var e in Entries) sb.Append($"- `{e.Date:HH:mm:ss}` **{e.Label.Trim()}** {e.Text}\n");
            sb.Append("\n## Подсказки\n\n");
            foreach (var a in Answers) sb.Append($"### {a.Question}\n\n{a.Text}\n\n");
            File.WriteAllText(Path.Combine(SessionsFolder, $"{_sessionStart:yyyy-MM-dd_HH-mm}.md"), sb.ToString(), Encoding.UTF8);
        }
        catch { }
    }
}
