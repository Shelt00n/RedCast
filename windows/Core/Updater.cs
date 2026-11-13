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

    public static async Task<ReleaseInfo> LatestAsync()
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
        req.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var resp = await Http.SendAsync(req);
        if ((int)resp.StatusCode == 404)
            throw new InvalidOperationException("Релизы не найдены (репозиторий приватный или ещё нет релизов).");
        resp.EnsureSuccessStatusCode();
        var obj = JsonNode.Parse(await resp.Content.ReadAsStringAsync())!;
        var tag = obj["tag_name"]!.GetValue<string>();
        var asset = (obj["assets"] as JsonArray)?.FirstOrDefault(a => a?["name"]?.GetValue<string>() == AssetName)
                    ?? throw new InvalidOperationException("В релизе нет файла для Windows.");
        return new ReleaseInfo(
            tag.TrimStart('v'),
            tag,
            asset["browser_download_url"]!.GetValue<string>(),
            asset["size"]?.GetValue<long>() ?? 0,
            obj["body"]?.GetValue<string>() ?? "");
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
