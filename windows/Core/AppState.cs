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
    public TranscriptEntry(Speaker speaker, string text, double? recognitionSeconds = null)
    {
        Speaker = speaker; Text = text; Date = DateTime.Now; RecognitionSeconds = recognitionSeconds;
    }
    public Speaker Speaker { get; }
    public string Text { get; }
    public DateTime Date { get; }
    /// <summary>From the end of the phrase to ready text, waiting in the queue included.</summary>
    public double? RecognitionSeconds { get; }
    public string RecognitionLabel => RecognitionSeconds is double s ? $"  {s:0.0} с" : "";
    public string Label => Speaker == Speaker.Interviewer ? "Интервьюер  " : "Я  ";
    public bool IsInterviewer => Speaker == Speaker.Interviewer;
}

public sealed class AnswerItem : Observable
{
    public AnswerItem(string question) { Question = question; }
    public Guid Id { get; } = Guid.NewGuid();
    public DateTime Started { get; } = DateTime.Now;
    public string Question { get; }

    string _text = "";
    public string Text { get => _text; set { if (Set(ref _text, value)) { OnChanged(nameof(ShowSpinner)); OnChanged(nameof(Preview)); OnChanged(nameof(CanCopy)); } } }

    bool _streaming = true;
    public bool IsStreaming { get => _streaming; set { if (Set(ref _streaming, value)) { OnChanged(nameof(ShowSpinner)); OnChanged(nameof(CanCopy)); } } }

