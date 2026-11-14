using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

namespace RedCast.Core;

/// <summary>
/// Up to 2.4.0 the app was published as hundreds of loose .NET/WPF DLLs. The updater only adds files
/// (robocopy /E), so after updating to the single-file build the old DLLs stay in the folder.
/// On start the new build deletes them: only files listed in the old RedCast.deps.json, and never
/// anything from this build's own list (RedCast.files) or from runtimes\.
/// </summary>
public static class LegacyCleanup
{
    const string DepsFile = "RedCast.deps.json";
    const string ManifestFile = "RedCast.files";

    /// <summary>True when running as a single-file bundle (the entry assembly has no file on disk).</summary>
#pragma warning disable IL3000 // empty Location in a single-file app is exactly what is checked here
    public static bool IsSingleFile => string.IsNullOrEmpty(typeof(LegacyCleanup).Assembly.Location);
#pragma warning restore IL3000

    /// <summary>Returns how many files were deleted. Never throws.</summary>
    public static int Run(string dir)
    {
        try
        {
            var deps = Path.Combine(dir, DepsFile);
            var manifest = Path.Combine(dir, ManifestFile);
            if (!File.Exists(deps) || !File.Exists(manifest)) return 0;

            var keep = new HashSet<string>(
                File.ReadAllLines(manifest).Select(Normalize).Where(x => x.Length > 0),
                StringComparer.OrdinalIgnoreCase) { ManifestFile, "RedCast.exe" };

            var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var cultures = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var root = JsonNode.Parse(File.ReadAllText(deps));
            if (root?["targets"] is JsonObject tfms)
                foreach (var (_, libs) in tfms)
                {
                    if (libs is not JsonObject libsObj) continue;
                    foreach (var (_, lib) in libsObj)
                    {
                        foreach (var kind in new[] { "runtime", "native" })
                            if (lib?[kind] is JsonObject files)
                                foreach (var (path, _) in files)
                                    targets.Add(Path.GetFileName(path));
                        if (lib?["resources"] is JsonObject res)
                            foreach (var (path, info) in res)
                            {
                                var locale = info?["locale"]?.GetValue<string>();
                                if (string.IsNullOrEmpty(locale) || locale.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) continue;
                                cultures.Add(locale);
                                targets.Add(locale + "/" + Path.GetFileName(path));
                            }
                    }
                }
            targets.Add("RedCast.dll");
            targets.Add("RedCast.runtimeconfig.json");

            // WPF/WinForms satellite assemblies (ru\PresentationCore.resources.dll…) are not listed in deps.json:
            // delete <culture>\X.resources.dll when X.dll is one of the old build's assemblies.
            var assemblies = new HashSet<string>(
                targets.Where(t => !t.Contains('/') && t.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                       .Select(Path.GetFileNameWithoutExtension)!, StringComparer.OrdinalIgnoreCase);
            foreach (var sub in Directory.GetDirectories(dir))
            {
                var culture = Path.GetFileName(sub);
                if (culture.Equals("runtimes", StringComparison.OrdinalIgnoreCase)) continue;
                foreach (var f in Directory.GetFiles(sub, "*.resources.dll"))
                {
                    var name = Path.GetFileName(f);
                    if (assemblies.Contains(name[..^".resources.dll".Length]))
                    {
                        targets.Add(culture + "/" + name);
                        cultures.Add(culture);
                    }
                }
            }

            int deleted = 0;
            foreach (var rel in targets)
            {
                if (rel.Length == 0 || keep.Contains(rel) || rel.StartsWith("runtimes/", StringComparison.OrdinalIgnoreCase)) continue;
                var full = Path.Combine(dir, rel.Replace('/', Path.DirectorySeparatorChar));
                try { if (File.Exists(full)) { File.Delete(full); deleted++; } } catch { }
            }
            foreach (var c in cultures)
            {
                var d = Path.Combine(dir, c);
                try { if (Directory.Exists(d) && !Directory.EnumerateFileSystemEntries(d).Any()) Directory.Delete(d); } catch { }
            }
            // Last: if something was locked, the next start tries again.
            if (!targets.Any(t => !keep.Contains(t) && !t.StartsWith("runtimes/", StringComparison.OrdinalIgnoreCase)
                                  && File.Exists(Path.Combine(dir, t.Replace('/', Path.DirectorySeparatorChar)))))
            {
                try { File.Delete(deps); deleted++; } catch { }
            }
            return deleted;
        }
        catch { return 0; }
    }

    static string Normalize(string p) => p.Trim().Replace('\\', '/');
}
