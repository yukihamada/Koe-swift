import Foundation

/// システムメモリの空き状況を監視し、モデルロードの安全性を判定
enum MemoryMonitor {

    /// 物理メモリ総量 (MB)
    static var totalMemoryMB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    }

    /// 現在の空きメモリ (MB) — free + inactive (再利用可能)
    static var availableMemoryMB: Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        // purgeable は実質 free
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        return Int((free + inactive + purgeable) / 1_048_576)
    }

    /// モデルロードに必要な推定メモリ (MB)
    static func estimatedMemoryMB(modelSizeMB: Int, contextSize: Int = 2048) -> Int {
        // モデルウェイト × 1.2 + KVキャッシュ + 初期化オーバーヘッド (~200MB)
        let kvCacheMB = contextSize / 8
        return Int(Double(modelSizeMB) * 1.2) + kvCacheMB + 200
    }

    /// ロード可能かチェック
    static func canLoad(modelSizeMB: Int, contextSize: Int = 2048) -> Bool {
        let needed = estimatedMemoryMB(modelSizeMB: modelSizeMB, contextSize: contextSize)
        let available = availableMemoryMB
        let safetyMarginMB = 512  // 512MB はシステム用に確保
        let canFit = available > needed + safetyMarginMB
        klog("Memory: available=\(available)MB needed=\(needed)MB safety=\(safetyMarginMB)MB → \(canFit ? "OK" : "NG")")
        return canFit
    }

    /// メモリ状況に基づいたモデル推奨
    static func recommendedWhisperModel() -> String {
        let avail = availableMemoryMB
        if avail > 4000 {
            return "large-v3-turbo"     // 1500MB — メモリ余裕あり・最高速
        } else {
            return "large-v3-turbo-q5"  // 547MB — 推奨デフォルト・高速
        }
    }

    /// メモリ状況に基づいたLLMモデル推奨
    static func recommendedLLMModel() -> String? {
        let total = totalMemoryMB
        // 物理メモリ総量で判定（空きは変動するので総量ベースが安定）
        // Whisper (Kotoba Q5 ~700MB GPU) + Metal overhead (~500MB) を差し引く
        if total >= 64_000 {
            return "qwen3.5-4b-q4"    // 2740MB — 64GB以上
        } else if total >= 32_000 {
            return "qwen3-1.7b-q4"    // 1280MB — 32GB
        } else if total >= 24_000 {
            return "qwen3-0.6b-q8"    // 750MB — 24GB
        } else if total >= 16_000 {
            return "qwen3-0.6b-q8"    // 750MB — 16GBはこれが限界
        } else {
            return nil  // 8GB以下 — LLM使用不可
        }
    }

    /// 状況サマリ文字列 (UI表示用)
    static var statusText: String {
        let total = totalMemoryMB
        let avail = availableMemoryMB
        return "メモリ: \(avail)MB 空き / \(total)MB 合計"
    }

    /// メモリ不足時の警告メッセージ
    static func warningText(modelSizeMB: Int) -> String? {
        let needed = estimatedMemoryMB(modelSizeMB: modelSizeMB)
        let available = availableMemoryMB
        if available - needed < 512 {
            return "⚠ メモリ不足の可能性 (空き\(available)MB, 必要~\(needed)MB)。クラッシュする場合は他のアプリを閉じるか、より小さいモデルを選択してください。"
        }
        return nil
    }

    /// 8GB未満のMacではローカルLLMを自動無効化
    /// アプリ起動時に一度呼ぶ
    static func autoDisableLocalLLMIfNeeded() {
        guard totalMemoryMB < 8000 else { return }
        let settings = AppSettings.shared
        if settings.llmUseLocal {
            settings.llmUseLocal = false
            klog("Memory: totalMemory=\(totalMemoryMB)MB (<8GB) — local LLM auto-disabled")
        }
    }
}
