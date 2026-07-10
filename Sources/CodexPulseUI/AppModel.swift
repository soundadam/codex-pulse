import AppKit
import Core
import Foundation
import Observation

public enum TimelineTab: String, CaseIterable, Sendable {
    case allTurns
    case threadDetail
}

@MainActor
@Observable
public final class AppModel {
    let suspiciousModulo: Int
    let refreshInterval: Duration
    let sessionLimit: Int
    let threadFetchLimit: Int
    let timelineLookbackSeconds: TimeInterval
    let cwdFilters: [String]
    let liveSampleMinimumInterval: TimeInterval
    let liveSampleReasoningStep: Int

    var searchQuery = "" {
        didSet { normalizeSelection() }
    }

    private(set) var snapshot: MonitorSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var errorMessage: String?
    private(set) var dataWarningMessage: String?
    private(set) var statusTitle = "Cdx"
    private(set) var selectedTab: TimelineTab = .allTurns
    private(set) var selectedSessionKey: String?
    private(set) var selectedThreadID: String?
    private(set) var selectedTurnKey: String?

    var onStatusTitleChange: ((String) -> Void)?

    private let discoveryService: any ThreadDiscoveryService
    private let snapshotRepository: MonitorSnapshotRepository
    private let notificationSender: any NotificationSending
    private let notificationStore: any NotificationStatePersisting
    private let nowProvider: @Sendable () -> Date
    private let realtimeService: (any ThreadRealtimeSubscribing)?

