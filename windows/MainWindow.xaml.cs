using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using RedCast.Core;
using Brush = System.Windows.Media.Brush;
using Button = System.Windows.Controls.Button;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using Orientation = System.Windows.Controls.Orientation;

namespace RedCast;

public partial class MainWindow : Window
{
    readonly AppState _state = AppState.Shared;
    readonly AppSettings _s = AppSettings.Shared;
    public HotKeyManager HotKeys { get; }
    IntPtr _hwnd;
    bool _compact, _clickThrough, _transcriptVisible = true, _pulsing;
    double _expandedHeight = 680;
    HotKeyAction? _recordingHotKey;
    Button? _recordingButton;
    readonly List<Border> _sysBars = new(), _micBars = new();

    // Fluent icon glyphs (Segoe Fluent Icons / Segoe MDL2 Assets)
    const string GPlay = "", GStop = "", GHeadphones = "", GMic = "",
                 GClose = "", GChevronDown = "", GChevronRight = "",
                 GCheck = "", GWarn = "", GClock = "", GGear = "", GBack = "";

    static readonly Dictionary<string, string> ModelNotes = new()
    {
        ["claude-opus-5-5"] = "Самый умный. Первые слова примерно через 2 с",
        ["claude-sonnet-5-5"] = "Быстрый и умный: ~1 с. Лучший выбор для живого собеседования",
        ["claude-haiku-5-5"] = "Самый быстрый и дешёвый, проще в рассуждениях",
    };

    Brush R(string key) => (Brush)FindResource(key);
    Style S(string key) => (Style)FindResource(key);

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _state;
        HotKeys = new HotKeyManager(_s);
        HotKeys.Pressed = OnHotKey;
        HotKeys.Changed += BuildHotKeyRows;

        if (!double.IsNaN(_s.WindowLeft) && !double.IsNaN(_s.WindowTop))
        {
            Left = _s.WindowLeft;
            Top = _s.WindowTop;
            Width = Math.Max(MinWidth, _s.WindowWidth);
            Height = Math.Max(360, _s.WindowHeight);   // never come back as a squeezed strip
        }
        else
        {
            var wa = SystemParameters.WorkArea;
            Left = wa.Right - Width - 24;
            Top = wa.Top + 24;
        }

        BuildMeter(SysMeter, _sysBars);
        BuildMeter(MicMeter, _micBars);
        BuildModelRows();
        BuildEffortRow();
        BuildFormatPresets();

