import Foundation
import Core
import UserNotifications

protocol NotificationSending: Sendable {
    func requestAuthorization() async
    func deliver(_ completion: SuspiciousCompletion) async
}

actor SystemNotificationSender: NotificationSending {
    private var requestedAuthorization = false

    func requestAuthorization() async {
        guard let center = notificationCenter, requestedAuthorization == false else {
            return
        }
        requestedAuthorization = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(_ completion: SuspiciousCompletion) async {
        guard let center = notificationCenter else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Suspicious Codex turn"
        content.subtitle = completion.projectName
        content.body = "\(completion.threadTitle) hit \(completion.reasoningOutputTokens) reasoning tokens."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-pulse.\(completion.threadId).\(completion.turnId)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }
}

protocol NotificationStatePersisting {
    func loadNotifiedTurnTimestamps() -> [String: Date]
    func saveNotifiedTurnTimestamps(_ timestamps: [String: Date])
}

struct UserDefaultsNotificationStateStore: NotificationStatePersisting {
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "codex_pulse.notified_turn_timestamps"
    ) {
        self.userDefaults = userDefaults
        self.key = key
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadNotifiedTurnTimestamps() -> [String: Date] {
        guard let data = userDefaults.data(forKey: key),
              let timestamps = try? decoder.decode([String: Date].self, from: data) else {
            return [:]
        }
        return timestamps
    }

    func saveNotifiedTurnTimestamps(_ timestamps: [String: Date]) {
        guard let data = try? encoder.encode(timestamps) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}
