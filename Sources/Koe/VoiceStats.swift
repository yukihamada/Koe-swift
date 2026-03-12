import Foundation

/// 音声入力の統計を追跡・表示するシステム
class VoiceStats: ObservableObject {
    static let shared = VoiceStats()

    @Published private(set) var todayCharCount: Int = 0
    @Published private(set) var todaySessionCount: Int = 0
    @Published private(set) var todayDurationSeconds: Double = 0
    @Published private(set) var totalCharCount: Int = 0
    @Published private(set) var totalSessionCount: Int = 0
    @Published private(set) var streak: Int = 0

    /// 日別統計（過去30日分）
    @Published private(set) var dailyStats: [DailyStat] = []

    struct DailyStat: Codable, Identifiable {
        var id: String { date }
        let date: String      // "yyyy-MM-dd"
        var charCount: Int
        var sessionCount: Int
        var durationSeconds: Double
    }

    private let ud = UserDefaults.standard
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var todayKey: String { dateFormatter.string(from: Date()) }

    private init() {
        load()
        refreshToday()
    }

    /// 認識完了時に呼ぶ
    func recordSession(charCount: Int, durationSeconds: Double) {
        let key = todayKey

        // 日別データを更新
        if let idx = dailyStats.firstIndex(where: { $0.date == key }) {
            dailyStats[idx].charCount += charCount
            dailyStats[idx].sessionCount += 1
            dailyStats[idx].durationSeconds += durationSeconds
        } else {
            dailyStats.append(DailyStat(
                date: key,
                charCount: charCount,
                sessionCount: 1,
                durationSeconds: durationSeconds
            ))
        }

        // 30日分に制限
        if dailyStats.count > 30 {
            dailyStats = Array(dailyStats.suffix(30))
        }

        totalCharCount += charCount
        totalSessionCount += 1

        refreshToday()
        updateStreak()
        save()
    }

    /// タイピング換算の節約時間（秒）: 1分あたり80文字と仮定
    var savedTimeSeconds: Double {
        Double(todayCharCount) / 80.0 * 60.0
    }

    var savedTimeDisplay: String {
        let mins = Int(savedTimeSeconds / 60)
        if mins < 1 { return "\(Int(savedTimeSeconds))秒" }
        return "\(mins)分"
    }

    var totalSavedTimeDisplay: String {
        let totalSec = Double(totalCharCount) / 80.0 * 60.0
        let hours = Int(totalSec / 3600)
        let mins = Int((totalSec.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 { return "\(hours)時間\(mins)分" }
        return "\(mins)分"
    }

    /// 過去7日間の文字数配列（グラフ用）
    var weeklyChars: [Int] {
        let cal = Calendar.current
        return (0..<7).reversed().map { daysAgo in
            let date = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = dateFormatter.string(from: date)
            return dailyStats.first { $0.date == key }?.charCount ?? 0
        }
    }

    /// 過去7日の曜日ラベル
    var weeklyLabels: [String] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "E"
        fmt.locale = Locale(identifier: "ja_JP")
        return (0..<7).reversed().map { daysAgo in
            let date = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            return fmt.string(from: date)
        }
    }

    // MARK: - Persistence

    private func refreshToday() {
        let key = todayKey
        if let today = dailyStats.first(where: { $0.date == key }) {
            todayCharCount = today.charCount
            todaySessionCount = today.sessionCount
            todayDurationSeconds = today.durationSeconds
        } else {
            todayCharCount = 0
            todaySessionCount = 0
            todayDurationSeconds = 0
        }
    }

    private func updateStreak() {
        let cal = Calendar.current
        var count = 0
        var checkDate = Date()
        while true {
            let key = dateFormatter.string(from: checkDate)
            if dailyStats.contains(where: { $0.date == key && $0.sessionCount > 0 }) {
                count += 1
                checkDate = cal.date(byAdding: .day, value: -1, to: checkDate)!
            } else {
                break
            }
        }
        streak = count
    }

    private func save() {
        if let data = try? JSONEncoder().encode(dailyStats) {
            ud.set(data, forKey: "voiceStats_daily")
        }
        ud.set(totalCharCount, forKey: "voiceStats_totalChars")
        ud.set(totalSessionCount, forKey: "voiceStats_totalSessions")
    }

    private func load() {
        if let data = ud.data(forKey: "voiceStats_daily"),
           let stats = try? JSONDecoder().decode([DailyStat].self, from: data) {
            dailyStats = stats
        }
        totalCharCount = ud.integer(forKey: "voiceStats_totalChars")
        totalSessionCount = ud.integer(forKey: "voiceStats_totalSessions")
    }
}
