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

    static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RedCast", "error.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _single = new Mutex(true, "RedCast.SingleInstance", out bool first);
        if (!first)
        {
            MessageBox.Show("RedCast уже запущен — его значок в трее (справа внизу, возможно под стрелкой ^).", "RedCast");
            Shutdown();
            return;
        }

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
        menu.Items.Add(new ToolStripSeparator());
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

    public void Quit()
    {
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
