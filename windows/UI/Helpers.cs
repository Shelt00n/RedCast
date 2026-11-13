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
    static readonly Brush Orange = new SolidColorBrush(Color.FromRgb(0xFF, 0xA5, 0x3D));
    static readonly Brush Blue = new SolidColorBrush(Color.FromRgb(0x5A, 0xA9, 0xFF));
    public object Convert(object value, Type t, object p, CultureInfo c) => value is true ? Orange : Blue;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>Minimal Markdown → WPF: **bold**, `code`, headings, bullets, ``` code blocks ```.</summary>
public static class Markdown
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.RegisterAttached(
        "Text", typeof(string), typeof(Markdown), new PropertyMetadata("", OnTextChanged));

    public static string GetText(DependencyObject d) => (string)d.GetValue(TextProperty);
    public static void SetText(DependencyObject d, string v) => d.SetValue(TextProperty, v);

    static readonly Brush CodeBg = new SolidColorBrush(Color.FromArgb(0x60, 0, 0, 0));
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
                    Foreground = Brushes.White,
                    BorderThickness = new Thickness(0),
                    TextWrapping = TextWrapping.NoWrap,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
                panel.Children.Add(new Border
                {
                    Background = CodeBg,
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(10),
                    Margin = new Thickness(0, 4, 0, 6),
                    Child = tb,
                });
            }
            else if (piece.Trim().Length > 0)
            {
                var block = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = size, LineHeight = size * 1.35 };
                var lines = piece.Trim('\n', '\r').Split('\n');
                for (int l = 0; l < lines.Length; l++)
                {
                    var line = lines[l].TrimEnd('\r');
                    var t = line.TrimStart();
                    bool heading = t.StartsWith("#");
                    if (heading) t = t.TrimStart('#').Trim();
                    else if (t.StartsWith("- ") || t.StartsWith("* ")) t = "•  " + t[2..];
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
                inlines.Add(new Run(part[2..^2]) { FontWeight = FontWeights.Bold });
            else if (part.StartsWith("`") && part.EndsWith("`") && part.Length > 2)
                inlines.Add(new Run(part[1..^1]) { FontFamily = Mono, Background = CodeBg });
            else
                inlines.Add(new Run(part) { FontWeight = bold ? FontWeights.Bold : FontWeights.Normal });
        }
    }
}
