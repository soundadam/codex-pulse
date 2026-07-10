import AppKit
import Core
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    let suspiciousModulo: Int
    let refreshInterval: Duration
    let timelinePointLimit: Int
    let threadFetchLimit: Int
    let timelineLookbackSeconds: TimeInterval
    let cwdFilters: [String]
    let liveSampleMinimumInterval: TimeInterval
    let liveSampleReasoningStep: Int

    var searchQuery = "" {
        didSet { normalizeTimelineSelection() }
    }

    private(set) var snapshot: MonitorSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var errorMessage: String?
    private(set) var dataWarningMessage: String?
    private(set) var statusTitle = "Cdx"
    private(set) var selectedTimelineWindow: TimelineWindow = .thirtyMinutes
    private(set) var selectedSessionKey: String?
    private(set) var selectedThreadID: String?

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
    private var consecutiveRefreshFailures = 0
    private var latestThreadsByID: [String: CodexThreadRef] = [:]
    private var liveTelemetry: LiveTelemetryStore

    public convenience init() {
        let launchConfiguration = AppServerLaunchConfiguration.codexAppServer()
        let discoveryClient = AppServerClient(
            launchConfiguration: launchConfiguration,
            requestTimeout: .seconds(15),
            timeoutFailureThreshold: 2
        )
        let realtimeClient = AppServerClient(
            launchConfiguration: launchConfiguration,
            requestTimeout: .seconds(15),
            timeoutFailureThreshold: 2
        )
        self.init(
            discoveryService: discoveryClient,
            realtimeService: realtimeClient,
            rolloutParser: RolloutParser(),
            notificationSender: SystemNotificationSender(),
            notificationStore: UserDefaultsNotificationStateStore()
        )
    }

    init(
        discoveryService: any ThreadDiscoveryService = AppServerClient(),
        realtimeService: (any ThreadRealtimeSubscribing)? = nil,
        rolloutParser: RolloutParser = RolloutParser(),
        notificationSender: any NotificationSending = SystemNotificationSender(),
        notificationStore: any NotificationStatePersisting = UserDefaultsNotificationStateStore(),
        suspiciousModulo: Int = 516,
        refreshInterval: Duration = .seconds(3),
        timelinePointLimit: Int = 240,
        threadFetchLimit: Int = 40,
        timelineLookbackSeconds: TimeInterval = 3_600,
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
        self.timelinePointLimit = max(1, timelinePointLimit)
        self.threadFetchLimit = max(1, threadFetchLimit)
        self.timelineLookbackSeconds = timelineLookbackSeconds
        self.liveSampleMinimumInterval = liveSampleMinimumInterval
        self.liveSampleReasoningStep = liveSampleReasoningStep
        self.cwdFilters = cwdFilters
        self.nowProvider = nowProvider
        self.realtimeService = realtimeService ?? (discoveryService as? any ThreadRealtimeSubscribing)
        self.liveTelemetry = LiveTelemetryStore(
            configuration: LiveTelemetryConfiguration(
                suspiciousModulo: suspiciousModulo,
                lookbackSeconds: timelineLookbackSeconds,
                overviewSampleMinimumInterval: liveSampleMinimumInterval,
                overviewSampleReasoningStep: liveSampleReasoningStep,
                overviewSessionLimit: 120
            )
        )
        self.notificationState = NotificationPolicyState(
            notifiedTurnTimestamps: notificationStore.loadNotifiedTurnTimestamps()
        )
        updateStatusTitle()
    }

    var timelineSeries: [ThreadTimelineSeries] {
        TimelinePresentationBuilder.build(
            sessions: retainedTimelineSessions,
            searchQuery: searchQuery,
            window: selectedTimelineWindow,
            now: nowProvider(),
            pointLimit: timelinePointLimit
        )
    }

    var timelinePoints: [TimelinePoint] {
        timelineSeries
            .flatMap(\.points)
            .sorted(by: timelinePointDateAscending)
    }

    var recentReasoningSessions: [CompletedSession] {
        timelinePoints.map(\.session)
    }

    var selectedTimelinePoint: TimelinePoint? {
        guard let selectedSessionKey else {
            return nil
        }
        return timelinePoints.first(where: { $0.id == selectedSessionKey })
    }

    var selectedCompletedSession: CompletedSession? {
        selectedTimelinePoint?.session
    }

    var selectedThreadSeries: ThreadTimelineSeries? {
        guard let selectedThreadID else {
            return nil
        }
        return timelineSeries.first(where: { $0.threadID == selectedThreadID })
    }

    var invalidTimelineTurnCount: Int {
        timelinePoints.filter { $0.session.signalState == .invalid }.count
    }

    var runningThreadCount: Int {
        snapshot?.runningCount ?? 0
    }

    var observedTimelineTurnCount: Int {
        timelinePoints.filter { $0.session.signalState == .valid }.count
    }

    var unknownTimelineTurnCount: Int {
        timelinePoints.filter { $0.session.signalState == .unknown }.count
    }

    var selectedTimelineTurnDetail: TurnDetailItem? {
        selectedCompletedSession.map(turnDetail(from:))
    }

    var selectedTimelineTurnSamples: [LiveTurnSample] {
        guard let turnKey = selectedCompletedSession?.turnKey else {
            return []
        }
        return liveTelemetry.samples(forTurnKey: turnKey)
    }

    var errorBannerMessage: String? {
        if let errorMessage, errorMessage.isEmpty == false {
            return errorMessage
        }
        return dataWarningMessage
    }

    var timelineDomain: ClosedRange<Date> {
        let upper = nowProvider()
        return upper.addingTimeInterval(-selectedTimelineWindow.duration)...upper
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
        let realtimeService = self.realtimeService
        let realtimeClient = realtimeService as? AppServerClient
        let discoveryClient = discoveryService as? AppServerClient
        Task {
            if let realtimeService {
                await realtimeService.syncSubscriptions(threadIDs: [])
            }
            if let realtimeClient {
                await realtimeClient.shutdown()
            }
            if let discoveryClient {
                await discoveryClient.shutdown()
            }
        }
    }

    func refreshNow() {
        Task { await performRefresh() }
    }

    func setTimelineWindow(_ window: TimelineWindow) {
        selectedTimelineWindow = window
        normalizeTimelineSelection()
        updateStatusTitle()
    }

    func selectTimelinePoint(_ pointID: String) {
        guard let point = timelinePoints.first(where: { $0.id == pointID }) else {
            return
        }
        selectedSessionKey = point.id
        selectedThreadID = point.threadID
        syncRealtimeSubscriptionsIfPossible()
    }

    func selectSession(_ key: String?) {
        guard let key else {
            selectedSessionKey = nil
            return
        }
        selectTimelinePoint(key)
    }

    func selectThreadLine(_ threadID: String) {
        guard timelineSeries.contains(where: { $0.threadID == threadID }) else {
            return
        }
        selectedThreadID = threadID
        selectedSessionKey = nil
        syncRealtimeSubscriptionsIfPossible()
    }

    func resetTimelineFocus() {
        selectedSessionKey = nil
        selectedThreadID = nil
        syncRealtimeSubscriptionsIfPossible()
    }

    func moveSelection(offset: Int) {
        let points: [TimelinePoint]
        if let selectedThreadSeries {
            points = selectedThreadSeries.points
        } else {
            points = timelinePoints
        }

        guard points.isEmpty == false else {
            selectedSessionKey = nil
            return
        }

        guard let selectedSessionKey,
              let currentIndex = points.firstIndex(where: { $0.id == selectedSessionKey }) else {
            selectTimelinePoint(points.last!.id)
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), points.count - 1)
        selectTimelinePoint(points[nextIndex].id)
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
            lastRefreshAt = nowProvider()
        }

        do {
            let refresh = try await snapshotRepository.refresh(
                threadLimit: threadFetchLimit,
                cwdFilters: cwdFilters,
                suspiciousModulo: suspiciousModulo
            )
            let snapshot = refresh.snapshot

            self.snapshot = snapshot
            self.latestThreadsByID = Dictionary(
                uniqueKeysWithValues: refresh.discoveredThreads.map { ($0.id, $0) }
            )
            reconcileCompletedTurns(with: snapshot)
            consecutiveRefreshFailures = 0
            self.errorMessage = nil
            self.dataWarningMessage = refresh.skippedRolloutCount > 0
                ? "Could not read \(refresh.skippedRolloutCount) rollout \(refresh.skippedRolloutCount == 1 ? "file" : "files"). Live data is still available."
                : nil
            normalizeTimelineSelection()
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
            consecutiveRefreshFailures += 1
            if snapshot == nil || consecutiveRefreshFailures >= 2 {
                errorMessage = error.localizedDescription
            }
            dataWarningMessage = nil
            normalizeTimelineSelection()
            updateStatusTitle()
        }
    }

    private func normalizeTimelineSelection() {
        let series = timelineSeries
        let visibleThreadIDs = Set(series.map(\.threadID))

        if let selectedThreadID, visibleThreadIDs.contains(selectedThreadID) == false {
            self.selectedThreadID = nil
            selectedSessionKey = nil
            return
        }

        if let selectedSessionKey {
            guard let point = series.flatMap(\.points).first(where: { $0.id == selectedSessionKey }) else {
                self.selectedSessionKey = nil
                return
            }
            selectedThreadID = point.threadID
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
            normalizeTimelineSelection()
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

    private var retainedTimelineSessions: [CompletedSession] {
        (retainedCompletedSessions + retainedLiveSessions)
            .sorted(by: timelineSessionDateAscending)
    }

    private var retainedCompletedSessions: [CompletedSession] {
        guard let snapshot else {
            return []
        }

        let cutoff = nowProvider().addingTimeInterval(-timelineLookbackSeconds)
        return snapshot.completedSessions
            .filter { ($0.completedAt ?? $0.startedAt ?? .distantPast) >= cutoff }
            .map(liveTelemetry.applyingSignal(to:))
            .map(attachingRetainedLiveSamples(to:))
    }

    private var retainedLiveSessions: [CompletedSession] {
        liveTelemetry.visibleOverviewSessions(referenceDate: nowProvider())
            .map(attachingRetainedLiveSamples(to:))
    }

    private func attachingRetainedLiveSamples(to session: CompletedSession) -> CompletedSession {
        guard let turnKey = session.turnKey else {
            return session
        }

        let liveSamples = liveTelemetry.samples(forTurnKey: turnKey).map {
            TurnReasoningSample(observedAt: $0.observedAt, tokenUsage: $0.tokenUsage)
        }
        guard liveSamples.isEmpty == false else {
            return session
        }

        let merged = (session.reasoningSamples + liveSamples)
            .reduce(into: [String: TurnReasoningSample]()) { result, sample in
                result[sample.id] = sample
            }
            .values
            .sorted { left, right in
                if left.observedAt != right.observedAt {
                    return left.observedAt < right.observedAt
                }
                return left.id < right.id
            }
        return session.withReasoningSamples(merged)
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

    private func timelineSessionDateAscending(_ left: CompletedSession, _ right: CompletedSession) -> Bool {
        let leftDate = left.completedAt ?? left.startedAt ?? .distantPast
        let rightDate = right.completedAt ?? right.startedAt ?? .distantPast
        if leftDate != rightDate {
            return leftDate < rightDate
        }
        return left.key < right.key
    }

    private func timelinePointDateAscending(_ left: TimelinePoint, _ right: TimelinePoint) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp < right.timestamp
        }
        return left.id < right.id
    }
}