    private var refreshLoopTask: Task<Void, Never>?
    private var notificationState: NotificationPolicyState
    private var hasBoundRealtimeService = false
    private var latestThreadsByID: [String: CodexThreadRef] = [:]
    private var liveTelemetry: LiveTelemetryStore
    private var trackedDetailedThreadID: String?

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
        refreshInterval: Duration = .seconds(1),
        sessionLimit: Int = 10,
        threadFetchLimit: Int? = nil,
        timelineLookbackSeconds: TimeInterval = 3600,
        liveSampleMinimumInterval: TimeInterval = 2,
        liveSampleReasoningStep: Int = 128,
        cwdFilters: [String] = [],
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.discoveryService = discoveryService
        self.snapshotRepository = MonitorSnapshotRepository(
            discoveryService: discoveryService,
            rolloutParser: rolloutParser
        )
        self.notificationSender = notificationSender
        self.notificationStore = notificationStore
        self.suspiciousModulo = suspiciousModulo
        self.refreshInterval = refreshInterval
        self.sessionLimit = sessionLimit
        self.threadFetchLimit = threadFetchLimit ?? max(sessionLimit * 4, 12)
        self.timelineLookbackSeconds = timelineLookbackSeconds
        self.liveSampleMinimumInterval = liveSampleMinimumInterval
        self.liveSampleReasoningStep = liveSampleReasoningStep
        self.cwdFilters = cwdFilters
        self.nowProvider = nowProvider
        self.realtimeService = discoveryService as? any ThreadRealtimeSubscribing
        self.liveTelemetry = LiveTelemetryStore(
            configuration: LiveTelemetryConfiguration(
                suspiciousModulo: suspiciousModulo,
                lookbackSeconds: timelineLookbackSeconds,
                overviewSampleMinimumInterval: liveSampleMinimumInterval,
                overviewSampleReasoningStep: liveSampleReasoningStep,
                overviewSessionLimit: max(sessionLimit * 3, 24)
            )
        )
        self.notificationState = NotificationPolicyState(
            notifiedTurnTimestamps: notificationStore.loadNotifiedTurnTimestamps()
        )
        updateStatusTitle()
    }

    var filteredCompletedSessions: [CompletedSession] {
        visibleTimelineSessions.filter { $0.matches(searchQuery: searchQuery) }
    }

    var recentReasoningSessions: [CompletedSession] {
        filteredCompletedSessions.sorted(by: timelineDateAscending)
    }

    var selectedCompletedSession: CompletedSession? {
        let sessions = filteredCompletedSessions
        if let selectedSessionKey,
           let selected = sessions.first(where: { $0.key == selectedSessionKey }) {
            return selected
        }
        return sessions.first
    }

    var invalidTimelineTurnCount: Int {
        Set(
            visibleTimelineSessions
                .filter(\.isInvalidReasoning)
                .map { $0.turnKey ?? $0.key }
        )
        .count
    }

    var runningThreadCount: Int {
        snapshot?.runningCount ?? 0
    }

    var observedTimelineTurnCount: Int {
        Set(
            visibleTimelineSessions
                .filter { $0.signalState == .valid }
                .map { $0.turnKey ?? $0.key }
        )
        .count
    }

    var unknownTimelineTurnCount: Int {
        Set(
            visibleTimelineSessions
                .filter { $0.signalState == .unknown }
                .map { $0.turnKey ?? $0.key }
        )
        .count
    }

    var selectedTimelineThreadGroup: ThreadTurnGroup? {
        guard let session = selectedCompletedSession else {
            return nil
        }

        let fallbackTurn = turnDetail(from: session)

        guard let thread = snapshot?.threads.first(where: { $0.id == session.threadId }) else {
            return ThreadTurnGroup(
                threadId: session.threadId,
                threadTitle: session.threadTitle,
                projectName: session.projectName,
                subtitle: session.subtitle,
                turns: [fallbackTurn]
            )
        }

        let merged = mergedThreadTurnGroup(for: thread)
        let visibleTurns = merged.turns.filter(isTurnWithinVisibleWindow)
        guard visibleTurns.isEmpty == false else {
            return ThreadTurnGroup(
                threadId: session.threadId,
                threadTitle: session.threadTitle,
                projectName: session.projectName,
                subtitle: session.subtitle,
                turns: [fallbackTurn]
            )
        }

        return ThreadTurnGroup(
            threadId: merged.threadId,
            threadTitle: merged.threadTitle,
            projectName: merged.projectName,
            subtitle: merged.subtitle,
            turns: visibleTurns
        )
    }

    var selectedTimelineTurns: [TurnDetailItem] {
        selectedTimelineThreadGroup?.turns ?? []
    }

    var selectedTimelineTurnDetail: TurnDetailItem? {
        let turns = selectedTimelineTurns
        guard turns.isEmpty == false else {
            return nil
        }

        if let selectedTurnKey,
           let selected = turns.first(where: { $0.key == selectedTurnKey }) {
            return selected
        }

        if let sessionTurnKey = selectedCompletedSession?.turnKey,
           let selected = turns.first(where: { $0.key == sessionTurnKey }) {
            return selected
        }

        return turns.first
    }

    var selectedTimelineTurnSamples: [LiveTurnSample] {
        guard let turn = selectedTimelineTurnDetail else {
            return []
        }
        return liveSamples(forTurnKey: turn.key, threadID: turn.threadId)
    }

    var threadDetailThreads: [MonitorThread] {
        guard let snapshot else {
            return []
        }

        let visibleThreads = snapshot.threads.filter(isThreadWithinVisibleWindow)
        let query = normalizedSearchQuery
        guard query.isEmpty == false else {
            return visibleThreads
        }

        return visibleThreads.filter { thread in
            let haystack = [
                thread.projectName,
                thread.projectSubtitle,
                thread.threadTitle,
                thread.preview,
                thread.latestTurn?.lastAgentMessage ?? "",
            ]
            .joined(separator: "\n")
            .lowercased()
            return haystack.contains(query)
        }
    }

    var selectedThread: MonitorThread? {
        let threads = threadDetailThreads
        if let selectedThreadID,
           let selected = threads.first(where: { $0.id == selectedThreadID }) {
            return selected
        }
        return threads.first
    }

    var selectedThreadTurnGroup: ThreadTurnGroup? {
        guard let selectedThread else {
            return nil
        }
        let merged = mergedThreadTurnGroup(for: selectedThread)
        let visibleTurns = merged.turns.filter(isTurnWithinVisibleWindow)
        guard visibleTurns.isEmpty == false else {
            return nil
        }
        return ThreadTurnGroup(
            threadId: merged.threadId,
            threadTitle: merged.threadTitle,
            projectName: merged.projectName,
            subtitle: merged.subtitle,
            turns: visibleTurns
        )
    }

    var selectedThreadTurns: [TurnDetailItem] {
        selectedThreadTurnGroup?.turns ?? []
    }

    var selectedTurnDetail: TurnDetailItem? {
        let turns = selectedThreadTurns
        if let selectedTurnKey,
           let selected = turns.first(where: { $0.key == selectedTurnKey }) {
            return selected
        }
        return turns.first
    }

    var selectedTurnSamples: [LiveTurnSample] {
        guard let selectedTurnDetail else {
            return []
        }
        return liveSamples(forTurnKey: selectedTurnDetail.key, threadID: selectedTurnDetail.threadId)
    }

    var errorBannerMessage: String? {
        if let errorMessage, errorMessage.isEmpty == false {
            return errorMessage
        }
        return dataWarningMessage
    }

    public func start() {
        guard refreshLoopTask == nil else {
            return
        }

        Task { await notificationSender.requestAuthorization() }
        bindRealtimeServiceIfNeeded()
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
        if let realtimeService {
            Task { await realtimeService.syncSubscriptions(threadIDs: []) }
        }
        if let appServerClient = discoveryService as? AppServerClient {
            Task { await appServerClient.shutdown() }
        }
    }

    func refreshNow() {
        Task { await performRefresh() }
    }

    func setSelectedTab(_ tab: TimelineTab) {
        selectedTab = tab
        normalizeSelection()
        syncRealtimeSubscriptionsIfPossible()
    }

    func selectSession(_ key: String?) {
        selectedSessionKey = key
        normalizeOverviewSelection()
        syncDetailSelectionFromSelectedSession(forceTurnSelection: true)
        normalizeDetailSelection()
        syncRealtimeSubscriptionsIfPossible()
    }

    func selectThread(_ threadID: String?) {
        selectedThreadID = threadID
        normalizeSelection()
        syncRealtimeSubscriptionsIfPossible()
    }

    func selectTurn(_ key: String?) {
        selectedTurnKey = key
    }

    func moveSelection(offset: Int) {
        switch selectedTab {
        case .allTurns:
            let sessions = filteredCompletedSessions
            guard sessions.isEmpty == false else {
                selectedSessionKey = nil
                return
            }

            guard let currentSelection = selectedSessionKey,
                  let currentIndex = sessions.firstIndex(where: { $0.key == currentSelection }) else {
                selectedSessionKey = sessions.last?.key
                syncDetailSelectionFromSelectedSession(forceTurnSelection: true)
                syncRealtimeSubscriptionsIfPossible()
                return
            }

            let nextIndex = min(max(currentIndex + offset, 0), sessions.count - 1)
            selectedSessionKey = sessions[nextIndex].key
            syncDetailSelectionFromSelectedSession(forceTurnSelection: true)
            syncRealtimeSubscriptionsIfPossible()

        case .threadDetail:
            let turns = selectedThreadTurns
            guard turns.isEmpty == false else {
                selectedTurnKey = nil
                return
            }

            guard let currentTurnKey = selectedTurnKey,
                  let currentIndex = turns.firstIndex(where: { $0.key == currentTurnKey }) else {
                self.selectedTurnKey = turns.first?.key
                return
            }

            let nextIndex = min(max(currentIndex + offset, 0), turns.count - 1)
            selectedTurnKey = turns[nextIndex].key
        }
    }

    @discardableResult
    func openSelectedRollout() -> Bool {
        let path: String?
        switch selectedTab {
        case .allTurns:
            path = selectedTimelineTurnDetail?.rolloutPath ?? selectedCompletedSession?.rolloutPath
        case .threadDetail:
            path = selectedTurnDetail?.rolloutPath
        }

        guard let path else {
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
            lastRefreshAt = nowProvider()
        }

        do {
            let refresh = try await snapshotRepository.refresh(
                threadLimit: threadFetchLimit,
                cwdFilters: cwdFilters,
                suspiciousModulo: suspiciousModulo
            )
            let snapshot = refresh.snapshot
            let discoveredThreads = refresh.discoveredThreads

            self.snapshot = snapshot
            self.latestThreadsByID = Dictionary(
                uniqueKeysWithValues: discoveredThreads.map { ($0.id, $0) }
            )
            reconcileCompletedTurns(with: snapshot)
            self.errorMessage = nil
            self.dataWarningMessage = refresh.skippedRolloutCount > 0
                ? "Could not read \(refresh.skippedRolloutCount) rollout \(refresh.skippedRolloutCount == 1 ? "file" : "files"). Live data is still available."
                : nil
            normalizeSelection()
            syncRealtimeSubscriptionsIfPossible()

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
            dataWarningMessage = nil
            updateStatusTitle()
        }
    }

    private func normalizeSelection() {
        let previousSessionKey = selectedSessionKey
        normalizeOverviewSelection()
        if previousSessionKey != selectedSessionKey {
            syncDetailSelectionFromSelectedSession(forceTurnSelection: true)
        }
        normalizeDetailSelection()
    }

    private func normalizeOverviewSelection() {
        let sessions = filteredCompletedSessions
        if sessions.isEmpty {
            selectedSessionKey = nil
            return
        }

        if let selectedSessionKey,
           sessions.contains(where: { $0.key == selectedSessionKey }) {
            return
        }

        selectedSessionKey = sessions.last?.key
    }

    private func normalizeDetailSelection() {
        let threads = threadDetailThreads
        if threads.isEmpty {
            selectedThreadID = nil
            selectedTurnKey = nil
            trackedDetailedThreadID = nil
            return
        }

        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) == false {
            self.selectedThreadID = nil
        }

        if selectedThreadID == nil {
            selectedThreadID = threads.first?.id
        }

        if trackedDetailedThreadID != selectedThreadID {
            trackedDetailedThreadID = selectedThreadID
            selectedTurnKey = nil
        }

        let turns = selectedThreadTurns
        if turns.isEmpty {
            selectedTurnKey = nil
            return
        }

        if let selectedTurnKey,
           turns.contains(where: { $0.key == selectedTurnKey }) {
            return
        }

        selectedTurnKey = turns.first?.key
    }

    private func syncDetailSelectionFromSelectedSession(forceTurnSelection: Bool) {
        guard let session = selectedCompletedSession else {
            return
        }

        let nextThreadID = session.threadId
        let threadChanged = selectedThreadID != nextThreadID
        selectedThreadID = nextThreadID

        if trackedDetailedThreadID != nextThreadID {
            trackedDetailedThreadID = nextThreadID
            if threadChanged == false {
                selectedTurnKey = nil
            }
        }

        guard let sessionTurnKey = session.turnKey else {
            if forceTurnSelection {
                selectedTurnKey = nil
            }
            return
        }

        if forceTurnSelection || threadChanged || selectedTurnKey == nil {
            selectedTurnKey = sessionTurnKey
        }
    }

    private func updateStatusTitle() {
        let nextTitle = StatusItemTitleFormatter.title(
            suspiciousCount: invalidTimelineTurnCount,
            runningCount: snapshot?.runningCount ?? 0,
            errorMessage: errorMessage
        )
        statusTitle = nextTitle
        onStatusTitleChange?(nextTitle)
    }

    private func bindRealtimeServiceIfNeeded() {
        guard hasBoundRealtimeService == false, let realtimeService else {
            return
        }

        hasBoundRealtimeService = true
        Task { [weak self] in
            await realtimeService.setEventHandler { event in
                await MainActor.run {
                    self?.handleRealtimeEvent(event)
                }
            }
        }
    }

    private func handleRealtimeEvent(_ event: AppServerEvent) {
        switch event {
        case let .tokenUsageUpdated(update):
            liveTelemetry.ingest(
                update,
                context: liveSessionContext(for: update.threadId),
                referenceDate: nowProvider()
            )
            normalizeSelection()
            updateStatusTitle()
        case .turnCompleted:
            refreshNow()
        }
    }

    private func liveSessionContext(for threadID: String) -> LiveSessionContext {
        let thread = snapshot?.threads.first(where: { $0.id == threadID })
        let threadRef = latestThreadsByID[threadID]
        let threadTitle = normalizedText(thread?.name)
            ?? normalizedText(threadRef?.name)
            ?? normalizedText(thread?.preview)
            ?? normalizedText(threadRef?.preview)
            ?? threadID

        return LiveSessionContext(
            projectName: thread?.projectName ?? projectName(for: threadRef),
            projectSubtitle: thread?.projectSubtitle ?? projectSubtitle(for: threadRef),
            threadTitle: threadTitle,
            source: thread?.source ?? threadRef?.source,
            rolloutPath: thread?.rolloutPath ?? threadRef?.rolloutPath,
            startedAt: thread?.latestTurn?.startedAt,
            model: thread?.latestTurn?.model,
            reasoningEffort: thread?.latestTurn?.reasoningEffort,
            assistantPreview: thread?.latestTurn?.lastAgentMessage ?? threadRef?.preview
        )
    }

    private func reconcileCompletedTurns(with snapshot: MonitorSnapshot) {
        liveTelemetry.reconcile(completedSessions: snapshot.completedSessions)
        liveTelemetry.prune(referenceDate: nowProvider())
    }

    private func syncRealtimeSubscriptionsIfPossible() {
        guard let snapshot, let realtimeService else {
            return
        }

        let subscriptionIDs = subscriptionCandidateIDs(from: snapshot)
        Task {
            await realtimeService.syncSubscriptions(threadIDs: subscriptionIDs)
        }
    }

    private func subscriptionCandidateIDs(from snapshot: MonitorSnapshot) -> [String] {
        let runningThreadIDs = snapshot.threads
            .filter { $0.monitorState == .running }
            .prefix(3)
            .map(\.id)

        var selectedThreadIDs = Set(runningThreadIDs)
        if let selectedThreadID {
            selectedThreadIDs.insert(selectedThreadID)
        }

        if selectedThreadIDs.isEmpty, let fallback = snapshot.threads.first?.id {
            selectedThreadIDs.insert(fallback)
        }

        return snapshot.threads.map(\.id).filter { selectedThreadIDs.contains($0) }
    }

    private func projectName(for thread: CodexThreadRef?) -> String {
        guard let thread else {
            return "Unknown project"
        }
        if let cwd = normalizedText(thread.cwd) {
            return cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        return normalizedText(thread.source) ?? "Unknown project"
    }

    private func projectSubtitle(for thread: CodexThreadRef?) -> String {
        guard let thread else {
            return "Waiting for thread metadata"
        }
        if let cwd = normalizedText(thread.cwd) {
            return cwd
        }
        return normalizedText(thread.source) ?? "No project binding"
    }

    private func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private var visibleTimelineSessions: [CompletedSession] {
        let combined = (visibleCompletedSessions + visibleOverviewLiveSessions)
            .sorted(by: timelineDateAscending)
        return Array(combined.suffix(max(sessionLimit * 3, 24)))
    }

    private var visibleCompletedSessions: [CompletedSession] {
        guard let snapshot else {
            return []
        }

        let allSessions = snapshot.completedSessions
        let cutoff = nowProvider().addingTimeInterval(-timelineLookbackSeconds)
        let recentSessions = allSessions.filter {
            ($0.completedAt ?? $0.startedAt ?? .distantPast) >= cutoff
        }
        return Array(recentSessions.prefix(sessionLimit)).map(applyHistoricalSignalState)
    }

    private var visibleOverviewLiveSessions: [CompletedSession] {
        liveTelemetry.visibleOverviewSessions(referenceDate: nowProvider())
    }

    private var normalizedSearchQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func applyHistoricalSignalState(_ session: CompletedSession) -> CompletedSession {
        liveTelemetry.applyingSignal(to: session)
    }

    private func applyHistoricalSignalState(to item: TurnDetailItem) -> TurnDetailItem {
        liveTelemetry.applyingSignal(to: item)
    }

    private func mergedThreadTurnGroup(for thread: MonitorThread) -> ThreadTurnGroup {
        let baseGroup = snapshot?.threadTurnGroups.first(where: { $0.threadId == thread.id })
        var itemsByKey = Dictionary(
            uniqueKeysWithValues: (baseGroup?.turns ?? []).map { ($0.key, applyHistoricalSignalState(to: $0)) }
        )

        for (turnKey, samples) in liveTelemetry.sampleBuckets(forThreadID: thread.id) {
            guard let latestSample = samples.max(by: { left, right in
                if left.observedAt != right.observedAt {
                    return left.observedAt < right.observedAt
                }
                return left.id < right.id
            }) else {
                continue
            }

            let base = itemsByKey[turnKey]
            let nextSignalState = liveTelemetry.signalState(for: turnKey)
            let status: MonitorState
            if nextSignalState == .invalid {
                status = .suspicious
            } else if base?.completedAt != nil {
                status = .normal
            } else {
                status = .running
            }

            itemsByKey[turnKey] = TurnDetailItem(
                key: turnKey,
                threadId: thread.id,
                turnId: latestSample.turnId,
                startedAt: base?.startedAt ?? thread.latestTurn?.startedAt,
                completedAt: base?.completedAt,
                model: base?.model ?? thread.latestTurn?.model,
                reasoningEffort: base?.reasoningEffort ?? thread.latestTurn?.reasoningEffort,
                lastUsage: latestSample.tokenUsage.last,
                totalUsage: latestSample.tokenUsage.total,
                hadInvalidSignal: nextSignalState == .invalid,
                status: status,
                assistantPreview: base?.assistantPreview ?? thread.latestTurn?.lastAgentMessage ?? latestThreadsByID[thread.id]?.preview,
                rolloutPath: base?.rolloutPath ?? thread.rolloutPath
            )
        }

        let turns = itemsByKey.values.sorted(by: turnDetailNewestFirst)
        return ThreadTurnGroup(
            threadId: thread.id,
            threadTitle: thread.threadTitle,
            projectName: thread.projectName,
            subtitle: thread.projectSubtitle,
            turns: turns
        )
    }

    private func isThreadWithinVisibleWindow(_ thread: MonitorThread) -> Bool {
        let cutoff = nowProvider().addingTimeInterval(-timelineLookbackSeconds)
        if let latestUpdateAt = thread.latestUpdateAt, latestUpdateAt >= cutoff {
            return true
        }

        return liveTelemetry.hasActivity(threadID: thread.id, since: cutoff)
    }

    private func isTurnWithinVisibleWindow(_ turn: TurnDetailItem) -> Bool {
        let cutoff = nowProvider().addingTimeInterval(-timelineLookbackSeconds)
        if let liveSampleTime = liveTelemetry.latestObservedAt(forTurnKey: turn.key),
           liveSampleTime >= cutoff {
            return true
        }

        let timestamp = turn.completedAt ?? turn.startedAt ?? .distantPast
        return timestamp >= cutoff
    }

    private func turnDetail(from session: CompletedSession) -> TurnDetailItem {
        TurnDetailItem(
            key: session.turnKey ?? session.key,
            threadId: session.threadId,
            turnId: session.turnId,
            startedAt: session.startedAt,
            completedAt: session.completedAt,
            model: session.model,
            reasoningEffort: session.reasoningEffort,
            lastUsage: session.tokenUsage.last,
            totalUsage: session.tokenUsage.total,
            hadInvalidSignal: session.signalState == .invalid,
            status: session.monitorState,
            assistantPreview: session.assistantPreview,
            rolloutPath: session.rolloutPath
        )
    }

    private func liveSamples(forTurnKey turnKey: String, threadID: String) -> [LiveTurnSample] {
        guard liveTelemetry.sampleBuckets(forThreadID: threadID)[turnKey] != nil else {
            return []
        }
        return liveTelemetry.samples(forTurnKey: turnKey)
    }

    private func timelineDateAscending(_ left: CompletedSession, _ right: CompletedSession) -> Bool {
        let leftDate = left.completedAt ?? left.startedAt ?? .distantPast
        let rightDate = right.completedAt ?? right.startedAt ?? .distantPast
        if leftDate != rightDate {
            return leftDate < rightDate
        }
        return left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending
    }

    private func turnDetailNewestFirst(_ left: TurnDetailItem, _ right: TurnDetailItem) -> Bool {
        let leftDate = left.completedAt ?? left.startedAt ?? .distantPast
        let rightDate = right.completedAt ?? right.startedAt ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending
    }
}
