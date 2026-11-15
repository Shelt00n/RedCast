using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace RedCast.Core;

public sealed record ReleaseInfo(string Version, string Tag, string AssetUrl, long Size, string Notes);

/// <summary>
/// Self-update from GitHub Releases: download → unpack → wait for RedCast to quit →
/// copy the new files over the app folder (robocopy) → relaunch.
/// </summary>
public static class Updater
{
    public const string Repo = "Shelt00n/RedCast";
    const string AssetName = "RedCast-Windows.zip";

    static readonly HttpClient Http = CreateHttp();

    static HttpClient CreateHttp()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("RedCast-Updater");
        return h;
    }

    public static string CurrentVersion
    {
        get
        {
            var v = Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 0);
            return $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }
    }

    public static bool IsNewer(string a, string b)
    {
        int[] P(string s) => s.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var pa = P(a);
        var pb = P(b);
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            int x = i < pa.Length ? pa[i] : 0, y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// <summary>
    /// Latest release via the public redirect github.com/…/releases/latest → …/releases/tag/vX.Y.Z
    /// (no API call: the GitHub API limits anonymous clients to 60 requests per hour per IP).
    /// </summary>
    public static async Task<ReleaseInfo> LatestAsync()
    {
        using var req = new HttpRequestMessage(HttpMethod.Head, $"https://github.com/{Repo}/releases/latest");
        using var resp = await Http.SendAsync(req);
        if ((int)resp.StatusCode == 404)
            throw new InvalidOperationException("Релизы не найдены (репозиторий приватный или ещё нет релизов).");
        if ((int)resp.StatusCode is 403 or 429)
            throw new InvalidOperationException("GitHub временно ограничил запросы — попробуйте через несколько минут.");
        resp.EnsureSuccessStatusCode();
        var segments = resp.RequestMessage?.RequestUri?.Segments.Select(x => x.Trim('/')).ToList() ?? new();
        int i = segments.IndexOf("tag");
        if (i < 0 || i + 1 >= segments.Count) throw new InvalidOperationException("Релизы не найдены.");
        var tag = Uri.UnescapeDataString(segments[i + 1]);
        return new ReleaseInfo(tag.TrimStart('v'), tag,
            $"https://github.com/{Repo}/releases/download/{tag}/{AssetName}", 0, "");
    }

    /// <summary>Downloads and unpacks the release; returns the folder that contains the new RedCast.exe.</summary>
    public static async Task<string> DownloadAsync(ReleaseInfo r, IProgress<double>? progress = null)
    {
        var work = Path.Combine(Path.GetTempPath(), "redcast-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        var zip = Path.Combine(work, AssetName);
        using (var resp = await Http.GetAsync(r.AssetUrl, HttpCompletionOption.ResponseHeadersRead))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? r.Size;
            await using var src = await resp.Content.ReadAsStreamAsync();
            await using var dst = File.Create(zip);
            var buf = new byte[1 << 20];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0) progress?.Report((double)done / total);
            }
        }
        var outDir = Path.Combine(work, "unpacked");
        ZipFile.ExtractToDirectory(zip, outDir);
        var exe = Directory.GetFiles(outDir, "RedCast.exe", SearchOption.AllDirectories).FirstOrDefault()
                  ?? throw new InvalidOperationException("Скачанный архив повреждён: нет RedCast.exe.");
        return Path.GetDirectoryName(exe)!;
    }

    const string Script = """
        param([int]$WaitPid, [string]$Src, [string]$Dst, [int]$Relaunch)
        if ($WaitPid -gt 0) { try { Wait-Process -Id $WaitPid -Timeout 60 -ErrorAction SilentlyContinue } catch {} }
        Start-Sleep -Milliseconds 400
        $code = 16
        for ($i = 0; $i -lt 10; $i++) {
            robocopy $Src $Dst /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            $code = $LASTEXITCODE
            if ($code -lt 8) { break }
            Start-Sleep -Seconds 1
        }
        if ($Relaunch -eq 1) { Start-Process -FilePath (Join-Path $Dst 'RedCast.exe') }
        if ($code -lt 8) { exit 0 } else { exit $code }
        """;

    /// <summary>Starts the install script. wait = synchronously (self-test).</summary>
    public static int Install(string newDir, string targetDir, int waitPid, bool relaunch, bool wait)
    {
        var script = Path.Combine(Path.GetTempPath(), $"redcast-install-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(script, Script, new UTF8Encoding(true));
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        foreach (var a in new[]
                 {
                     "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script,
                     "-WaitPid", waitPid.ToString(), "-Src", newDir.TrimEnd('\\'), "-Dst", targetDir.TrimEnd('\\'),
                     "-Relaunch", relaunch ? "1" : "0",
                 })
            psi.ArgumentList.Add(a);
        var p = Process.Start(psi) ?? throw new InvalidOperationException("Не удалось запустить установщик.");
        if (!wait) return 0;
        p.WaitForExit();
        return p.ExitCode;
    }

    public static string AppDir => AppContext.BaseDirectory.TrimEnd('\\');

    /// <summary>Checks that the app folder is writable (e.g. not in Program Files without admin).</summary>
    public static bool CanWriteAppDir()
    {
        try
        {
            var probe = Path.Combine(AppDir, ".write-test");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    // MARK: - Self-test (CI): the whole update path on a temporary copy of the app

    public static async Task<int> SelfTestAsync(string logPath)
    {
        var log = new StringBuilder();
        void Log(string s) { log.AppendLine("[self-test] " + s); File.WriteAllText(logPath, log.ToString()); }
        string Ver(string dir) => FileVersionInfo.GetVersionInfo(Path.Combine(dir, "RedCast.exe")).FileVersion ?? "?";
        bool failed = false;
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        Log($"current version {CurrentVersion}");

        // A. Offline: install a copy of this build over another copy with the real install script.
        try
        {
            var sandbox = Path.Combine(Path.GetTempPath(), "redcast-selftest-" + Guid.NewGuid().ToString("N"));
            var newDir = Path.Combine(sandbox, "new");
            var target = Path.Combine(sandbox, "app");
            CopyDir(AppDir, newDir);
            Directory.CreateDirectory(target);
            File.WriteAllText(Path.Combine(target, "settings-like-user-file.txt"), "keep me");
            int code = Install(newDir, target, waitPid: 0, relaunch: false, wait: true);
            if (code != 0) throw new Exception($"install script exit {code}");
            if (!File.Exists(Path.Combine(target, "RedCast.exe")) || !Ver(target).StartsWith(CurrentVersion))
                throw new Exception("RedCast.exe was not installed");
            if (!File.Exists(Path.Combine(target, "settings-like-user-file.txt")))
                throw new Exception("installer deleted a user file");
            Log($"A install script copied the app ({Ver(target)}), user files kept ✓");
        }
        catch (Exception ex) { failed = true; Log("A FAILED: " + ex); }

        // C. Update from an old multi-DLL build: leftovers are removed, the new build and user files are kept.
        try
        {
            if (!File.Exists(Path.Combine(AppDir, "RedCast.files"))) throw new Exception("RedCast.files missing in the build");
            var dir = Path.Combine(Path.GetTempPath(), "redcast-legacy-" + Guid.NewGuid().ToString("N"));
            CopyDir(AppDir, dir);
            Directory.CreateDirectory(Path.Combine(dir, "ru"));
            foreach (var f in new[] { "RedCast.dll", "RedCast.runtimeconfig.json", "System.Runtime.dll", "coreclr.dll",
                                      "PresentationCore.dll", "ru/NAudio.resources.dll", "ru/PresentationCore.resources.dll",
                                      "user-file.dll" })
                File.WriteAllText(Path.Combine(dir, f), "old");
            File.WriteAllText(Path.Combine(dir, "RedCast.deps.json"), """
                {"targets":{".NETCoreApp,Version=v8.0/win-x64":{
                  "RedCast/1.0.0":{"runtime":{"RedCast.dll":{}}},
                  "runtimepack.Microsoft.NETCore.App.Runtime.win-x64/8.0.0":{"runtime":{"System.Runtime.dll":{}},"native":{"coreclr.dll":{},"RedCast.exe":{}}},
                  "runtimepack.Microsoft.WindowsDesktop.App.Runtime.win-x64/8.0.0":{"runtime":{"PresentationCore.dll":{}}},
                  "NAudio/2.2.1":{"resources":{"lib/net6.0/ru/NAudio.resources.dll":{"locale":"ru"}}}}}}
                """);
            LegacyCleanup.Run(dir);
            var left = new[] { "RedCast.dll", "RedCast.runtimeconfig.json", "System.Runtime.dll", "coreclr.dll",
                               "PresentationCore.dll", "ru/NAudio.resources.dll", "ru/PresentationCore.resources.dll",
                               "RedCast.deps.json" }
                .Where(f => File.Exists(Path.Combine(dir, f))).ToList();
            if (left.Count > 0) throw new Exception("not deleted: " + string.Join(", ", left));
            if (Directory.Exists(Path.Combine(dir, "ru"))) throw new Exception("empty ru\\ folder not deleted");
            if (!File.Exists(Path.Combine(dir, "RedCast.exe"))) throw new Exception("deleted RedCast.exe");
            if (!File.Exists(Path.Combine(dir, "user-file.dll"))) throw new Exception("deleted a file not listed in deps.json");
            foreach (var f in File.ReadAllLines(Path.Combine(dir, "RedCast.files")).Where(x => x.Trim().Length > 0))
                if (!File.Exists(Path.Combine(dir, f.Trim()))) throw new Exception("deleted a file of the new build: " + f);
            Log("C legacy DLLs removed, new build and user files kept ✓");
        }
        catch (Exception ex) { failed = true; Log("C FAILED: " + ex.Message); }

        // D. Speech engine: the native Whisper libraries from runtimes\ load from the single-file exe.
        try
        {
            using var t = new Transcriber();
            await t.LoadAsync("tiny", useGpu: true, new Progress<double>());
            var lib = Whisper.net.LibraryLoader.RuntimeOptions.LoadedLibrary?.ToString() ?? "?";
            var text = await t.TranscribeAsync(new float[16000 * 2], "ru", "", urgent: true);
            Log($"D Whisper loaded ({lib}, {t.Device}), transcribed 2 s of silence: \"{text.Trim()}\" ✓");
        }
        catch (Exception ex) { failed = true; Log("D FAILED: " + ex); }

        // B. Online: latest release from GitHub → download → unpack → version check.
        try
        {
            var r = await LatestAsync();
            Log($"B1 latest release {r.Tag}, newer than current: {IsNewer(r.Version, CurrentVersion)}");
            var dir = await DownloadAsync(r);
            if (!Ver(dir).StartsWith(r.Version)) throw new Exception($"downloaded version {Ver(dir)}");
            Log($"B2 downloaded and unpacked {r.Tag} ✓");
        }
        catch (Exception ex) { failed = true; Log("B FAILED: " + ex.Message); }

        Log(failed ? "FAILED" : "OK");
        return failed ? 1 : 0;
    }

    static void CopyDir(string src, string dst)
    {
        foreach (var dir in Directory.GetDirectories(src, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dir.Replace(src, dst));
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
            File.Copy(f, f.Replace(src, dst), true);
    }
}
