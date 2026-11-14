using System;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;
using RedCast.Core;

namespace RedCast.UI;

public sealed class BoolToVis : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object value, Type t, object p, CultureInfo c)
    {
        bool b = value is bool v && v;
        if (Invert) b = !b;
        return b ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => Binding.DoNothing;
}

public sealed class TextToVis : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => Binding.DoNothing;
}

public sealed class SpeakerBrush : IValueConverter
{
    // Neutral roles, not colors: the interviewer reads as primary text, «Я» as muted.
    static readonly Brush Interviewer = new SolidColorBrush(Color.FromRgb(0xED, 0xED, 0xED));
    static readonly Brush Me = new SolidColorBrush(Color.FromRgb(0x85, 0x85, 0x8B));
    public object Convert(object value, Type t, object p, CultureInfo c) => value is true ? Interviewer : Me;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>Minimal Markdown → WPF: **bold**, `code`, headings, bullets, ``` code blocks ```.</summary>
public static class Markdown
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.RegisterAttached(
        "Text", typeof(string), typeof(Markdown), new PropertyMetadata("", OnTextChanged));

    public static string GetText(DependencyObject d) => (string)d.GetValue(TextProperty);
    public static void SetText(DependencyObject d, string v) => d.SetValue(TextProperty, v);

    static readonly Brush CodeBg = new SolidColorBrush(Color.FromRgb(0x0F, 0x0F, 0x10));
    static readonly Brush InlineCodeBg = new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x26));
    static readonly Brush CodeLine = new SolidColorBrush(Color.FromArgb(0x14, 0xED, 0xED, 0xED));
    static readonly Brush CodeFg = new SolidColorBrush(Color.FromRgb(0xED, 0xED, 0xED));
    static readonly Brush BulletFg = new SolidColorBrush(Color.FromRgb(0x85, 0x85, 0x8B));
    static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    static void OnTextChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ContentControl host) return;
        host.Content = Build((e.NewValue as string) ?? "", AppSettings.Shared.FontSize);
    }

    static UIElement Build(string text, double size)
    {
        var panel = new StackPanel();
        var pieces = text.Split("```");
        for (int i = 0; i < pieces.Length; i++)
        {
            var piece = pieces[i];
            if (i % 2 == 1)
            {
                var lines = piece.Split('\n');
                int start = lines.Length > 1 && !lines[0].Contains(' ') ? 1 : 0;
                var code = string.Join("\n", lines[start..]).Trim('\n', '\r');
                var tb = new TextBox
                {
                    Text = code,
                    IsReadOnly = true,
                    FontFamily = Mono,
                    FontSize = size - 2,
                    Background = Brushes.Transparent,
                    Foreground = CodeFg,
                    CaretBrush = CodeFg,
                    BorderThickness = new Thickness(0),
                    TextWrapping = TextWrapping.NoWrap,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
                panel.Children.Add(new Border
                {
                    Background = CodeBg,
                    BorderBrush = CodeLine,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(12),
                    Margin = new Thickness(0, 8, 0, 8),
                    Child = tb,
                });
            }
            else if (piece.Trim().Length > 0)
            {
                var block = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = size, LineHeight = Math.Round(size * 1.45) };
                var lines = piece.Trim('\n', '\r').Split('\n');
                for (int l = 0; l < lines.Length; l++)
                {
                    var line = lines[l].TrimEnd('\r');
                    var t = line.TrimStart();
                    bool heading = t.StartsWith("#");
                    if (heading) t = t.TrimStart('#').Trim();
                    else if (t.StartsWith("- ") || t.StartsWith("* "))
                    {
                        block.Inlines.Add(new Run("•  ") { Foreground = BulletFg });
                        t = t[2..];
                    }
                    else t = line;
                    AddInline(block.Inlines, t, heading);
                    if (l < lines.Length - 1) block.Inlines.Add(new LineBreak());
                }
                panel.Children.Add(block);
            }
        }
        return panel;
    }

    static readonly Regex Token = new(@"(\*\*[^*]+\*\*|`[^`]+`)", RegexOptions.Compiled);

    static void AddInline(InlineCollection inlines, string text, bool bold)
    {
        foreach (var part in Token.Split(text))
        {
            if (part.Length == 0) continue;
            if (part.StartsWith("**") && part.EndsWith("**") && part.Length > 4)
                inlines.Add(new Run(part[2..^2]) { FontWeight = FontWeights.SemiBold });
            else if (part.StartsWith("`") && part.EndsWith("`") && part.Length > 2)
                inlines.Add(new Run(part[1..^1]) { FontFamily = Mono, Background = InlineCodeBg });
            else
                inlines.Add(new Run(part) { FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal });
        }
    }
}
