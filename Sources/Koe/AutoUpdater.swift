import AppKit
import Foundation

/// GitHub Releases ベースのオートアップデーター
/// 起動時にバックグラウンドで最新バージョンを確認し、更新があれば通知
class AutoUpdater {
    static let shared = AutoUpdater()

    private let repo = "yukihamada/Koe-swift"
    private let currentVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()

    /// 起動時に呼ぶ（バックグラウンドでチェック）
    func checkForUpdates(silent: Bool = true) {
        DispatchQueue.global(qos: .utility).async {
            self.fetchLatestRelease { release in
                guard let release else { return }
                if self.isNewer(release.version) {
                    DispatchQueue.main.async {
                        self.promptUpdate(release: release)
                    }
                } else if !silent {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "最新版です"
                        alert.informativeText = "Koe \(self.currentVersion) は最新バージョンです。"
                        alert.runModal()
                    }
                }
            }
        }
    }

    // MARK: - GitHub API

    private struct Release {
        let version: String
        let downloadURL: URL
        let isPkg: Bool
        let body: String
    }

    private func fetchLatestRelease(completion: @escaping (Release?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                if let error { klog("AutoUpdater: fetch error \(error.localizedDescription)") }
                completion(nil); return
            }

            // Prefer .pkg, fall back to .zip
            let pkgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".pkg") == true }
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            guard let asset = pkgAsset ?? zipAsset,
                  let dlURLStr = asset["browser_download_url"] as? String,
                  let dlURL = URL(string: dlURLStr) else {
                completion(nil); return
            }

            let isPkg = (asset["name"] as? String)?.hasSuffix(".pkg") == true
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let body = json["body"] as? String ?? ""
            klog("AutoUpdater: latest=\(version) current=\(self.currentVersion) pkg=\(isPkg)")
            completion(Release(version: version, downloadURL: dlURL, isPkg: isPkg, body: body))
        }.resume()
    }

    // MARK: - Version comparison

    private func isNewer(_ remote: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = currentVersion.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    // MARK: - UI

    private func promptUpdate(release: Release) {
        let alert = NSAlert()
        alert.messageText = "声 Koe \(release.version) が利用可能です"
        let notes = release.body.prefix(300)
        alert.informativeText = "現在: v\(currentVersion) → 新: v\(release.version)\n\n\(notes)"
        alert.alertStyle = .informational
        if let icon = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) {
            alert.icon = icon
        }
        alert.addButton(withTitle: "アップデート")
        alert.addButton(withTitle: "後で")

        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(release: release)
        }
    }

    private func downloadAndInstall(release: Release) {
        klog("AutoUpdater: downloading \(release.downloadURL)")

        // Show progress window
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "Koe アップデート中..."
        progressWindow.center()
        progressWindow.isReleasedWhenClosed = false

        let pView = NSView(frame: progressWindow.contentView!.bounds)

        let pLabel = NSTextField(labelWithString: "v\(release.version) をダウンロード中...")
        pLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pLabel.frame = NSRect(x: 20, y: 60, width: 340, height: 20)
        pView.addSubview(pLabel)

        let pBar = NSProgressIndicator(frame: NSRect(x: 20, y: 35, width: 340, height: 20))
        pBar.isIndeterminate = true
        pBar.style = .bar
        pBar.startAnimation(nil)
        pView.addSubview(pBar)

        let pDetail = NSTextField(labelWithString: "")
        pDetail.font = .systemFont(ofSize: 11)
        pDetail.textColor = .secondaryLabelColor
        pDetail.frame = NSRect(x: 20, y: 12, width: 340, height: 16)
        pView.addSubview(pDetail)

        progressWindow.contentView = pView
        progressWindow.makeKeyAndOrderFront(nil)

        let task = URLSession.shared.downloadTask(with: release.downloadURL) { tmpURL, _, error in
            DispatchQueue.main.async {
                progressWindow.close()
            }
            guard let tmpURL, error == nil else {
                klog("AutoUpdater: download error \(error?.localizedDescription ?? "nil")")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "ダウンロードに失敗しました"
                    alert.informativeText = error?.localizedDescription ?? ""
                    alert.runModal()
                }
                return
            }
            DispatchQueue.main.async {
                if release.isPkg {
                    self.installFromPkg(pkgURL: tmpURL)
                } else {
                    self.installFromZip(zipURL: tmpURL)
                }
            }
        }
        task.resume()
    }

    // MARK: - Install from .pkg

    private func installFromPkg(pkgURL: URL) {
        // Copy to a stable temp path (download temp file may be cleaned up)
        let stablePkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("Koe_update.pkg")
        try? FileManager.default.removeItem(at: stablePkg)
        do {
            try FileManager.default.moveItem(at: pkgURL, to: stablePkg)
        } catch {
            klog("AutoUpdater: pkg move error \(error)")
            showError("アップデートファイルの準備に失敗しました")
            return
        }

        klog("AutoUpdater: opening pkg installer \(stablePkg.path)")

        // Open the .pkg with macOS Installer (user will see standard installer UI)
        NSWorkspace.shared.open(stablePkg)

        // Quit current app so installer can replace it
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Install from .zip (legacy)

    private func installFromZip(zipURL: URL) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("koe_update_\(UUID().uuidString)")

        do {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipURL.path, "-d", tmpDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()

            let extracted = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
            guard let newApp = extracted.first(where: { $0.lastPathComponent == "Koe.app" }) else {
                klog("AutoUpdater: Koe.app not found in zip")
                return
            }

            guard let currentApp = Bundle.main.bundlePath as String? else { return }
            let currentURL = URL(fileURLWithPath: currentApp)
            let backupURL = currentURL.deletingLastPathComponent()
                .appendingPathComponent("Koe_old.app")

            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: currentURL, to: backupURL)
            try fm.moveItem(at: newApp, to: currentURL)

            // Verify signature — 検証失敗時はバックアップを復元して中断
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", currentURL.path]
            verify.standardError = Pipe()
            try? verify.run()
            verify.waitUntilExit()
            if verify.terminationStatus != 0 {
                klog("AutoUpdater: signature verification FAILED, rolling back")
                try? fm.removeItem(at: currentURL)
                try? fm.moveItem(at: backupURL, to: currentURL)
                try? fm.removeItem(at: tmpDir)
                return
            }

            klog("AutoUpdater: signature verified, relaunching")

            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = [currentURL.path]
            try relaunch.run()

            try? fm.removeItem(at: backupURL)
            try? fm.removeItem(at: tmpDir)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            klog("AutoUpdater: install error \(error)")
            showError("アップデートに失敗しました: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "アップデートエラー"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