    string? _error;
    public string? Error { get => _error; set { if (Set(ref _error, value)) OnChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrEmpty(Error);

    /// <summary>Speech recognition time after the question ended (null for typed questions / screenshots).</summary>
    public double? RecognitionSeconds { get; init; }

    double? _firstToken;
    public double? FirstTokenSeconds
    {
        get => _firstToken;
        set { if (Set(ref _firstToken, value)) { OnChanged(nameof(Latency)); OnChanged(nameof(HasLatency)); } }
    }

    /// <summary>«речь 0,6 с · ответ 1,1 с».</summary>
    public string Latency
    {
        get
        {
            var parts = new List<string>();
            if (RecognitionSeconds is double r) parts.Add($"речь {r:0.0} с");
            if (FirstTokenSeconds is double t) parts.Add($"ответ {t:0.0} с");
            return string.Join("  ·  ", parts);
        }
    }
    public bool HasLatency => Latency.Length > 0;

    public bool ShowSpinner => IsStreaming && Text.Length == 0;
    public bool CanCopy => !IsStreaming && Text.Length > 0;

    bool _expanded = true;
    public bool IsExpanded { get => _expanded; set { if (Set(ref _expanded, value)) OnChanged(nameof(Chevron)); } }
    public string Chevron => IsExpanded ? "\uE70D" : "\uE76C";   // Fluent chevron down / right

    // The answer being read right now (marked with the red on-air rule).
    bool _current;
    public bool IsCurrent { get => _current; set => Set(ref _current, value); }

    public string Preview
    {
        get
        {
            var line = Text.Split('\n').FirstOrDefault(l => l.Trim().Length > 0) ?? "";
            return line.Replace("**", "").Replace("`", "").Trim().TrimStart('#', '-', '*', '•', ' ');
        }
    }
}

/// <summary>One phrase being recognised piece by piece, while the person is still talking. UI thread only.</summary>
sealed class Utterance
{
    public Utterance(int id, Speaker speaker) { Id = id; Speaker = speaker; }
    public int Id { get; }
    public Speaker Speaker { get; }
    public List<Task<Recognized>> Pieces { get; } = new();
    /// <summary>Recognised pieces, in order (live caption).</summary>
    public List<string> Done { get; } = new();
    public int Finished;
    /// <summary>Caption of the piece being spoken right now.</summary>
    public string Partial = "";
    public string Caption => string.Join(" ", Done.Append(Partial).Where(t => t.Length > 0));
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
    readonly Dictionary<Speaker, Utterance> _utterances = new();
    readonly DispatcherTimer _recTimer;
    readonly DispatcherTimer _warmDebounce;
    int _manualId = 1_000_000;
    string _lastWarmKey = "";

    CancellationTokenSource? _answerCts;
    Guid? _currentAnswerId;
    string? _currentQuestion;
    DateTime _questionStartedAt = DateTime.MinValue, _lastInterviewerFinalAt = DateTime.MinValue, _lastMeAt = DateTime.MinValue;
    DateTime? _recSinceInterviewer, _recSinceMe;
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
        _system.Level += l => Ui(() => SystemLevel = l * 100);
        _mic.Level += l => Ui(() => MicLevel = l * 100);

        foreach (var (seg, sp) in new[] { (_sysSeg, Speaker.Interviewer), (_micSeg, Speaker.Me) })
        {
            seg.OnSpeechStart = id => Ui(() => SpeechStarted(sp, id));
            seg.OnPartial = (id, a) => Ui(() => _ = HandlePartial(sp, id, a));
            seg.OnPiece = (id, a) => Ui(() => HandlePiece(sp, id, a));
            seg.OnFinal = (id, tail, voice) => Ui(() => _ = HandleFinal(sp, id, tail, voice));
            seg.OnDiscard = id => Ui(() => Discard(sp, id));
        }
        foreach (var (rec, sp) in new[] { (_sysRec, Speaker.Interviewer), (_micRec, Speaker.Me) })
        {
            rec.OnPartial = (id, a) => Ui(() => _ = HandlePartial(sp, id, a));
            rec.OnPiece = (id, a) => Ui(() => HandlePiece(sp, id, a));
        }

        _recTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _recTimer.Tick += (_, _) => UpdateElapsed();

        // A changed resume / model / connection: prepare the model connection again in the background.
        _warmDebounce = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _warmDebounce.Tick += (_, _) => { _warmDebounce.Stop(); if (WarmKey != _lastWarmKey) PrewarmLLM(); };
        Settings.PropertyChanged += (_, _) => { _warmDebounce.Stop(); _warmDebounce.Start(); };
    }

    void Ui(Action a) => _ui.BeginInvoke(a);

    // MARK: - Bindable state

    string _note = "";
    /// <summary>Short transient note in the header ("" = the header shows what RedCast is doing).</summary>
    public string Note { get => _note; set => Set(ref _note, value); }

    string _modelStatus = "Модель речи не загружена";
    public string ModelStatus { get => _modelStatus; set => Set(ref _modelStatus, value); }

    double _modelProgress;
    public double ModelProgress { get => _modelProgress; set => Set(ref _modelProgress, value); }

    bool _showProgress;
    public bool ShowProgress { get => _showProgress; set => Set(ref _showProgress, value); }

    bool _modelReady;
    public bool ModelReady { get => _modelReady; set => Set(ref _modelReady, value); }

    bool _modelFailed;
    public bool ModelFailed { get => _modelFailed; set => Set(ref _modelFailed, value); }

    bool _isListening;
    public bool IsListening { get => _isListening; set => Set(ref _isListening, value); }

    bool _isStarting;
    public bool IsStarting { get => _isStarting; set => Set(ref _isStarting, value); }

    bool _interviewerSpeaking;
    public bool InterviewerSpeaking { get => _interviewerSpeaking; set => Set(ref _interviewerSpeaking, value); }

    bool _recInterviewer, _recMe;
    public bool RecordingInterviewer { get => _recInterviewer; set { if (Set(ref _recInterviewer, value)) OnChanged(nameof(IsRecording)); } }
    public bool RecordingMe { get => _recMe; set { if (Set(ref _recMe, value)) OnChanged(nameof(IsRecording)); } }
    public bool IsRecording => RecordingInterviewer || RecordingMe;

    bool _recognizingInterviewer, _recognizingMe;
    public bool RecognizingInterviewer { get => _recognizingInterviewer; set { if (Set(ref _recognizingInterviewer, value)) OnChanged(nameof(IsRecognizing)); } }
    public bool RecognizingMe { get => _recognizingMe; set { if (Set(ref _recognizingMe, value)) OnChanged(nameof(IsRecognizing)); } }
    public bool IsRecognizing => RecognizingInterviewer || RecognizingMe;

    string _elapsedInterviewer = "", _elapsedMe = "";
    /// <summary>«0:07» while the channel is being recorded.</summary>
    public string ElapsedInterviewer { get => _elapsedInterviewer; set => Set(ref _elapsedInterviewer, value); }
    public string ElapsedMe { get => _elapsedMe; set => Set(ref _elapsedMe, value); }

    string _partialInterviewer = "", _partialMe = "";
    public string PartialInterviewer { get => _partialInterviewer; set => Set(ref _partialInterviewer, value); }
    public string PartialMe { get => _partialMe; set => Set(ref _partialMe, value); }

    string? _error;
    public string? ErrorMessage { get => _error; set { if (Set(ref _error, value)) OnChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    public void ShowError(string text) => ErrorMessage = text;

    double _systemLevel, _micLevel;
    /// <summary>Input levels 0…100 for the meters.</summary>
    public double SystemLevel { get => _systemLevel; set => Set(ref _systemLevel, value); }
    public double MicLevel { get => _micLevel; set => Set(ref _micLevel, value); }

    /// <summary>Problem that blocks answers right now (readiness checklist), null = fine.</summary>
    public string? ConnectionProblem
    {
        get
        {
            var p = Settings.ActiveProvider;
            if (Settings.Backend == "api" && string.IsNullOrWhiteSpace(Settings.ApiKey)) return "Не задан API-ключ Anthropic";
            if (p != null && p.NeedsKey && string.IsNullOrWhiteSpace(Settings.ProviderKey)) return $"Не задан API-ключ {p.Title.Split(" — ")[0]}";
            if (p != null && string.IsNullOrWhiteSpace(Settings.ProviderModel)) return "Не выбрана модель";
            if (Settings.Backend == "claudecode" && !_cli.IsInstalled) return "Claude Code не найден";
            return null;
        }
    }

    /// <summary>What RedCast is doing right now, in plain words (header and strip).</summary>
    public string PhaseTitle
    {
        get
        {
            if (Note.Length > 0) return Note;
            if (RecordingInterviewer) return "Запись: интервьюер";
            if (RecordingMe) return "Запись: вы";
            if (IsRecognizing) return "Распознаю…";
            var a = Answers.LastOrDefault();
            if (a != null && a.IsStreaming && a.Id == _currentAnswerId) return a.Text.Length == 0 ? "Думаю…" : "Отвечаю…";
            if (IsStarting) return "Запуск…";
            if (IsListening) return InterviewerSpeaking ? "Интервьюер говорит…" : "Слушаю";
            if (ShowProgress) return "Скачиваю модель речи";
            if (!ModelReady && !ModelFailed) return "Загружаю распознавание…";
            return "Готов";
        }
    }

    public bool OnAir => IsListening || IsRecording;

    // MARK: - Microphone choice

    public ObservableCollection<Option> MicDevices { get; } = new();

    bool _micTesting;
    public bool MicTesting { get => _micTesting; set { if (Set(ref _micTesting, value)) OnChanged(nameof(MicTestLabel)); } }
    public string MicTestLabel => MicTesting ? "Остановить" : "Проверить";

    public void RefreshMicDevices()
    {
        var selected = Settings.MicDeviceId;
        MicDevices.Clear();
        var def = AudioSource.DefaultMicrophoneName();
        MicDevices.Add(new Option("", "Микрофон Windows по умолчанию" + (def != null ? $" ({def})" : "")));
        foreach (var (id, name) in AudioSource.Microphones()) MicDevices.Add(new Option(id, name));
        if (selected.Length > 0 && MicDevices.All(o => o.Id != selected))
            MicDevices.Add(new Option(selected, "Отключён: выбранный ранее микрофон"));
        Settings.MicDeviceId = selected;
    }

    /// <summary>Microphone changed in Settings: switch right away if it is in use.</summary>
    public void MicDeviceChanged()
    {
        if (!_mic.IsRunning) return;
        _mic.Stop();
        EnsureCaptures(false, true, false);
    }

    /// <summary>«Проверить»: listen to the microphone and show its level (without transcribing).</summary>
    public void ToggleMicTest()
    {
        if (MicTesting)
        {
            MicTesting = false;
            if (!IsListening && !IsRecording) _mic.Stop();
            return;
        }
        ErrorMessage = null;
        if (EnsureCaptures(false, true, true)) MicTesting = true;
    }

    // MARK: - Updates

    public string CurrentVersion => Updater.CurrentVersion;

    ReleaseInfo? _update;
    public ReleaseInfo? UpdateAvailable
    {
        get => _update;
        set { if (Set(ref _update, value)) { OnChanged(nameof(HasUpdate)); OnChanged(nameof(UpdateButtonText)); } }
    }
    public bool HasUpdate => UpdateAvailable != null;
    public string UpdateButtonText => UpdateAvailable == null ? "" : $"Обновить до {UpdateAvailable.Version}";

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
        ModelFailed = false;
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
            ModelFailed = true;
            ModelStatus = "Ошибка модели речи";
            ShowError("Не удалось загрузить модель речи: " + ex.Message +
                      ". Проверьте интернет и нажмите «Перезагрузить модель» в настройках → «Речь».");
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
            _mic.DeviceId = Settings.MicDeviceId;
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
        if (ConnectionProblem is string problem)
            ShowError($"Подсказок не будет: {problem.ToLowerInvariant()}. Откройте настройки (шестерёнка) → «ИИ».");
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
    }

    public async void ToggleListening()
    {
        if (Settings.IsManual)
        {
            if (IsListening) Stop(); else Note = "Режим «По кнопкам»: нажмите «Интервьюер» или «Я»";
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
            Note = "";
            if (!ModelReady)
            {
                Note = "Жду модель речи — прослушивание начнётся само";
                await LoadSpeechModel();
                Note = "";
            }
            if (!ModelReady) return;
            SetAutoSegmentation(true);
            if (!EnsureCaptures(true, Settings.CaptureMic, false)) return;
            SessionStarted();
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
        _recTimer.Stop();
        IsListening = false;
        MicTesting = false;
        RecordingInterviewer = RecordingMe = false;
        _recSinceInterviewer = _recSinceMe = null;
        ElapsedInterviewer = ElapsedMe = "";
        InterviewerSpeaking = false;
        PartialInterviewer = PartialMe = "";
        SystemLevel = MicLevel = 0;
        _utterances.Clear();
        if (was) SaveSession();
    }

    // MARK: - Piece-by-piece recognition (both modes)

    void SetPartial(Speaker sp, string text)
    {
        if (sp == Speaker.Interviewer) PartialInterviewer = text; else PartialMe = text;
    }

    string Prompt(string previous)
    {
        if (!Settings.PreciseTerms) return "";
        var prev = previous.Length > 160 ? previous[^160..] : previous;
        return (Settings.Vocabulary.Trim() + " " + prev).Trim();
    }

    /// <summary>
    /// Recognises one finished piece of a phrase in the background. Pieces are chained: each starts
    /// after the previous one, gets its text as context and (in «auto») stays in its language.
    /// </summary>
    void AddPiece(Utterance u, float[] audio, bool urgent)
    {
        var previous = u.Pieces.LastOrDefault();
        var lang = Settings.WhisperLanguage;
        bool precise = Settings.PreciseTerms;
        var vocab = Settings.Vocabulary;
        var task = Task.Run(async () =>
        {
            Recognized? before = previous != null ? await previous : null;
            var l = lang ?? before?.Language;
            var prev = before?.Text ?? "";
            if (prev.Length > 160) prev = prev[^160..];
            var prompt = precise ? (vocab.Trim() + " " + prev).Trim() : "";
            return await _transcriber.RecognizeAsync(audio, l, prompt, urgent);
        });
        u.Pieces.Add(task);
        u.Partial = "";
        _ = task.ContinueWith(t => Ui(() =>
        {
            u.Finished++;
            if (t.IsCompletedSuccessfully && t.Result.Text.Length > 0) u.Done.Add(t.Result.Text);
            if (_utterances.TryGetValue(u.Speaker, out var cur) && cur == u) SetPartial(u.Speaker, u.Caption);
        }), TaskScheduler.Default);
    }

    /// <summary>The phrase ended: recognise the tail and join all pieces.</summary>
    async Task<(string Text, double Seconds)> Finish(Utterance u, float[] tail, bool hasVoice, bool urgent)
    {
        var started = DateTime.Now;
        if (hasVoice && tail.Length > 0) AddPiece(u, tail, urgent);
        if (_utterances.TryGetValue(u.Speaker, out var cur) && cur == u) _utterances.Remove(u.Speaker);
        var texts = new List<string>();
        foreach (var p in u.Pieces)
        {
            try { texts.Add((await p).Text); } catch { }
        }
        var text = Transcriber.CollapseRepeats(string.Join(" ", texts.Where(t => t.Length > 0)).Trim());
        return (text, (DateTime.Now - started).TotalSeconds);
    }

    void SpeechStarted(Speaker sp, int id)
    {
        if (sp == Speaker.Interviewer) InterviewerSpeaking = true;
        _utterances[sp] = new Utterance(id, sp);
    }

    void HandlePiece(Speaker sp, int id, float[] audio)
    {
        if (!_utterances.TryGetValue(sp, out var u) || u.Id != id) return;
        AddPiece(u, audio, sp == Speaker.Interviewer || Settings.IsManual);
    }

    async Task HandlePartial(Speaker sp, int id, float[] audio)
    {
        if (!_utterances.TryGetValue(sp, out var u) || u.Id != id) return;
        var lang = Settings.WhisperLanguage;
        var prompt = Prompt(u.Done.LastOrDefault() ?? "");
        var text = await Task.Run(() => _transcriber.TranscribePartialAsync(audio, lang, prompt));
        if (string.IsNullOrEmpty(text) || !_utterances.TryGetValue(sp, out var cur) || cur != u || u.Pieces.Count != u.Finished) return;
        u.Partial = text;
        SetPartial(sp, u.Caption);
    }

    void Discard(Speaker sp, int id)
    {
        if (!_utterances.TryGetValue(sp, out var u) || u.Id != id) return;
        _utterances.Remove(sp);
        if (sp == Speaker.Interviewer) InterviewerSpeaking = false;
        SetPartial(sp, "");
    }

    void SetRecognizing(Speaker sp, bool on)
    {
        if (sp == Speaker.Interviewer) RecognizingInterviewer = on; else RecognizingMe = on;
    }

    async Task HandleFinal(Speaker sp, int id, float[] tail, bool hasVoice)
    {
        if (sp == Speaker.Interviewer) InterviewerSpeaking = false;
        if (!_utterances.TryGetValue(sp, out var u) || u.Id != id) return;
        if (sp == Speaker.Interviewer) SetRecognizing(sp, true);
        var (text, seconds) = await Finish(u, tail, hasVoice, sp == Speaker.Interviewer);
        SetRecognizing(sp, false);
        SetPartial(sp, _utterances.TryGetValue(sp, out var next) ? next.Caption : "");
        if (text.Length == 0 || !IsListening || Settings.IsManual) return;
        if (sp == Speaker.Me)
        {
            if (IsEcho(text)) return;   // the mic heard the interviewer from the speakers
            _lastMeAt = DateTime.Now;
        }
        Entries.Add(new TranscriptEntry(sp, text, seconds));
        TrimEntries();
        if (sp == Speaker.Interviewer) InterviewerSaid(text, seconds);
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

    void InterviewerSaid(string text, double recognition)
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
            Ask(_currentQuestion, Prompts.Question(Context(_questionStartedAt), _currentQuestion), null, continuing, recognition);
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
        Note = "";
        SetAutoSegmentation(false);
        if (!EnsureCaptures(sp == Speaker.Interviewer, sp == Speaker.Me, true)) return;
        SessionStarted();
        int id = ++_manualId;
        _utterances[sp] = new Utterance(id, sp);
        if (sp == Speaker.Interviewer)
        {
            _sysQ.Invoke(() => _sysRec.Start(id));
            RecordingInterviewer = true;
            _recSinceInterviewer = DateTime.Now;
        }
        else
        {
            _micQ.Invoke(() => _micRec.Start(id));
            RecordingMe = true;
            _recSinceMe = DateTime.Now;
        }
        UpdateElapsed();
        _recTimer.Start();
        if (!ModelReady) _ = LoadSpeechModel();
    }

    void UpdateElapsed()
    {
        static string F(DateTime? since) => since is DateTime d ? $"{(int)(DateTime.Now - d).TotalMinutes}:{(DateTime.Now - d).Seconds:00}" : "";
        ElapsedInterviewer = F(_recSinceInterviewer);
        ElapsedMe = F(_recSinceMe);
        if (!IsRecording) _recTimer.Stop();
    }

    async Task FinishRecording(Speaker sp)
    {
        (float[] Tail, bool HasVoice) stopped;
        if (sp == Speaker.Interviewer)
        {
            stopped = _sysQ.Invoke(() => _sysRec.Stop());
            RecordingInterviewer = false;
            _recSinceInterviewer = null;
        }
        else
        {
            stopped = _micQ.Invoke(() => _micRec.Stop());
            RecordingMe = false;
            _recSinceMe = null;
        }
        UpdateElapsed();
        if (!_utterances.TryGetValue(sp, out var u)) return;
        SetRecognizing(sp, true);
        var (text, seconds) = await Finish(u, stopped.Tail, stopped.HasVoice, true);
        SetRecognizing(sp, false);
        SetPartial(sp, _utterances.TryGetValue(sp, out var next) ? next.Caption : "");
        if (text.Length == 0)
        {
            ShowError("Речь не распознана. Проверьте, что звук идёт, и попробуйте ещё раз.");
            return;
        }
        Entries.Add(new TranscriptEntry(sp, text, seconds));
        TrimEntries();
        _currentQuestion = text;
        _questionStartedAt = DateTime.Now;
        var ctx = Context(DateTime.Now.AddSeconds(-0.5));
        if (sp == Speaker.Interviewer) Ask(text, Prompts.Question(ctx, text), null, false, seconds);
        else Ask("Я: " + text, Prompts.Mine(ctx, text), null, false, seconds);
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

    public void TestConnection() =>
        Ask("Проверка связи", "Тест связи: ответь одним словом «работает».", null, false);

    public async void SolveScreenshot()
    {
        try
        {
            Note = "Скриншот…";
            var jpeg = await Task.Run(ScreenGrabber.CaptureJpeg);
            Note = "";
            Ask("Задача с экрана", Prompts.Screenshot(Context(DateTime.Now), !string.IsNullOrWhiteSpace(Settings.AnswerFormat)), jpeg, false);
        }
        catch (Exception ex)
        {
            Note = "";
            ShowError("Скриншот не удался: " + ex.Message);
        }
    }

    public void StopAnswer()
    {
        _answerCts?.Cancel();
        foreach (var a in Answers) a.IsStreaming = false;
        OnChanged(nameof(PhaseTitle));
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

    // MARK: - Model

    string Context(DateTime before)
    {
        var lines = Entries.Where(e => e.Date < before).TakeLast(24).Select(e => $"[{e.Label.Trim()}] {e.Text}").ToList();
        while (lines.Count > 0 && string.Join("\n", lines).Length > 6000) lines.RemoveAt(0);
        return string.Join("\n", lines);
    }

    LLMRequest MakeRequest(string text, byte[]? image) =>
        new(Prompts.System(Settings), text, image, Settings.ActiveModel, Settings.Effort, Settings.FastMode);

    ILLMClient Client => Settings.ActiveProvider is Provider p
        ? new OpenAICompatClient(p, Settings.ProviderKey, Settings.ProviderUrl)
        : Settings.Backend == "api" ? _api : _cli;

    string WarmKey => $"{Settings.Backend}|{Settings.ActiveModel}|{Settings.Effort}|{Settings.FastMode}|{Prompts.System(Settings).GetHashCode()}";

    /// <summary>
    /// Warms whatever the current connection needs: the prompt cache (API), a waiting CLI process
    /// (subscription) or the TLS connection (other providers).
    /// </summary>
    public void PrewarmLLM()
    {
        _lastWarmKey = WarmKey;
        var req = MakeRequest("ping", null);
        if (Settings.ActiveProvider is Provider p)
        {
            var client = new OpenAICompatClient(p, Settings.ProviderKey, Settings.ProviderUrl);
            _ = Task.Run(client.PrewarmAsync);
        }
        else if (Settings.Backend == "api")
        {
            if (string.IsNullOrWhiteSpace(Settings.ApiKey)) return;
            _ = Task.Run(() => _api.PrewarmAsync(req));
        }
        else _ = Task.Run(() => _cli.Prewarm(req));
    }

    public void Shutdown() => _cli.Shutdown();

    void Ask(string question, string prompt, byte[]? image, bool replaceCurrent, double? recognition = null)
    {
        _answerCts?.Cancel();
        foreach (var a in Answers) a.IsStreaming = false;

        var item = new AnswerItem(question) { IsCurrent = true, RecognitionSeconds = recognition };
        // Older answers fold into one line so the new one gets the whole window.
        foreach (var a in Answers) { a.IsExpanded = false; a.IsCurrent = false; }
        var idx = replaceCurrent && _currentAnswerId != null ? Answers.ToList().FindIndex(a => a.Id == _currentAnswerId) : -1;
        if (idx >= 0) Answers[idx] = item;
        else
        {
            Answers.Add(item);
            while (Answers.Count > 30) Answers.RemoveAt(0);
        }
        _currentAnswerId = item.Id;
        OnChanged(nameof(PhaseTitle));

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
                        if (f) item.FirstTokenSeconds = (DateTime.Now - item.Started).TotalSeconds;
                        string snapshot;
                        lock (sb) snapshot = sb.ToString();
                        item.Text = snapshot;
                        if (f) OnChanged(nameof(PhaseTitle));
                    });
                }, cts.Token);
                Ui(() => { item.IsStreaming = false; OnChanged(nameof(PhaseTitle)); });
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                if (cts.IsCancellationRequested) return;
                Ui(() => { item.IsStreaming = false; item.Error = ex.Message; OnChanged(nameof(PhaseTitle)); });
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
            foreach (var e in Entries) sb.Append($"- `{e.Date:HH:mm:ss}` **{e.Label.Trim()}:** {e.Text}\n");
            sb.Append("\n## Подсказки\n\n");
            foreach (var a in Answers) sb.Append($"### {a.Question}\n\n{a.Text}\n\n");
            File.WriteAllText(Path.Combine(SessionsFolder, $"{_sessionStart:yyyy-MM-dd_HH-mm}.md"), sb.ToString(), Encoding.UTF8);
        }
        catch { }
    }
}
