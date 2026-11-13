using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using RedCast.Core;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using SolidColorBrush = System.Windows.Media.SolidColorBrush;

namespace RedCast;

public partial class MainWindow : Window
{
    readonly AppState _state = AppState.Shared;
    readonly AppSettings _s = AppSettings.Shared;
    public HotKeyManager HotKeys { get; }
    IntPtr _hwnd;
    bool _compact, _clickThrough, _transcriptVisible = true;
    double _expandedHeight = 720;
    HotKeyAction? _recordingHotKey;
    Button? _recordingButton;

    static readonly Brush Green = new SolidColorBrush(Color.FromRgb(0x22, 0xA5, 0x5B));
    static readonly Brush Red = new SolidColorBrush(Color.FromRgb(0xE5, 0x48, 0x4D));
    static readonly Brush Orange = new SolidColorBrush(Color.FromRgb(0xF0, 0x8C, 0x2B));
    static readonly Brush Blue = new SolidColorBrush(Color.FromRgb(0x3B, 0x82, 0xF6));
    static readonly Brush Yellow = new SolidColorBrush(Color.FromRgb(0xE8, 0xC5, 0x3A));
    static readonly Brush Neutral = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
    static readonly Brush Selected = new SolidColorBrush(Color.FromArgb(0x80, 0x3B, 0x82, 0xF6));

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
            Height = Math.Max(360, _s.WindowHeight);
        }
        else
        {
            var wa = SystemParameters.WorkArea;
            Left = wa.Right - Width - 24;
            Top = wa.Top + 24;
        }

        ApiKeyBox.Password = _s.ApiKey;
        _state.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() => OnStateChanged(e.PropertyName));
        _s.PropertyChanged += (_, e) => Dispatcher.BeginInvoke(() => OnSettingsChanged(e.PropertyName));
        _state.Answers.CollectionChanged += (_, _) =>
        {
            UpdateCompactText();
            UpdateEmptyHint();
            Dispatcher.BeginInvoke(() => AnswersScroll.ScrollToEnd());
        };
        _state.Entries.CollectionChanged += (_, _) => Dispatcher.BeginInvoke(() => TranscriptScroll.ScrollToEnd());
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
            case nameof(AppState.IsListening):
            case nameof(AppState.IsStarting):
            case nameof(AppState.InterviewerSpeaking):
            case nameof(AppState.RecordingInterviewer):
            case nameof(AppState.RecordingMe):
            case nameof(AppState.Status):
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
                UpdateBackendPanels();
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
        ModeAuto.Background = manual ? Neutral : Selected;
        ModeManual.Background = manual ? Selected : Neutral;
        AutoButtons.Visibility = manual ? Visibility.Collapsed : Visibility.Visible;
        ManualButtons.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;

        StartButton.Content = _state.StartLabel;
        StartButton.Background = _state.IsListening ? Red : Green;
        CompactStart.Content = _state.IsListening ? "■" : "▶";
        CompactStart.Background = StartButton.Background;
        CompactStart.Visibility = CompactAnswer.Visibility = manual ? Visibility.Collapsed : Visibility.Visible;
        CompactRecI.Visibility = CompactRecMe.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;

        string Key(HotKeyAction a) => HotKeys.Get(a)?.Display ?? "";
        RecIButton.Content = RecordContent(_state.RecordingInterviewer, "🎧  Интервьюер", Key(HotKeyAction.RecordInterviewer));
        RecIButton.Background = _state.RecordingInterviewer ? Red : Orange;
        RecMeButton.Content = RecordContent(_state.RecordingMe, "🎤  Я", Key(HotKeyAction.RecordMe));
        RecMeButton.Background = _state.RecordingMe ? Red : Blue;
        CompactRecI.Content = _state.RecordingInterviewer ? "■ 🎧" : "🎧";
        CompactRecI.Background = RecIButton.Background;
        CompactRecMe.Content = _state.RecordingMe ? "■ 🎤" : "🎤";
        CompactRecMe.Background = RecMeButton.Background;

        Brush dot = _state.IsRecording ? Red
            : _state.IsListening ? (_state.InterviewerSpeaking ? Orange : Green)
            : _state.IsStarting ? Yellow : Brushes.Gray;
        StatusDot.Fill = dot;
        CompactDot.Fill = dot;

        UpdateBackendPanels();
        UpdateCompactText();
        UpdateEmptyHint();
    }

    static object RecordContent(bool recording, string title, string key)
    {
        var sp = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        sp.Children.Add(new TextBlock
        {
            Text = recording ? "■  Готово → ответ" : title,
            FontWeight = FontWeights.SemiBold,
            FontSize = 14,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        sp.Children.Add(new TextBlock
        {
            Text = recording ? "идёт запись…" : (key.Length > 0 ? key : "нажмите, чтобы записать"),
            FontSize = 10.5,
            Opacity = 0.85,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        return sp;
    }

    void UpdateBackendPanels()
    {
        bool api = _s.Backend == "api";
        ApiPanel.Visibility = api ? Visibility.Visible : Visibility.Collapsed;
        CliPanel.Visibility = api ? Visibility.Collapsed : Visibility.Visible;
    }

    void UpdateCompactText()
    {
        var a = _state.Answers.LastOrDefault();
        string text = _state.Status;
        if (a != null)
        {
            if (a.HasError) text = a.Error!;
            else
            {
                var first = a.Text.Split('\n').FirstOrDefault(l => l.Trim().Length > 0) ?? "";
                text = first.Length > 0 ? first.Replace("**", "") : (a.IsStreaming ? "Думаю…" : _state.Status);
            }
        }
        CompactText.Text = text;
        CompactText.ToolTip = a?.Text;
    }

    void UpdateEmptyHint()
    {
        string Key(HotKeyAction x) => HotKeys.Get(x)?.Display ?? "не задано";
        EmptyHint.Visibility = _state.Answers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyHint.Text = _s.IsManual
            ? $"Режим «По кнопкам»\n\n🎧 «Интервьюер» ({Key(HotKeyAction.RecordInterviewer)}): нажмите, когда интервьюер начал вопрос, и ещё раз — когда закончил. Через 1–3 секунды появится ответ.\n\n🎤 «Я» ({Key(HotKeyAction.RecordMe)}): то же для вашего микрофона — повторите вопрос вслух или начните отвечать, и RedCast подскажет, что добавить.\n\nКлавиши меняются во вкладке «Настройки»."
            : $"Режим «Авто»: нажмите «Старт» и начните созвон.\n\nRedCast сам слышит вопросы интервьюера — подсказка появится через 1–3 секунды после паузы.\n{Key(HotKeyAction.AnswerNow)} — ответить сразу · {Key(HotKeyAction.Screenshot)} — задача со скриншота · {Key(HotKeyAction.ToggleWindow)} — спрятать окно · {Key(HotKeyAction.ToggleCompact)} — свернуть.\n\nКлавиши меняются во вкладке «Настройки».";
    }

    // MARK: - Window

    void Drag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch { }
        }
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
            FullView.Visibility = Visibility.Collapsed;
            CompactBar.Visibility = Visibility.Visible;
            ResizeMode = ResizeMode.NoResize;
            Height = 54;
        }
        else
        {
            CompactBar.Visibility = Visibility.Collapsed;
            FullView.Visibility = Visibility.Visible;
            ResizeMode = ResizeMode.CanResizeWithGrip;
            Height = Math.Max(360, _expandedHeight);
        }
    }

    public void ToggleClickThrough()
    {
        _clickThrough = !_clickThrough;
        if (_hwnd != IntPtr.Zero) Native.SetClickThrough(_hwnd, _clickThrough);
        _state.Status = _clickThrough
            ? $"Сквозные клики включены ({HotKeys.Get(HotKeyAction.ClickThrough)?.Display} — выключить)"
            : (_state.IsListening ? "Слушаю…" : "Готов");
    }

    void SelectTab(bool settings)
    {
        HintsView.Visibility = settings ? Visibility.Collapsed : Visibility.Visible;
        SettingsView.Visibility = settings ? Visibility.Visible : Visibility.Collapsed;
        TabHints.Background = settings ? Neutral : Selected;
        TabSettings.Background = settings ? Selected : Neutral;
        if (settings)
        {
            BuildHotKeyRows();
            _state.RefreshMicDevices();
        }
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
        foreach (var a in Enum.GetValues<HotKeyAction>())
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var clear = new Button { Style = (Style)FindResource("IconBtn"), Content = "✕", ToolTip = "Убрать сочетание", Margin = new Thickness(6, 0, 0, 0) };
            clear.Click += (_, _) => { HotKeys.Set(a, null); UpdateAll(); };
            DockPanel.SetDock(clear, Dock.Right);
            var combo = HotKeys.Get(a);
            bool recording = _recordingHotKey == a;
            var btn = new Button
            {
                Style = (Style)FindResource("Btn"),
                MinWidth = 150,
                Padding = new Thickness(10, 4, 10, 4),
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                Content = recording ? "Нажмите сочетание…" : (combo?.Display ?? "не задано"),
                Background = recording ? Selected : Neutral,
            };
            btn.Click += (_, _) => StartHotKeyRecording(a, btn);
            DockPanel.SetDock(btn, Dock.Right);
            var title = new TextBlock { Text = HotKeyInfo.Title(a), VerticalAlignment = VerticalAlignment.Center, FontSize = 13 };
            if (HotKeys.Failed.Contains(a))
            {
                title.Text += "  ⚠ занято другой программой";
                title.Foreground = Yellow;
            }
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
        btn.Background = Selected;
        Activate();
        Keyboard.Focus(btn);
    }

    void StopHotKeyRecording()
    {
        _recordingHotKey = null;
        _recordingButton = null;
        HotKeys.RegisterAll();
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
    void TabSettings_Click(object s, RoutedEventArgs e) => SelectTab(settings: true);
    void ResetHotKeys_Click(object s, RoutedEventArgs e) { HotKeys.ResetDefaults(); UpdateAll(); }
    void ReloadModel_Click(object s, RoutedEventArgs e) => _ = _state.LoadSpeechModel();
    void Quit_Click(object s, RoutedEventArgs e) => ((App)Application.Current).Quit();
    void Backend_Changed(object s, SelectionChangedEventArgs e) => UpdateBackendPanels();
    void ApiKey_Changed(object s, RoutedEventArgs e) => _s.ApiKey = ApiKeyBox.Password;

    void AnswerHeader_Click(object s, MouseButtonEventArgs e)
    {
        if ((s as FrameworkElement)?.DataContext is AnswerItem a) a.IsExpanded = !a.IsExpanded;
    }

    /// Quick window sizes (tray → «Размер окна»).
    public void SetSize(string preset)
    {
        if (_compact) ToggleCompact();
        ShowWindow();
        var wa = SystemParameters.WorkArea;
        (double w, double h) = preset switch
        {
            "small" => (420.0, 480.0),
            "large" => (760.0, 900.0),
            "tall" => (Math.Max(Width, 560), wa.Height - 16),
            _ => (560.0, 720.0),
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
        _state.AskManual("Тест связи: ответь одним словом «работает».");
    }

    void TranscriptToggle_Click(object s, RoutedEventArgs e)
    {
        _transcriptVisible = !_transcriptVisible;
        TranscriptScroll.Visibility = _transcriptVisible ? Visibility.Visible : Visibility.Collapsed;
        TranscriptToggle.Content = _transcriptVisible ? "▾ Расшифровка" : "▸ Расшифровка";
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

    static string? ImportText()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Текст (*.txt;*.md;*.rtf)|*.txt;*.md;*.rtf|Все файлы|*.*",
        };
        if (dlg.ShowDialog() != true) return null;
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
