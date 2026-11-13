import AppKit
import Foundation

/// A published GitHub release of RedCast.
struct ReleaseInfo: Sendable {
    let version: String     // "2.1.0"
    let tag: String         // "v2.1.0"
    let assetURL: URL
    let notes: String
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noAsset
    case badArchive
    case command(String)

    var errorDescription: String? {
        switch self {
        case .http(404): return "Релизы не найдены (репозиторий приватный или ещё нет релизов)."
        case .http(let c): return "GitHub ответил ошибкой \(c)."
        case .noAsset: return "В релизе нет файла для macOS."
        case .badArchive: return "Скачанный архив повреждён."
        case .command(let s): return s
        }
    }
}

/// Self-update from GitHub Releases:
/// download → unpack → sign with a stable local certificate → swap the app → relaunch.
enum Updater {
    static let repo = "Shelt00n/RedCast"
    static let assetName = "RedCast-macOS.zip"
    /// Self-signed certificate kept in the login keychain. A stable signature means macOS keeps
    /// the «Screen & System Audio Recording» permission across updates.
    static let signingName = "RedCast Local Signing"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - GitHub

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("RedCast-Updater", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 30
        return r
    }

    static func latest() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, resp) = try await URLSession.shared.data(for: request(url, accept: "application/vnd.github+json"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let link = asset["browser_download_url"] as? String,
              let assetURL = URL(string: link)
        else { throw UpdateError.noAsset }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, tag: tag, assetURL: assetURL, notes: obj["body"] as? String ?? "")
    }

    /// Downloads and unpacks the release. Returns the new RedCast.app in a temp folder.
    static func download(_ release: ReleaseInfo) async throws -> URL {
        let (tmpZip, resp) = try await URLSession.shared.download(for: request(release.assetURL, accept: "application/octet-stream"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("redcast-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(assetName)
        try FileManager.default.moveItem(at: tmpZip, to: zip)
        let out = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let app = out.appendingPathComponent("RedCast.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/RedCast").path) else {
            throw UpdateError.badArchive
        }
        return app
    }

    // MARK: - Stable local code signature

    /// RedCast keeps its certificate in its own keychain with a fixed password, so signing never
    /// shows a keychain prompt (the login keychain would ask «codesign wants to use the key…»).
    static var signingKeychain: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RedCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signing.keychain-db").path
    }
    private static let keychainPassword = "redcast-local-signing"

    private static func unlockKeychain() throws {
        if !FileManager.default.fileExists(atPath: signingKeychain) {
            try run("/usr/bin/security", ["create-keychain", "-p", keychainPassword, signingKeychain])
        }
        try run("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, signingKeychain])
        // No auto-lock.
        try? run("/usr/bin/security", ["set-keychain-settings", signingKeychain])
    }

    /// SHA-1 of the local signing certificate; creates it on first use.
    static func signingIdentity() throws -> String {
        try unlockKeychain()
        if let h = findIdentityHash() { return h }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redcast-sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("cert.cnf")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        x509_extensions = ext
        [dn]
        CN = \(signingName)
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        """.write(to: cfg, atomically: true, encoding: .utf8)
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        let p12 = dir.appendingPathComponent("id.p12").path
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                                     "-days", "3650", "-config", cfg.path])
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                                     "-passout", "pass:redcast", "-name", signingName])
        try run("/usr/bin/security", ["import", p12, "-k", signingKeychain, "-P", "redcast",
                                      "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        // Allow codesign to use the key without any dialog.
        try run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                                      "-k", keychainPassword, signingKeychain])
        guard let h = findIdentityHash() else { throw UpdateError.command("Не удалось создать сертификат подписи.") }
        return h
    }

    private static func findIdentityHash() -> String? {
        guard let out = try? run("/usr/bin/security", ["find-certificate", "-c", signingName, "-Z", signingKeychain]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("SHA-1 hash:") {
            return line.replacingOccurrences(of: "SHA-1 hash:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func sign(_ app: URL) throws {
        let id = try signingIdentity()
        try run("/usr/bin/codesign", ["--force", "--deep", "--keychain", signingKeychain, "--sign", id, app.path])
    }

    static func isLocallySigned(_ app: URL) -> Bool {
        guard let out = try? run("/usr/bin/codesign", ["-dvv", app.path]) else { return false }
        return out.contains("Authority=\(signingName)")
    }

    /// The requirement macOS uses to recognise the app (and keep its permissions).
    static func designatedRequirement(_ app: URL) -> String {
        (try? run("/usr/bin/codesign", ["-d", "-r-", app.path])) ?? ""
    }

    // MARK: - Install

    /// Script that waits for RedCast to quit, swaps the bundle (with rollback) and relaunches it.
    static let installScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; TARGET="$3"; RELAUNCH="$4"
    for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    BACKUP="${TARGET%.app}.previous.app"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP"; then
      if ! mv "$NEW" "$TARGET"; then mv "$BACKUP" "$TARGET"; exit 1; fi
      rm -rf "$BACKUP"
    else
      exit 1
    fi
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    if [ "$RELAUNCH" = "1" ]; then open "$TARGET"; fi
    exit 0
    """

    /// Runs the install script. `wait` = synchronously (self-test), otherwise detached.
    @discardableResult
    static func install(newApp: URL, target: URL, waitForPID pid: Int32, relaunch: Bool, wait: Bool) throws -> Int32 {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("redcast-install-\(UUID().uuidString).sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, String(pid), newApp.path, target.path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        if wait {
            p.waitUntilExit()
            return p.terminationStatus
        }
        return 0
    }

    /// Full update of the running app. Returns only on failure (on success the app quits).
    @MainActor
    static func installAndRelaunch(_ newApp: URL) throws {
        try? sign(newApp)   // best effort: without it the app still works, permissions may need re-granting
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.command("Нет прав на запись в \(target.deletingLastPathComponent().path). Переместите RedCast в «Программы».")
        }
        try install(newApp: newApp, target: target, waitForPID: ProcessInfo.processInfo.processIdentifier,
                    relaunch: true, wait: false)
        NSApp.terminate(nil)
    }

    /// First launch of a build with the ad-hoc signature: re-sign a copy with the local
    /// certificate and swap it in, so the permissions granted from now on survive updates.
    @MainActor
    static func adoptStableSignatureIfNeeded() {
        let key = "stableSignatureAttempt"
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app",
              UserDefaults.standard.string(forKey: key) != currentVersion,
              !isLocallySigned(app) else { return }
        UserDefaults.standard.set(currentVersion, forKey: key)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("redcast-resign-\(UUID().uuidString)/RedCast.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [app.path, copy.path])
            try sign(copy)
            guard isLocallySigned(copy) else { return }
            try installAndRelaunch(copy)
        } catch {
            // Not critical: the app keeps working with its original signature.
        }
    }

    // MARK: - Helpers

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 90) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        final class Output: @unchecked Sendable { var data = Data() }
        let output = Output()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        try p.run()
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw UpdateError.command("\(URL(fileURLWithPath: tool).lastPathComponent): не ответил за \(Int(timeout)) с")
        }
        _ = reader.wait(timeout: .now() + 5)
        let out = String(data: output.data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw UpdateError.command("\(URL(fileURLWithPath: tool).lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }

    // MARK: - Self-test (CI): the whole update path on a temporary copy of the app

    static func selfTest() async -> Int32 {
        func log(_ s: String) { print("[self-test] \(s)"); fflush(stdout) }
        func version(_ app: URL) -> String {
            NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "?"
        }
        var failed = false
        log("current version \(currentVersion)")

        // A. Offline: sign a copy of this build and install it over another copy.
        do {
            let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("redcast-selftest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            let newApp = sandbox.appendingPathComponent("new/RedCast.app", isDirectory: true)
            let target = sandbox.appendingPathComponent("Applications/RedCast.app", isDirectory: true)
            try FileManager.default.createDirectory(at: newApp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [Bundle.main.bundleURL.path, newApp.path])
            try run("/usr/bin/ditto", [Bundle.main.bundleURL.path, target.path])
            try sign(newApp)
            guard isLocallySigned(newApp) else { throw UpdateError.command("local signature not applied") }
            try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            log("A1 signed with «\(signingName)», signature valid ✓")
            let dr = designatedRequirement(newApp)
            log("   designated requirement: \(dr.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard dr.contains("certificate"), !dr.contains("cdhash") else {
                throw UpdateError.command("requirement is not certificate-based → permissions would reset")
            }
            let again = try signingIdentity()
            log("A2 identity is reused (\(again.prefix(8))…) ✓")
            let status = try install(newApp: newApp, target: target, waitForPID: 999_999, relaunch: false, wait: true)
            guard status == 0 else { throw UpdateError.command("install script exit \(status)") }
            guard isLocallySigned(target), version(target) == currentVersion,
                  !FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.command("swap result is wrong") }
            log("A3 install script swapped the app, signature kept ✓")
        } catch {
            failed = true
            log("A FAILED: \(error.localizedDescription)")
        }

        // B. Online: latest release from GitHub → download → unpack → version check.
        do {
            let release = try await latest()
            log("B1 latest release \(release.tag), newer than current: \(isNewer(release.version, than: currentVersion))")
            let app = try await download(release)
            guard version(app) == release.version else { throw UpdateError.command("downloaded version \(version(app))") }
            log("B2 downloaded and unpacked \(release.tag) ✓")
        } catch {
            failed = true
            log("B FAILED: \(error.localizedDescription)")
        }

        log(failed ? "FAILED" : "OK")
        return failed ? 1 : 0
    }
}