        ApiKeyBox.Password = _s.ApiKey;
        _state.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() => OnStateChanged(e.PropertyName));
        _s.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() => OnSettingsChanged(e.PropertyName));
        _state.Answers.CollectionChanged += (_, _) =>
        {
            UpdateAll();
            Dispatcher.BeginInvoke(() => AnswersScroll.ScrollToEnd());
        };
        _state.Entries.CollectionChanged += (_, _) =>
        {
            UpdateTranscript();
            Dispatcher.BeginInvoke(() => TranscriptScroll.ScrollToEnd());
        };
        PreviewKeyDown += Window_PreviewKeyDown;
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.SetToolWindow(_hwnd);
            Native.SetHiddenFromCapture(_hwnd, _s.HideFromCapture);
            HotKeys.Attach(_hwnd);
        };
        Closing += (_, e) =>
        {
            if (App.IsQuitting) return;
            e.Cancel = true;
            HideToTray();
        };
        LocationChanged += (_, _) => SaveBounds();
        SizeChanged += (_, _) => SaveBounds();

        UpdateTranscript();
        UpdateAll();
    }

    void SaveBounds()
    {
        if (!IsLoaded || _compact) return;
        _s.WindowLeft = Left;
        _s.WindowTop = Top;
        _s.WindowWidth = Width;
        _s.WindowHeight = Height;
    }

    // MARK: - State → UI

    void OnStateChanged(string? name)
    {
        switch (name)
        {
            case nameof(AppState.SystemLevel): SetMeter(_sysBars, _state.SystemLevel); break;
            case nameof(AppState.MicLevel): SetMeter(_micBars, _state.MicLevel); break;
            case nameof(AppState.PartialInterviewer):
            case nameof(AppState.PartialMe):
                UpdateTranscript();
                Dispatcher.BeginInvoke(() => TranscriptScroll.ScrollToEnd());
                break;
            case nameof(AppState.ElapsedInterviewer):
            case nameof(AppState.ElapsedMe):
                UpdateHeader();
                UpdateRecordButtons();
                break;
            case nameof(AppState.IsListening):
            case nameof(AppState.IsStarting):
            case nameof(AppState.InterviewerSpeaking):
            case nameof(AppState.RecordingInterviewer):
            case nameof(AppState.RecordingMe):
            case nameof(AppState.RecognizingInterviewer):
            case nameof(AppState.RecognizingMe):
            case nameof(AppState.Note):
            case nameof(AppState.PhaseTitle):
            case nameof(AppState.ModelReady):
            case nameof(AppState.ModelFailed):
            case nameof(AppState.ModelStatus):
            case nameof(AppState.ShowProgress):
                UpdateAll();
                break;
        }
    }

    void OnSettingsChanged(string? name)
    {
        switch (name)
        {
            case nameof(AppSettings.ListenMode):
                UpdateAll();
                break;
            case nameof(AppSettings.HideFromCapture):
                if (_hwnd != IntPtr.Zero) Native.SetHiddenFromCapture(_hwnd, _s.HideFromCapture);
                break;
            case nameof(AppSettings.Backend):
            case nameof(AppSettings.ProviderKey):
            case nameof(AppSettings.ProviderModel):
            case nameof(AppSettings.ApiKey):
            case nameof(AppSettings.ClaudePath):
                UpdateBackendPanels();
                UpdateReadiness();
                UpdateHeader();
                break;
            case nameof(AppSettings.Model):
                BuildModelRows();
                UpdateHeader();
                UpdateReadiness();
                break;
            case nameof(AppSettings.Effort):
                BuildEffortRow();
                break;
            case nameof(AppSettings.AnswerFormat):
                BuildFormatPresets();
                break;
            case nameof(AppSettings.SpeechLanguage):
                UpdateReadiness();
                break;
            case nameof(AppSettings.FontSize):
                // re-render answers with the new font size
                foreach (var a in _state.Answers) { var t = a.Text; a.Text = t + " "; a.Text = t; }
                break;
        }
    }

    void UpdateAll()
    {
        bool manual = _s.IsManual;
        ModeAuto.Tag = ModeAuto2.Tag = manual ? null : "on";
        ModeManual.Tag = ModeManual2.Tag = manual ? "on" : null;
        AutoButtons.Visibility = manual ? Visibility.Collapsed : Visibility.Visible;
        ManualButtons.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;
        AutoOptions.Visibility = manual ? Visibility.Collapsed : Visibility.Visible;
        ModeHint.Text = manual
            ? "Две кнопки: «Интервьюер» и «Я». Первое нажатие начинает запись, второе даёт ответ. Пока идёт запись, речь уже распознаётся — ответ приходит почти сразу."
            : "RedCast сам слышит вопросы интервьюера и отвечает после паузы.";

        // Start is the one primary action; on air it turns red with the lit tally.
        bool live = _state.IsListening;
        StartButton.Style = S(live ? "LiveBtn" : "PrimaryBtn");
        StartButton.Content = IconLabel(live ? null : GPlay, live ? "Стоп" : _state.IsStarting ? "Запуск…" : "Начать слушать", live);
        CompactStart.Content = live ? GStop : GPlay;
        CompactStart.Foreground = live ? R("Accent") : R("Fg");
        CompactStart.ToolTip = live ? "Стоп" : "Начать слушать";
        CompactStart.Visibility = CompactAnswer.Visibility = manual ? Visibility.Collapsed : Visibility.Visible;
        CompactRecI.Visibility = CompactRecMe.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;
        CompactRecI.Content = _state.RecordingInterviewer ? GStop : GHeadphones;
        CompactRecI.Foreground = _state.RecordingInterviewer ? R("Accent") : R("Fg2");
        CompactRecMe.Content = _state.RecordingMe ? GStop : GMic;
        CompactRecMe.Foreground = _state.RecordingMe ? R("Accent") : R("Fg2");

        UpdateRecordButtons();
        UpdateHeader();
        UpdateBackendPanels();
        UpdateReadiness();
        UpdateCompactText();
    }

    void UpdateHeader()
    {
        bool onAir = _state.OnAir;
        Brush dot = onAir ? R("Accent") : _state.IsStarting ? R("Warning") : R("Idle");
        StatusDot.Fill = dot;
        CompactDot.Fill = dot;
        SetPulse(onAir);

        PhaseText.Text = _state.PhaseTitle;
        PhaseTimer.Text = _state.RecordingInterviewer ? _state.ElapsedInterviewer : _state.RecordingMe ? _state.ElapsedMe : "";
        string subtitle;
        if (_state.ShowProgress || (!_state.ModelReady && !_state.ModelFailed)) subtitle = _state.ModelStatus;
        else if (_state.ModelFailed) subtitle = "Ошибка модели речи — откройте настройки";
        else subtitle = $"{BackendShort()} · {ModelShort()} · {(_s.IsManual ? "по кнопкам" : "авто")}";
        SubtitleText.Text = subtitle;
        Meters.Visibility = onAir ? Visibility.Visible : Visibility.Collapsed;
    }

    string BackendShort() => _s.Backend switch
    {
        "api" => "Claude API",
        "claudecode" => "Claude · подписка",
        _ => _s.ActiveProvider?.Title.Split(" — ")[0] ?? _s.Backend,
    };

    string ModelShort()
    {
        if (_s.ActiveProvider != null) return _s.ProviderModel.Length > 0 ? _s.ProviderModel : "модель не выбрана";
        var m = Catalog.Models.FirstOrDefault(o => o.Id == _s.Model);
        return m?.Title.Split(" —")[0] ?? _s.Model;
    }

    /// <summary>The tally breathes while on air.</summary>
    void SetPulse(bool on)
    {
        if (on == _pulsing) return;
        _pulsing = on;
        foreach (var e in new[] { StatusPulse, CompactPulse })
        {
            var scale = (ScaleTransform)e.RenderTransform;
            if (!on)
            {
                e.BeginAnimation(OpacityProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
                e.Opacity = 0;
                continue;
            }
            var dur = TimeSpan.FromSeconds(1.4);
            e.BeginAnimation(OpacityProperty, new DoubleAnimation(0.9, 0, dur) { RepeatBehavior = RepeatBehavior.Forever });
            var grow = new DoubleAnimation(0.4, 1, dur) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new QuadraticEase() };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        }
    }

    void BuildMeter(StackPanel host, List<Border> bars)
    {
        for (int i = 0; i < 5; i++)
        {
            var b = new Border
            {
                Width = 3, Height = 4 + i * 2, CornerRadius = new CornerRadius(1), Margin = new Thickness(0, 0, 2, 0),
                Background = R("LineStrong"), VerticalAlignment = VerticalAlignment.Bottom,
            };
            bars.Add(b);
            host.Children.Add(b);
        }
    }

    void SetMeter(List<Border> bars, double level)
    {
        for (int i = 0; i < bars.Count; i++)
        {
            bool lit = level / 100 > i * 0.17 + 0.03;
            bars[i].Background = lit ? (i == 4 ? R("Warning") : R("Positive")) : R("LineStrong");
        }
    }

    /// <summary>Icon (or the lit tally dot) + label, for buttons built in code.</summary>
    UIElement IconLabel(string? glyph, string text, bool tally)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        if (tally)
            sp.Children.Add(new System.Windows.Shapes.Ellipse
            {
                Width = 8, Height = 8, Fill = R("Accent"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0),
            });
        else if (glyph != null)
            sp.Children.Add(new TextBlock { Text = glyph, Style = S("Icon"), FontSize = 13, Margin = new Thickness(0, 0, 8, 0) });
        sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return sp;
    }

    void UpdateRecordButtons()
    {
        string Key(HotKeyAction a) => HotKeys.Get(a)?.Display ?? "";
        RecIButton.Content = RecordContent(_state.RecordingInterviewer, _state.RecognizingInterviewer, GHeadphones, "Интервьюер",
                                           Key(HotKeyAction.RecordInterviewer), _state.ElapsedInterviewer);
        RecIButton.Style = S(_state.RecordingInterviewer ? "LiveBtn" : "Btn");
        RecMeButton.Content = RecordContent(_state.RecordingMe, _state.RecognizingMe, GMic, "Я",
                                            Key(HotKeyAction.RecordMe), _state.ElapsedMe);
        RecMeButton.Style = S(_state.RecordingMe ? "LiveBtn" : "Btn");
    }

    UIElement RecordContent(bool recording, bool recognizing, string glyph, string title, string key, string elapsed)
    {
        var row = new DockPanel();
        FrameworkElement icon = recording
            ? new System.Windows.Shapes.Ellipse { Width = 9, Height = 9, Fill = R("Accent") }
            : new TextBlock { Text = recognizing ? GClock : glyph, Style = S("Icon"), FontSize = 15, Foreground = R("Fg2") };
        icon.Margin = new Thickness(4, 0, 12, 0);
        icon.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = recording ? "Ответить" : title, FontSize = 14, FontWeight = FontWeights.SemiBold });
        string sub = recording ? elapsed : recognizing ? "распознаю…" : key.Length > 0 ? key : "нажмите, чтобы записать";
        text.Children.Add(new TextBlock
        {
            Text = sub,
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = recording ? R("Accent") : R("Fg3"),
            Margin = new Thickness(0, 2, 0, 0),
        });
        row.Children.Add(text);
        return row;
    }

    // MARK: - Readiness (empty state)

    void UpdateReadiness()
    {
        bool empty = _state.Answers.Count == 0;
        ReadinessPanel.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (!empty) return;

        SpeechIcon.Text = _state.ModelReady ? GCheck : _state.ModelFailed ? GWarn : GClock;
        SpeechIcon.Foreground = _state.ModelReady ? R("Positive") : _state.ModelFailed ? R("Warning") : R("Fg3");
        var lang = Catalog.SpeechLanguages.FirstOrDefault(o => o.Id == _s.SpeechLanguage)?.Title ?? "";
        SpeechDetail.Text = _state.ModelReady ? $"Whisper на этом ПК · {lang}" : _state.ModelStatus;
        SpeechAction.Visibility = _state.ModelFailed ? Visibility.Visible : Visibility.Collapsed;

        var problem = _state.ConnectionProblem;
        AiIcon.Text = problem == null ? GCheck : GWarn;
        AiIcon.Foreground = problem == null ? R("Positive") : R("Warning");
        AiDetail.Text = problem ?? $"{BackendShort()} · {ModelShort()}";
        AiAction.Content = problem == null ? "Проверить" : "Настроить";
        AiAction.Style = S(problem == null ? "Btn" : "PrimaryBtn");
        AiAction.Height = AiAction.MinHeight = 24;
        AiAction.FontSize = 11.5;
        AiAction.Padding = new Thickness(9, 0, 9, 0);

        string Key(HotKeyAction x) => HotKeys.Get(x)?.Display ?? "—";
        HowToTitle.Text = _s.IsManual ? "Режим «По кнопкам»" : "Режим «Авто»";
        HowToPanel.Children.Clear();
        var steps = _s.IsManual
            ? new List<(string, string)>
            {
                (Key(HotKeyAction.RecordInterviewer), "Интервьюер начал вопрос — нажмите. Закончил — нажмите ещё раз: ответ появится почти сразу."),
                (Key(HotKeyAction.RecordMe), "То же для вашего микрофона: повторите вопрос вслух или начните отвечать — RedCast подскажет."),
            }
            : new List<(string, string)>
            {
                (Key(HotKeyAction.ToggleListening), "Начать / остановить. RedCast сам ловит вопросы интервьюера и отвечает после паузы."),
                (Key(HotKeyAction.AnswerNow), "Ответить сразу, не дожидаясь паузы."),
            };
        steps.Add((Key(HotKeyAction.Screenshot), "Решить задачу с экрана (live coding, тест)."));
        steps.Add((Key(HotKeyAction.ToggleWindow), "Спрятать / показать окно."));
        foreach (var (combo, text) in steps)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
            var cap = new Border
            {
                Background = R("Raised"), BorderBrush = R("LineStrong"), BorderThickness = new Thickness(1, 1, 1, 2),
                CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 1, 6, 1), MinWidth = 64,
                VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 0, 10, 0),
                Child = new TextBlock
                {
                    Text = combo, FontSize = 11, FontFamily = (FontFamily)FindResource("MonoFont"),
                    Foreground = R("Fg2"), HorizontalAlignment = HorizontalAlignment.Center,
                },
            };
            DockPanel.SetDock(cap, Dock.Left);
            row.Children.Add(cap);
            row.Children.Add(new TextBlock { Text = text, FontSize = 12.5, Foreground = R("Fg2"), TextWrapping = TextWrapping.Wrap });
            HowToPanel.Children.Add(row);
        }
    }

    void AiAction_Click(object s, RoutedEventArgs e)
    {
        if (_state.ConnectionProblem == null) _state.TestConnection();
        else { SelectTab(settings: true); SelectSection("model"); }
    }

    // MARK: - Settings blocks built in code

    void BuildModelRows()
    {
        ModelRows.Children.Clear();
        foreach (var m in Catalog.Models)
        {
            bool selected = _s.Model == m.Id;
            var grid = new DockPanel();
            var radio = new TextBlock
            {
                Text = selected ? "" : "", Style = S("Icon"), FontSize = 14,
                Foreground = selected ? R("Fg") : R("Fg3"), Margin = new Thickness(0, 0, 10, 0),
            };
            DockPanel.SetDock(radio, Dock.Left);
            grid.Children.Add(radio);
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = m.Title.Split(" —")[0], FontWeight = FontWeights.Medium });
            text.Children.Add(new TextBlock
            {
                Text = ModelNotes.TryGetValue(m.Id, out var note) ? note : "", FontSize = 11.5, Foreground = R("Fg3"),
                TextWrapping = TextWrapping.Wrap,
            });
            grid.Children.Add(text);
            var btn = new Button { Style = S("OptionBtn"), Content = grid, Tag = selected ? "on" : null, Margin = new Thickness(0, 1, 0, 1) };
            var id = m.Id;
            btn.Click += (_, _) => _s.Model = id;
            ModelRows.Children.Add(btn);
        }
    }

    void BuildEffortRow()
    {
        EffortRow.Children.Clear();
        foreach (var o in Catalog.Efforts)
        {
            var btn = new Button { Style = S("SegBtn"), Content = o.Title, Tag = _s.Effort == o.Id ? "on" : null };
            var id = o.Id;
            btn.Click += (_, _) => _s.Effort = id;
            EffortRow.Children.Add(btn);
        }
    }

    void BuildFormatPresets()
    {
        FormatPresets.Children.Clear();
        foreach (var p in AnswerFormatPreset.All)
        {
            string title = p.Id switch { "speak" => "Вслух", "standard" => "Стандарт", _ => p.Title.Split(" (")[0] };
            var btn = new Button
            {
                Style = S("SegBtn"), Content = title, Height = 24, MinHeight = 24, Margin = new Thickness(0, 0, 4, 0),
                Tag = _s.AnswerFormat == p.Text ? "on" : null,
                ToolTip = p.Text.Length == 0 ? "Главный тезис, 2–5 пунктов, код при необходимости" : p.Text,
            };
            var text = p.Text;
            btn.Click += (_, _) => _s.AnswerFormat = text;
            FormatPresets.Children.Add(btn);
        }
    }

    bool _loadingProviderKey;

    void UpdateBackendPanels()
    {
        var p = _s.ActiveProvider;
        static Visibility V(bool b) => b ? Visibility.Visible : Visibility.Collapsed;
        ApiPanel.Visibility = V(_s.Backend == "api");
        CliPanel.Visibility = V(_s.Backend == "claudecode");
        ClaudeModelPanel.Visibility = V(p == null);
        ProviderPanel.Visibility = V(p != null);
        if (_s.Backend == "claudecode")
        {
            bool installed = _state.ConnectionProblem != "Claude Code не найден";
            CliIcon.Text = installed ? GCheck : GWarn;
            CliIcon.Foreground = installed ? R("Positive") : R("Warning");
            CliStatus.Text = installed ? "Claude Code найден" : "Claude Code не найден — установите его и выполните claude → /login";
        }
        if (p == null) return;
        ProviderKeyPanel.Visibility = V(p.NeedsKey);
        ProviderUrlPanel.Visibility = V(p.Local);
        ProviderHint.Text = p.KeyHint + (p.NeedsKey ? " Хранится зашифрованным в вашей учётной записи Windows." : "");
        _loadingProviderKey = true;
        if (ProviderKeyBox.Password != _s.ProviderKey) ProviderKeyBox.Password = _s.ProviderKey;
        _loadingProviderKey = false;
    }

    void ProviderKey_Changed(object s, RoutedEventArgs e)
    {
        if (!_loadingProviderKey) _s.ProviderKey = ProviderKeyBox.Password;
    }

    async void ProviderModels_Click(object s, RoutedEventArgs e)
    {
        if (_s.ActiveProvider is not Provider p) return;
        ProviderModelsButton.IsEnabled = false;
        try
        {
            var models = await new OpenAICompatClient(p, _s.ProviderKey, _s.ProviderUrl).ListModelsAsync();
            if (models.Count == 0)
            {
                _state.ShowError(p.Local
                    ? "Сервер не вернул ни одной модели. Скачайте или загрузите модель и попробуйте снова."
                    : "Провайдер не вернул ни одной модели для этого ключа.");
                return;
            }
            var menu = new ContextMenu { PlacementTarget = ProviderModelsButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            foreach (var id in models)
            {
                var item = new MenuItem { Header = id, FontFamily = (FontFamily)FindResource("MonoFont"), FontSize = 12 };
                if (id == _s.ProviderModel) item.FontWeight = FontWeights.SemiBold;
                item.Click += (_, _) => _s.ProviderModel = id;
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        }
        catch (Exception ex)
        {
            _state.ShowError("Список моделей: " + ex.Message);
        }
        finally { ProviderModelsButton.IsEnabled = true; }
    }

    void UpdateCompactText()
    {
        var a = _state.Answers.LastOrDefault();
        string text = _state.PhaseTitle;
        if (a != null)
        {
            if (a.HasError) text = a.Error!;
            else if (a.Preview.Length > 0) text = a.Preview;
        }
        CompactText.Text = text;
        CompactText.ToolTip = a?.Text;
    }

    void UpdateTranscript()
    {
        bool empty = _state.Entries.Count == 0 && _state.PartialInterviewer.Length == 0 && _state.PartialMe.Length == 0;
        TranscriptEmpty.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        TranscriptEmpty.Text = _state.OnAir ? "Жду речь…" : "Здесь появится текст разговора";
        TranscriptScroll.Height = empty ? 30 : 92;
        bool live = _state.PartialInterviewer.Length > 0 || _state.PartialMe.Length > 0;
        LiveDot.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        var last = _state.PartialInterviewer.Length > 0 ? _state.PartialInterviewer
            : _state.PartialMe.Length > 0 ? _state.PartialMe
            : _state.Entries.LastOrDefault() is TranscriptEntry e ? e.Label.Trim() + ": " + e.Text : "";
        TranscriptPreview.Text = _transcriptVisible ? "" : last;
        UpdateCompactText();
    }

    // MARK: - Window

    void Drag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch { }
        }
    }

    /// <summary>Header: drag anywhere, double click folds the window into a strip.</summary>
    void Header_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { ToggleCompact(); return; }
        Drag(sender, e);
    }

    void Strip_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { ToggleCompact(); return; }
        Drag(sender, e);
    }

    public void ShowWindow()
    {
        // Back on screen if it ended up outside (monitor unplugged, resolution changed).
        var vl = SystemParameters.VirtualScreenLeft;
        var vt = SystemParameters.VirtualScreenTop;
        if (Left + 60 > vl + SystemParameters.VirtualScreenWidth || Left + Width < vl + 60 ||
            Top < vt - 20 || Top + 40 > vt + SystemParameters.VirtualScreenHeight)
        {
            var wa = SystemParameters.WorkArea;
            Left = wa.Right - Width - 24;
            Top = wa.Top + 24;
        }
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Topmost = true;
        Activate();
    }

    public void ShowSettings()
    {
        if (_compact) ToggleCompact();
        SelectTab(settings: true);
        ShowWindow();
    }

    public void ToggleVisible()
    {
        if (IsVisible) HideToTray(); else ShowWindow();
    }

    public void ToggleCompact()
    {
        _compact = !_compact;
        if (_compact)
        {
            _expandedHeight = Height;
            SelectTab(settings: false);
            FullView.Visibility = Visibility.Collapsed;
            CompactBar.Visibility = Visibility.Visible;
            ResizeMode = ResizeMode.NoResize;
            Height = 48;
        }
        else
        {
            CompactBar.Visibility = Visibility.Collapsed;
            FullView.Visibility = Visibility.Visible;
            ResizeMode = ResizeMode.CanResize;
            Height = Math.Max(360, _expandedHeight);
        }
    }

    public void ToggleClickThrough()
    {
        _clickThrough = !_clickThrough;
        if (_hwnd != IntPtr.Zero) Native.SetClickThrough(_hwnd, _clickThrough);
        _state.Note = _clickThrough ? $"Сквозные клики: {HotKeys.Get(HotKeyAction.ClickThrough)?.Display} — выключить" : "";
    }

    void SelectTab(bool settings)
    {
        HintsView.Visibility = settings ? Visibility.Collapsed : Visibility.Visible;
        SettingsView.Visibility = settings ? Visibility.Visible : Visibility.Collapsed;
        SettingsButton.Content = settings ? GBack : GGear;
        SettingsButton.ToolTip = settings ? "К подсказкам" : "Настройки";
        SettingsButton.Tag = settings ? "on" : null;
        if (settings)
        {
            BuildHotKeyRows();
            _state.RefreshMicDevices();
            UpdateBackendPanels();
        }
    }

    void SelectSection(string id)
    {
        var map = new (string Id, Button Chip, FrameworkElement Panel)[]
        {
            ("model", ChipModel, SecModel), ("speech", ChipSpeech, SecSpeech), ("answers", ChipAnswers, SecAnswers),
            ("window", ChipWindow, SecWindow), ("keys", ChipKeys, SecKeys), ("about", ChipAbout, SecAbout),
        };
        foreach (var (key, chip, panel) in map)
        {
            chip.Tag = key == id ? "on" : null;
            panel.Visibility = key == id ? Visibility.Visible : Visibility.Collapsed;
        }
        SettingsScroll.ScrollToTop();
    }

    void Chip_Click(object s, RoutedEventArgs e)
    {
        string id = s == ChipSpeech ? "speech" : s == ChipAnswers ? "answers" : s == ChipWindow ? "window"
            : s == ChipKeys ? "keys" : s == ChipAbout ? "about" : "model";
        SelectSection(id);
    }

    void OnHotKey(HotKeyAction a)
    {
        switch (a)
        {
            case HotKeyAction.ToggleListening: _state.ToggleListening(); break;
            case HotKeyAction.RecordInterviewer: _state.ToggleRecord(Speaker.Interviewer); break;
            case HotKeyAction.RecordMe: _state.ToggleRecord(Speaker.Me); break;
            case HotKeyAction.AnswerNow: _state.AnswerNow(); break;
            case HotKeyAction.Screenshot: _state.SolveScreenshot(); break;
            case HotKeyAction.ToggleWindow: ToggleVisible(); break;
            case HotKeyAction.ToggleCompact: if (!IsVisible) ShowWindow(); ToggleCompact(); break;
            case HotKeyAction.ScrollUp: AnswersScroll.ScrollToVerticalOffset(AnswersScroll.VerticalOffset - 140); break;
            case HotKeyAction.ScrollDown: AnswersScroll.ScrollToVerticalOffset(AnswersScroll.VerticalOffset + 140); break;
            case HotKeyAction.StopAnswer: _state.StopAnswer(); break;
            case HotKeyAction.ClickThrough: ToggleClickThrough(); break;
            case HotKeyAction.Clear: _state.Clear(); break;
        }
    }

    // MARK: - Hotkey editor

    void BuildHotKeyRows()
    {
        HotKeysPanel.Children.Clear();
        bool firstRow = true;
        foreach (var a in Enum.GetValues<HotKeyAction>())
        {
            if (!firstRow) HotKeysPanel.Children.Add(new Border { Height = 1, Background = R("Line"), Margin = new Thickness(0, 4, 0, 4) });
            firstRow = false;
            var row = new DockPanel { MinHeight = 30 };
            var clear = new Button
            {
                Style = S("IconBtn"), Content = GClose, FontSize = 9, Width = 24, Height = 24, MinHeight = 24,
                ToolTip = "Убрать сочетание", Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
            };
            clear.Click += (_, _) => { HotKeys.Set(a, null); UpdateAll(); };
            DockPanel.SetDock(clear, Dock.Right);
            var combo = HotKeys.Get(a);
            bool recording = _recordingHotKey == a;
            var btn = new Button
            {
                Style = S("KeyCap"),
                MinWidth = 120,
                VerticalAlignment = VerticalAlignment.Center,
                Content = recording ? "Нажмите сочетание…" : (combo?.Display ?? "не задано"),
                Tag = recording ? "on" : null,
            };
            btn.Click += (_, _) => StartHotKeyRecording(a, btn);
            DockPanel.SetDock(btn, Dock.Right);
            var title = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            title.Children.Add(new TextBlock { Text = HotKeyInfo.Title(a), FontSize = 12.5, TextTrimming = TextTrimming.CharacterEllipsis });
            if (HotKeys.Failed.Contains(a))
                title.Children.Add(new TextBlock { Text = "Занято другой программой — выберите другое", FontSize = 11, Foreground = R("Warning") });
            row.Children.Add(clear);
            row.Children.Add(btn);
            row.Children.Add(title);
            HotKeysPanel.Children.Add(row);
        }
    }

    void StartHotKeyRecording(HotKeyAction a, Button btn)
    {
        HotKeys.Suspend();
        _recordingHotKey = a;
        _recordingButton = btn;
        btn.Content = "Нажмите сочетание…";
        btn.Tag = "on";
        Activate();
        Keyboard.Focus(btn);
    }

    void StopHotKeyRecording()
    {
        _recordingHotKey = null;
        _recordingButton = null;
        HotKeys.RegisterAll();
        BuildHotKeyRows();
        UpdateAll();
    }

    void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_recordingHotKey is not HotKeyAction a) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { StopHotKeyRecording(); return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin or Key.ImeProcessed or Key.None) return;
        var mods = Keyboard.Modifiers;
        bool fKey = key >= Key.F1 && key <= Key.F24;
        if (mods == ModifierKeys.None && !fKey) { System.Media.SystemSounds.Beep.Play(); return; }
        HotKeys.Set(a, HotKeyCombo.FromKey(key, mods));
        StopHotKeyRecording();
    }

    // MARK: - Buttons

    void Start_Click(object s, RoutedEventArgs e) => _state.ToggleListening();
    void Answer_Click(object s, RoutedEventArgs e) => _state.AnswerNow();
    void RecI_Click(object s, RoutedEventArgs e) => _state.ToggleRecord(Speaker.Interviewer);
    void RecMe_Click(object s, RoutedEventArgs e) => _state.ToggleRecord(Speaker.Me);
    void Screenshot_Click(object s, RoutedEventArgs e) => _state.SolveScreenshot();
    void Clear_Click(object s, RoutedEventArgs e) => _state.Clear();
    void Compact_Click(object s, RoutedEventArgs e) => ToggleCompact();
    void Hide_Click(object s, RoutedEventArgs e) => HideToTray();

    /// <summary>✕ hides the window to the tray; RedCast keeps running.</summary>
    public void HideToTray()
    {
        Hide();
        ((App)Application.Current).ShowTrayHint();
    }
    void DismissError_Click(object s, RoutedEventArgs e) => _state.ErrorMessage = null;
    void ModeAuto_Click(object s, RoutedEventArgs e) => _state.SetMode("auto");
    void ModeManual_Click(object s, RoutedEventArgs e) => _state.SetMode("manual");
    void TabHints_Click(object s, RoutedEventArgs e) => SelectTab(settings: false);
    void TabSettings_Click(object s, RoutedEventArgs e) => SelectTab(settings: SettingsView.Visibility != Visibility.Visible);
    void ResetHotKeys_Click(object s, RoutedEventArgs e) { HotKeys.ResetDefaults(); BuildHotKeyRows(); UpdateAll(); }
    void ReloadModel_Click(object s, RoutedEventArgs e) => _ = _state.LoadSpeechModel();
    void Quit_Click(object s, RoutedEventArgs e) => ((App)Application.Current).Quit();
    void Backend_Changed(object s, SelectionChangedEventArgs e) => UpdateBackendPanels();
    void ApiKey_Changed(object s, RoutedEventArgs e) => _s.ApiKey = ApiKeyBox.Password;
    void SizePreset_Click(object s, RoutedEventArgs e) => SetSize((s as Button)?.Tag as string ?? "medium");

    void AnswerHeader_Click(object s, MouseButtonEventArgs e)
    {
        if ((s as FrameworkElement)?.DataContext is AnswerItem a) a.IsExpanded = !a.IsExpanded;
    }

    void CopyAnswer_Click(object s, RoutedEventArgs e)
    {
        if ((s as FrameworkElement)?.DataContext is not AnswerItem a || s is not Button b) return;
        try { Clipboard.SetText(a.Text); } catch { return; }
        b.Content = "Скопировано";
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        t.Tick += (_, _) => { t.Stop(); b.Content = "Копировать"; };
        t.Start();
    }

    /// Quick window sizes (tray → «Размер окна», Settings → Window).
    public void SetSize(string preset)
    {
        if (_compact) ToggleCompact();
        ShowWindow();
        var wa = SystemParameters.WorkArea;
        (double w, double h) = preset switch
        {
            "small" => (400.0, 500.0),
            "large" => (680.0, 880.0),
            "tall" => (Math.Max(Width, 480), wa.Height - 16),
            _ => (480.0, 680.0),
        };
        Width = Math.Min(w, wa.Width - 16);
        Height = Math.Min(h, wa.Height - 16);
        Left = Math.Min(Math.Max(wa.Left + 8, Left), wa.Right - Width - 8);
        Top = preset == "tall" ? wa.Top + 8 : Math.Min(Math.Max(wa.Top + 8, Top), wa.Bottom - Height - 8);
    }

    void RefreshMics_Click(object s, RoutedEventArgs e) => _state.RefreshMicDevices();
    void MicTest_Click(object s, RoutedEventArgs e) => _state.ToggleMicTest();
    void Mic_Changed(object s, SelectionChangedEventArgs e)
    {
        if (IsLoaded && e.AddedItems.Count > 0 && e.RemovedItems.Count > 0) _state.MicDeviceChanged();
    }

    void CheckUpdates_Click(object s, RoutedEventArgs e) => _ = _state.CheckForUpdates(silent: false);
    void InstallUpdate_Click(object s, RoutedEventArgs e) => _ = _state.InstallUpdate();

    void TestConnection_Click(object s, RoutedEventArgs e)
    {
        SelectTab(settings: false);
        _state.TestConnection();
    }

    void TranscriptToggle_Click(object s, RoutedEventArgs e)
    {
        _transcriptVisible = !_transcriptVisible;
        TranscriptScroll.Visibility = _transcriptVisible ? Visibility.Visible : Visibility.Collapsed;
        TranscriptChevron.Text = _transcriptVisible ? GChevronDown : GChevronRight;
        UpdateTranscript();
    }

    void ManualInput_KeyDown(object s, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        _state.AskManual(ManualInput.Text);
        ManualInput.Clear();
    }

    void OpenSessions_Click(object s, RoutedEventArgs e)
    {
        Directory.CreateDirectory(AppState.SessionsFolder);
        Process.Start(new ProcessStartInfo { FileName = AppState.SessionsFolder, UseShellExecute = true });
    }

    void ImportResume_Click(object s, RoutedEventArgs e) { var t = ImportText(); if (t != null) _s.Resume = t; }
    void ImportJob_Click(object s, RoutedEventArgs e) { var t = ImportText(); if (t != null) _s.JobDescription = t; }

    string? ImportText()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Текст (*.txt;*.md;*.rtf)|*.txt;*.md;*.rtf|Все файлы|*.*",
        };
        // The window is always on top: let the file dialog appear above it, not under it.
        Topmost = false;
        try
        {
            if (dlg.ShowDialog(this) != true) return null;
        }
        finally { Topmost = true; }
        try
        {
            if (dlg.FileName.EndsWith(".rtf", StringComparison.OrdinalIgnoreCase))
            {
                var rtb = new System.Windows.Forms.RichTextBox();
                rtb.LoadFile(dlg.FileName);
                return rtb.Text;
            }
            return File.ReadAllText(dlg.FileName);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Не удалось прочитать файл: " + ex.Message, "RedCast");
            return null;
        }
    }
}
