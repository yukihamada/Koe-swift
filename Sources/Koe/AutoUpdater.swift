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
                  let assets = json["assets"] as? [[String: Any]],
                  let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let dlURLStr = zipAsset["browser_download_url"] as? String,
                  let dlURL = URL(string: dlURLStr) else {
                if let error { klog("AutoUpdater: fetch error \(error.localizedDescription)") }
                completion(nil); return
            }
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let body = json["body"] as? String ?? ""
            klog("AutoUpdater: latest=\(version) current=\(self.currentVersion)")
            completion(Release(version: version, downloadURL: dlURL, body: body))
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
        alert.messageText = "Koe \(release.version) が利用可能です"
        alert.informativeText = "現在のバージョン: \(currentVersion)\n\n\(release.body.prefix(300))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "アップデート")
        alert.addButton(withTitle: "後で")

        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(release: release)
        }
    }

    private func downloadAndInstall(release: Release) {
        klog("AutoUpdater: downloading \(release.downloadURL)")

        let task = URLSession.shared.downloadTask(with: release.downloadURL) { tmpURL, _, error in
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
                self.installFromZip(zipURL: tmpURL)
            }
        }
        task.resume()
    }

    private func installFromZip(zipURL: URL) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("koe_update_\(UUID().uuidString)")

        do {
            // unzip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipURL.path, "-d", tmpDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()

            // Find Koe.app in extracted files
            let extracted = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
            guard let newApp = extracted.first(where: { $0.lastPathComponent == "Koe.app" }) else {
                klog("AutoUpdater: Koe.app not found in zip")
                return
            }

            // Current app location
            guard let currentApp = Bundle.main.bundlePath as String? else { return }
            let currentURL = URL(fileURLWithPath: currentApp)
            let backupURL = currentURL.deletingLastPathComponent()
                .appendingPathComponent("Koe_old.app")

            // Backup → Replace → Relaunch
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: currentURL, to: backupURL)
            try fm.moveItem(at: newApp, to: currentURL)

            // 署名検証: 展開された .app が正当な実行ファイルか確認
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", currentURL.path]
            let verifyPipe = Pipe()
            verify.standardError = verifyPipe
            try? verify.run()
            verify.waitUntilExit()
            // 未署名の場合は ad-hoc 署名
            if verify.terminationStatus != 0 {
                let sign = Process()
                sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                sign.arguments = ["--force", "--sign", "-", "--deep", currentURL.path]
                sign.standardOutput = FileHandle.nullDevice
                sign.standardError = FileHandle.nullDevice
                try? sign.run()
                sign.waitUntilExit()
            }

            klog("AutoUpdater: installed, relaunching")

            // Relaunch
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = [currentURL.path]
            try relaunch.run()

            // Cleanup
            try? fm.removeItem(at: backupURL)
            try? fm.removeItem(at: tmpDir)

            // Quit current instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            klog("AutoUpdater: install error \(error)")
            let alert = NSAlert()
            alert.messageText = "アップデートに失敗しました"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
