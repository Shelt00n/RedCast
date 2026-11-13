using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;

namespace RedCast.Core;

static class Native
{
    public const uint WDA_NONE = 0x0, WDA_MONITOR = 0x1, WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_APPWINDOW = 0x40000;
    public const int WM_HOTKEY = 0x0312;
    public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int index);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int index, int value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    /// <summary>Hide the window from screen sharing / recording (Windows 10 2004+). Falls back to a black box.</summary>
    public static void SetHiddenFromCapture(IntPtr hwnd, bool hidden)
    {
        if (!hidden) { SetWindowDisplayAffinity(hwnd, WDA_NONE); return; }
        if (!SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE))
            SetWindowDisplayAffinity(hwnd, WDA_MONITOR);
    }

    public static void SetToolWindow(IntPtr hwnd)
    {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        ex = (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;   // not in Alt+Tab / taskbar
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
    }

    public static void SetClickThrough(IntPtr hwnd, bool on)
    {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        ex = on ? ex | WS_EX_TRANSPARENT | WS_EX_LAYERED : ex & ~WS_EX_TRANSPARENT;
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
    }
}

// MARK: - Hotkeys

public sealed record HotKeyCombo(uint Modifiers, uint Vk, string Label)
{
    public string Display
    {
        get
        {
            var parts = new List<string>();
            if ((Modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
            if ((Modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
            if ((Modifiers & Native.MOD_SHIFT) != 0) parts.Add("Shift");
            if ((Modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
            parts.Add(Label);
            return string.Join("+", parts);
        }
    }

    public string Serialize() => $"{Modifiers}|{Vk}|{Label}";

    public static HotKeyCombo? Parse(string s)
    {
        var p = s.Split('|');
        if (p.Length != 3 || !uint.TryParse(p[0], out var m) || !uint.TryParse(p[1], out var v)) return null;
        return new HotKeyCombo(m, v, p[2]);
    }

    public static HotKeyCombo FromKey(Key key, ModifierKeys mods)
    {
        uint m = 0;
        if (mods.HasFlag(ModifierKeys.Control)) m |= Native.MOD_CONTROL;
        if (mods.HasFlag(ModifierKeys.Alt)) m |= Native.MOD_ALT;
        if (mods.HasFlag(ModifierKeys.Shift)) m |= Native.MOD_SHIFT;
        if (mods.HasFlag(ModifierKeys.Windows)) m |= Native.MOD_WIN;
        return new HotKeyCombo(m, (uint)KeyInterop.VirtualKeyFromKey(key), KeyLabel(key));
    }

    static string KeyLabel(Key k) => k switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(k - Key.D0)).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => "Num" + (int)(k - Key.NumPad0),
        Key.Space => "Space",
        Key.Up => "↑",
        Key.Down => "↓",
        Key.Left => "←",
        Key.Right => "→",
        Key.OemPeriod => ".",
        Key.OemComma => ",",
        Key.Return => "Enter",
        _ => k.ToString(),
    };
}

public enum HotKeyAction
{
    ToggleListening, RecordInterviewer, RecordMe, AnswerNow, Screenshot, ToggleWindow, ToggleCompact,
    ScrollUp, ScrollDown, StopAnswer, ClickThrough, Clear,
}

public static class HotKeyInfo
{
    const uint CA = Native.MOD_CONTROL | Native.MOD_ALT;

    public static string Title(HotKeyAction a) => a switch
    {
        HotKeyAction.ToggleListening => "Авто: старт / стоп",
        HotKeyAction.RecordInterviewer => "По кнопкам: записать интервьюера → ответ",
        HotKeyAction.RecordMe => "По кнопкам: записать меня → ответ",
        HotKeyAction.AnswerNow => "Ответить сейчас",
        HotKeyAction.Screenshot => "Скриншот → решение задачи",
        HotKeyAction.ToggleWindow => "Скрыть / показать окно",
        HotKeyAction.ToggleCompact => "Свернуть / развернуть окно",
        HotKeyAction.ScrollUp => "Прокрутить подсказку вверх",
        HotKeyAction.ScrollDown => "Прокрутить подсказку вниз",
        HotKeyAction.StopAnswer => "Остановить ответ",
        HotKeyAction.ClickThrough => "Сквозные клики",
        HotKeyAction.Clear => "Очистить",
        _ => a.ToString(),
    };

    public static HotKeyCombo Default(HotKeyAction a) => a switch
    {
        HotKeyAction.ToggleListening => new(CA, 0x4C, "L"),
        HotKeyAction.RecordInterviewer => new(CA, 0x31, "1"),
        HotKeyAction.RecordMe => new(CA, 0x32, "2"),
        HotKeyAction.AnswerNow => new(CA, 0x20, "Space"),
        HotKeyAction.Screenshot => new(CA, 0x53, "S"),
        HotKeyAction.ToggleWindow => new(CA, 0x48, "H"),
        HotKeyAction.ToggleCompact => new(CA, 0x4D, "M"),
        HotKeyAction.ScrollUp => new(CA, 0x26, "↑"),
        HotKeyAction.ScrollDown => new(CA, 0x28, "↓"),
        HotKeyAction.StopAnswer => new(CA, 0xBE, "."),
        HotKeyAction.ClickThrough => new(CA, 0x54, "T"),
        HotKeyAction.Clear => new(CA, 0x58, "X"),
        _ => new(CA, 0x7B, "F12"),
    };
}

/// <summary>Global hotkeys via RegisterHotKey; customisable and stored in settings.</summary>
public sealed class HotKeyManager
{
    readonly AppSettings _s;
    IntPtr _hwnd;
    HwndSource? _source;
    readonly Dictionary<int, HotKeyAction> _ids = new();
    public HashSet<HotKeyAction> Failed { get; } = new();
    public Action<HotKeyAction>? Pressed;
    public event Action? Changed;

    public HotKeyManager(AppSettings s) { _s = s; }

    public HotKeyCombo? Get(HotKeyAction a)
    {
        if (_s.HotKeys.TryGetValue(a.ToString(), out var v)) return v.Length == 0 ? null : HotKeyCombo.Parse(v);
        return HotKeyInfo.Default(a);
    }

    public void Set(HotKeyAction a, HotKeyCombo? combo)
    {
        if (combo != null)
            foreach (var other in Enum.GetValues<HotKeyAction>())
                if (other != a && Get(other) == combo) _s.HotKeys[other.ToString()] = "";
        _s.HotKeys[a.ToString()] = combo?.Serialize() ?? "";
        _s.TouchHotKeys();
        RegisterAll();
    }

    public void ResetDefaults()
    {
        _s.HotKeys.Clear();
        _s.TouchHotKeys();
        RegisterAll();
    }

    public void Attach(IntPtr hwnd)
    {
        _hwnd = hwnd;
        _source = HwndSource.FromHwnd(hwnd);
        _source?.AddHook(WndProc);
        RegisterAll();
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && _ids.TryGetValue(wParam.ToInt32(), out var a))
        {
            handled = true;
            Pressed?.Invoke(a);
        }
        return IntPtr.Zero;
    }

    public void Suspend()
    {
        foreach (var id in _ids.Keys) Native.UnregisterHotKey(_hwnd, id);
        _ids.Clear();
    }

    public void RegisterAll()
    {
        if (_hwnd == IntPtr.Zero) return;
        Suspend();
        Failed.Clear();
        int id = 0x5100;
        foreach (var a in Enum.GetValues<HotKeyAction>())
        {
            var c = Get(a);
            if (c == null) continue;
            id++;
            if (Native.RegisterHotKey(_hwnd, id, c.Modifiers | Native.MOD_NOREPEAT, c.Vk)) _ids[id] = a;
            else Failed.Add(a);
        }
        Changed?.Invoke();
    }
}

// MARK: - Screenshot

public static class ScreenGrabber
{
    /// <summary>Screen under the mouse pointer as JPEG (long edge ≤ 1568 px — Claude's sweet spot).</summary>
    public static byte[] CaptureJpeg()
    {
        var pos = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(pos);
        var b = screen.Bounds;
        using var full = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(full))
            g.CopyFromScreen(b.Left, b.Top, 0, 0, b.Size, CopyPixelOperation.SourceCopy);

        double scale = Math.Min(1.0, 1568.0 / Math.Max(b.Width, b.Height));
        int w = (int)(b.Width * scale), h = (int)(b.Height * scale);
        using var scaled = new Bitmap(w, h, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(scaled))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(full, 0, 0, w, h);
        }
        var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 85L);
        using var ms = new MemoryStream();
        scaled.Save(ms, codec, ep);
        return ms.ToArray();
    }
}
