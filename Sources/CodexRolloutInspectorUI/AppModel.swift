import AppKit
import Core
import Foundation
import Observation
import UserNotifications

protocol NotificationSending: Sendable {
    func requestAuthorization() async
    func deliver(_ completion: SuspiciousCompletion) async
}

actor SystemNotificationSender: NotificationSending {
    private var requestedAuthorization = false

    init() {}

    func requestAuthorization() async {
        guard let center = notificationCenter else {
            return
        }
        guard requestedAuthorization == false else {
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
            identifier: "codex-rollout-inspector.\(completion.threadId).\(completion.turnId)",
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
        key: String = "codex_rollout_inspector.notified_turn_timestamps"
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

struct StatusItemTitleFormatter {
    static func title(
        suspiciousCount: Int,
        runningCount: Int,
        errorMessage: String?
    ) -> String {
        let base: String
        if suspiciousCount > 0 {
            base = "Cdx !\(suspiciousCount) ~\(runningCount)"
        } else if runningCount > 0 {
            base = "Cdx ~\(runningCount)"
        } else {
            base = "Cdx"
        }

        guard let errorMessage, errorMessage.isEmpty == false else {
            return base
        }
        return "\(base)?"
    }

    static func title(snapshot: MonitorSnapshot?, errorMessage: String?) -> String {
        title(
            suspiciousCount: snapshot?.suspiciousCount ?? 0,
            runningCount: snapshot?.runningCount ?? 0,
            errorMessage: errorMessage
        )
    }
}

@MainActor
@Observable
public final class AppModel {
    let suspiciousModulo: Int
    let refreshInterval: Duration
    let sessionLimit: Int
    let threadFetchLimit: Int
    let cwdFilters: [String]

    var searchQuery = "" {
        didSet { normalizeSelection() }
    }

    private(set) var snapshot: MonitorSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var errorMessage: String?
    private(set) var statusTitle = "Cdx"
    private(set) var selectedSessionKey: String?

    var onStatusTitleChange: ((String) -> Void)?

    private let discoveryService: any ThreadDiscoveryService
    private let rolloutParser: RolloutParser
    private let notificationSender: any NotificationSending
    private let notificationStore: any NotificationStatePersisting
    private let fileManager: FileManager

    private var refreshLoopTask: Task<Void, Never>?
    private var notificationState: NotificationPolicyState

    public convenience init() {
        self.init(
            discoveryService: AppServerClient(),
            rolloutParser: RolloutParser(),
            notificationSender: SystemNotificationSender(),
            notificationStore: UserDefaultsNotificationStateStore()
        )
    }

    init(
        discoveryService: any ThreadDiscoveryService = AppServerClient(),
        rolloutParser: RolloutParser = RolloutParser(),
        notificationSender: any NotificationSending = SystemNotificationSender(),
        notificationStore: any NotificationStatePersisting = UserDefaultsNotificationStateStore(),
        suspiciousModulo: Int = 516,
        refreshInterval: Duration = .seconds(2),
        sessionLimit: Int = 3,
        threadFetchLimit: Int? = nil,
        cwdFilters: [String] = [],
        fileManager: FileManager = .default
    ) {
        self.discoveryService = discoveryService
        self.rolloutParser = rolloutParser
        self.notificationSender = notificationSender
        self.notificationStore = notificationStore
        self.suspiciousModulo = suspiciousModulo
        self.refreshInterval = refreshInterval
        self.sessionLimit = sessionLimit
        self.threadFetchLimit = threadFetchLimit ?? max(sessionLimit * 4, 12)
        self.cwdFilters = cwdFilters
        self.fileManager = fileManager
        self.notificationState = NotificationPolicyState(
            notifiedTurnTimestamps: notificationStore.loadNotifiedTurnTimestamps()
        )
        updateStatusTitle()
    }

    var filteredCompletedSessions: [CompletedSession] {
        visibleCompletedSessions.filter { $0.matches(searchQuery: searchQuery) }
    }

    var recentReasoningSessions: [CompletedSession] {
        Array(filteredCompletedSessions.prefix(3))
    }

    var selectedCompletedSession: CompletedSession? {
        let sessions = filteredCompletedSessions
        if let selectedSessionKey,
           let selected = sessions.first(where: { $0.key == selectedSessionKey }) {
            return selected
        }
        return sessions.first
    }

    var errorBannerMessage: String? {
        guard let errorMessage, errorMessage.isEmpty == false else {
            return nil
        }
        return errorMessage
    }

    public func start() {
        guard refreshLoopTask == nil else {
            return
        }

        Task { await notificationSender.requestAuthorization() }
        refreshNow()

        refreshLoopTask = Task { [weak self] in
            while let self, Task.isCancelled == false {
                try? await Task.sleep(for: self.refreshInterval)
                if Task.isCancelled {
                    break
                }
                await self.performRefresh()
            }
        }
    }

    public func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        if let appServerClient = discoveryService as? AppServerClient {
            Task { await appServerClient.shutdown() }
        }
    }

    func refreshNow() {
        Task { await performRefresh() }
    }

    func selectSession(_ key: String?) {
        selectedSessionKey = key
        normalizeSelection()
    }

    func moveSelection(offset: Int) {
        let sessions = filteredCompletedSessions
        guard sessions.isEmpty == false else {
            selectedSessionKey = nil
            return
        }

        guard let currentSelection = selectedSessionKey,
              let currentIndex = sessions.firstIndex(where: { $0.key == currentSelection }) else {
            selectedSessionKey = sessions.first?.key
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), sessions.count - 1)
        selectedSessionKey = sessions[nextIndex].key
    }

    @discardableResult
    func openSelectedRollout() -> Bool {
        guard let path = selectedCompletedSession?.rolloutPath else {
            return false
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func performRefresh() async {
        guard isRefreshing == false else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshAt = Date()
        }

        do {
            let discoveredThreads = try await discoveryService.listThreads(
                limit: threadFetchLimit,
                cwdFilters: cwdFilters
            )
            var parsedRollouts: [String: ParsedRollout] = [:]

            for thread in discoveredThreads {
                guard let rolloutPath = thread.rolloutPath,
                      fileManager.fileExists(atPath: rolloutPath) else {
                    continue
                }

                do {
                    parsedRollouts[rolloutPath] = try await rolloutParser.parse(path: rolloutPath)
                } catch {
                    continue
                }
            }

            let snapshot = SnapshotAssembler.build(
                threads: discoveredThreads,
                parsedRollouts: parsedRollouts,
                suspiciousModulo: suspiciousModulo
            )

            self.snapshot = snapshot
            self.errorMessage = nil
            normalizeSelection()

            let completions = NotificationPolicy.collectNewSuspiciousCompletedTurns(
                snapshot: snapshot,
                state: &notificationState
            )
            if completions.isEmpty == false {
                notificationStore.saveNotifiedTurnTimestamps(notificationState.notifiedTurnTimestamps)
                for completion in completions {
                    Task { await notificationSender.deliver(completion) }
                }
            }

            updateStatusTitle()
        } catch {
            errorMessage = error.localizedDescription
            updateStatusTitle()
        }
    }

    private func normalizeSelection() {
        let sessions = filteredCompletedSessions
        if sessions.isEmpty {
            selectedSessionKey = nil
            return
        }

        if let selectedSessionKey,
           sessions.contains(where: { $0.key == selectedSessionKey }) {
            return
        }

        selectedSessionKey = sessions.first?.key
    }

    private func updateStatusTitle() {
        let nextTitle = StatusItemTitleFormatter.title(
            suspiciousCount: visibleCompletedSessions.filter(\.isInvalidReasoning).count,
            runningCount: snapshot?.runningCount ?? 0,
            errorMessage: errorMessage
        )
        statusTitle = nextTitle
        onStatusTitleChange?(nextTitle)
    }

    private var visibleCompletedSessions: [CompletedSession] {
        guard let snapshot else {
            return []
        }
        return Array(snapshot.completedSessions.prefix(sessionLimit))
    }
}
