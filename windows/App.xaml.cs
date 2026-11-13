using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Forms;
using RedCast.Core;
using Application = System.Windows.Application;
using MessageBox = System.Windows.MessageBox;

namespace RedCast;

public partial class App : Application
{
    NotifyIcon? _tray;
    MainWindow? _window;
    Mutex? _single;
    EventWaitHandle? _showSignal;

    static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RedCast", "error.log");

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (Array.IndexOf(e.Args, "--self-test") >= 0)
        {
            var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RedCast", "selftest.log");
            int code = await Updater.SelfTestAsync(log);
            Shutdown(code);
            return;
        }
        _single = new Mutex(true, "RedCast.SingleInstance", out bool first);
        if (!first)
        {
            // Already running (maybe hidden in the tray): ask that copy to show its window.
            try
            {
                using var show = EventWaitHandle.OpenExisting("RedCast.ShowWindow");
                show.Set();
            }
            catch { }
            Shutdown();
            return;
        }
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "RedCast.ShowWindow");
        new Thread(() =>
        {
            while (_showSignal.WaitOne())
                Dispatcher.BeginInvoke(() => _window?.ShowWindow());
        }) { IsBackground = true, Name = "redcast-show-signal" }.Start();

        DispatcherUnhandledException += (_, ex) =>
        {
            Log(ex.Exception);
            MessageBox.Show("Ошибка: " + ex.Exception.Message + "\n\nПодробности: " + LogPath, "RedCast");
            ex.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log(ex.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, ex) => { Log(ex.Exception); ex.SetObserved(); };

        var settings = AppSettings.Shared;   // create on the UI thread
        _window = new MainWindow();
        _window.Show();
        CreateTray();
        _ = AppState.Shared.LoadSpeechModel();
        AppState.Shared.PrewarmLLM();
        _ = AppState.Shared.CheckForUpdates(silent: true);
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        timer.Tick += (_, _) => _ = AppState.Shared.CheckForUpdates(silent: true);
        timer.Start();
    }

    static void Log(Exception? ex)
    {
        if (ex == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {ex}\n\n");
        }
        catch { }
    }

    void CreateTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Показать окно", null, (_, _) => _window?.ShowWindow());
        menu.Items.Add("Старт / стоп (Авто)", null, (_, _) => AppState.Shared.ToggleListening());
        menu.Items.Add("Записать интервьюера → ответ", null, (_, _) => AppState.Shared.ToggleRecord(Speaker.Interviewer));
        menu.Items.Add("Записать меня → ответ", null, (_, _) => AppState.Shared.ToggleRecord(Speaker.Me));
        menu.Items.Add("Решить задачу с экрана", null, (_, _) => AppState.Shared.SolveScreenshot());
        var size = new ToolStripMenuItem("Размер окна");
        size.DropDownItems.Add("Маленькое", null, (_, _) => _window?.SetSize("small"));
        size.DropDownItems.Add("Среднее", null, (_, _) => _window?.SetSize("medium"));
        size.DropDownItems.Add("Большое", null, (_, _) => _window?.SetSize("large"));
        size.DropDownItems.Add("На всю высоту экрана", null, (_, _) => _window?.SetSize("tall"));
        menu.Items.Add(size);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Проверить обновления", null, async (_, _) =>
        {
            await AppState.Shared.CheckForUpdates(silent: false);
            if (AppState.Shared.HasUpdate) _window?.ShowWindow();
        });
        menu.Items.Add("Настройки", null, (_, _) => _window?.ShowSettings());
        menu.Items.Add("Выйти", null, (_, _) => Quit());

        _tray = new NotifyIcon
        {
            Icon = MakeIcon(),
            Text = "RedCast",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) _window?.ToggleVisible(); };
    }

    static Icon MakeIcon()
    {
        var res = GetResourceStream(new Uri("pack://application:,,,/Assets/redcast.ico"));
        return res != null ? new Icon(res.Stream, 32, 32) : SystemIcons.Application;
    }

    /// <summary>First time the window is hidden: tell where it went.</summary>
    public void ShowTrayHint()
    {
        var flag = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RedCast", "tray-hint-shown");
        if (File.Exists(flag) || _tray == null) return;
        try { Directory.CreateDirectory(Path.GetDirectoryName(flag)!); File.WriteAllText(flag, ""); } catch { }
        _tray.ShowBalloonTip(6000, "RedCast свёрнут в трей",
            "Он продолжает работать. Вернуть окно: клик по значку в трее, Ctrl+Alt+H или повторный запуск RedCast.exe. Выйти: правой кнопкой по значку → «Выйти».",
            ToolTipIcon.Info);
    }

    public static bool IsQuitting { get; private set; }

    public void Quit()
    {
        IsQuitting = true;
        try { AppState.Shared.Stop(); } catch { }
        AppSettings.Shared.Save();
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_tray != null) _tray.Visible = false;
        base.OnExit(e);
    }
}
