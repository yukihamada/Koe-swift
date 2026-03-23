import Foundation
import EventKit

/// 議事録のSlack/Notion連携 + カレンダー連携 + リマインダー連携
class MeetingIntegrations {
    static let shared = MeetingIntegrations()

    private let eventStore = EKEventStore()

    // MARK: - Slack Webhook

    /// Slack Webhook URLに議事録を投稿
    func postToSlack(webhookURL: String, summary: String, meetingTitle: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: webhookURL) else {
            klog("Slack: invalid webhook URL")
            completion(false)
            return
        }

        let payload: [String: Any] = [
            "blocks": [
                ["type": "header", "text": ["type": "plain_text", "text": "📝 \(meetingTitle)"]],
                ["type": "section", "text": ["type": "mrkdwn", "text": summary]],
                ["type": "context", "elements": [
                    ["type": "mrkdwn", "text": "🎙 _Koe で自動生成_"]
                ]]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            klog("Slack: post \(ok ? "OK" : "failed") \(error?.localizedDescription ?? "")")
            completion(ok)
        }.resume()
    }

    // MARK: - Notion API

    /// Notion APIで議事録ページを作成
    func postToNotion(token: String, databaseID: String, title: String, content: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            completion(false); return
        }

        let payload: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": [
                "Name": ["title": [["text": ["content": title]]]]
            ],
            "children": [
                ["object": "block", "type": "paragraph",
                 "paragraph": ["rich_text": [["text": ["content": String(content.prefix(2000))]]]]]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            klog("Notion: post \(ok ? "OK" : "failed") \(error?.localizedDescription ?? "")")
            completion(ok)
        }.resume()
    }

    // MARK: - Apple Reminders

    /// TODOをAppleリマインダーに登録
    func addReminders(todos: [String], listName: String = "Koe 議事録TODO", completion: @escaping (Int) -> Void) {
        eventStore.requestAccess(to: .reminder) { granted, error in
            guard granted else {
                klog("Reminders: access denied")
                completion(0)
                return
            }

            // リスト取得 or 作成
            let calendars = self.eventStore.calendars(for: .reminder)
            let list = calendars.first { $0.title == listName } ?? {
                let newList = EKCalendar(for: .reminder, eventStore: self.eventStore)
                newList.title = listName
                newList.source = self.eventStore.defaultCalendarForNewReminders()?.source
                    ?? self.eventStore.sources.first { $0.sourceType == .local }
                try? self.eventStore.saveCalendar(newList, commit: true)
                return newList
            }()

            var count = 0
            for todo in todos {
                let reminder = EKReminder(eventStore: self.eventStore)
                reminder.title = todo
                reminder.calendar = list
                // 期限は明日
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
                do {
                    try self.eventStore.save(reminder, commit: false)
                    count += 1
                } catch {
                    klog("Reminders: save failed: \(error)")
                }
            }
            try? self.eventStore.commit()
            klog("Reminders: added \(count) items to '\(listName)'")
            completion(count)
        }
    }

    // MARK: - Calendar Integration

    /// 次の会議イベントを取得（直近30分以内）
    func getUpcomingMeeting(within minutes: Int = 30) -> EKEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .authorized else {
            eventStore.requestAccess(to: .event) { _, _ in }
            return nil
        }

        let now = Date()
        let end = now.addingTimeInterval(Double(minutes) * 60)
        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // 会議っぽいイベント（Zoom/Teams URLを含む or 参加者がいる）
        return events.first { event in
            let hasURL = event.url != nil ||
                (event.notes ?? "").contains("zoom.us") ||
                (event.notes ?? "").contains("teams.microsoft.com") ||
                (event.notes ?? "").contains("meet.google.com")
            let hasAttendees = (event.attendees?.count ?? 0) > 1
            return hasURL || hasAttendees
        } ?? events.first
    }

    /// カレンダー監視: 会議の1分前に通知
    func startCalendarMonitoring(onMeetingApproaching: @escaping (EKEvent) -> Void) {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, let event = self.getUpcomingMeeting(within: 2) else { return }
            let timeUntil = event.startDate.timeIntervalSinceNow
            if timeUntil > 0 && timeUntil < 120 {
                klog("Calendar: meeting '\(event.title ?? "?")' starting in \(Int(timeUntil))s")
                onMeetingApproaching(event)
            }
        }
    }

    // MARK: - Extract TODOs from formatted text

    /// 整形済みテキストからTODOを抽出
    static func extractTodos(from text: String) -> [String] {
        var todos: [String] = []
        var inTodoSection = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## TODO") || trimmed.hasPrefix("## ネクストアクション") || trimmed.hasPrefix("## ネクストステップ") {
                inTodoSection = true
                continue
            }
            if trimmed.hasPrefix("##") { inTodoSection = false }
            if inTodoSection && trimmed.hasPrefix("- ") {
                let todo = String(trimmed.dropFirst(2))
                if !todo.isEmpty && todo != "特になし" {
                    todos.append(todo)
                }
            }
        }
        return todos
    }
}
