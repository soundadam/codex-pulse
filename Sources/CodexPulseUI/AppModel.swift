import AppKit
import Core
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    let suspiciousModulo: Int
    let refreshInterval: Duration
    let backgroundRefreshInterval: Duration
    let timelinePointLimit: Int
    let threadFetchLimit: Int
    let timelineLookbackSeconds: TimeInterval
    let cwdFilters: [String]

    private(set) var snapshot: MonitorSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var errorMessage: String?
    private(set) var dataWarningMessage: String?
    private(set) var statusTitle = "Cdx"
    private(set) var selectedTimelineWindow: TimelineWindow = .oneHour
    private(set) var selectedSessionKey: String?
    private(set) var selectedThreadID: String?
    private(set) var selectedTurnReasoningSamples: [TurnReasoningSample] = []
    private(set) var isLoadingSelectedTurnDetails = false
    private(set) var isPopoverVisible = false
    private(set) var timelinePresentation: TimelinePresentation
    private(set) var timelinePresentationRevision = 0

    var onStatusTitleChange: ((String) -> Void)?

    private let discoveryService: any ThreadDiscoveryService
    private let snapshotRepository: MonitorSnapshotRepository
    private let notificationSender: any NotificationSending
    private let notificationStore: any NotificationStatePersisting
    private let nowProvider: @Sendable () -> Date
    private let realtimeService: (any ThreadRealtimeSubscribing)?
    private let turnDetailCache: TurnDetailCache

    @ObservationIgnored private var refreshLoopTask: Task<Void, Never>?
    @ObservationIgnored private var detailLoadTask: Task<Void, Never>?
    @ObservationIgnored private var windowRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var presentationUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    private var notificationState: NotificationPolicyState
    private var hasBoundRealtimeService = false
    private var consecutiveRefreshFailures = 0
    private var latestThreadsByID: [String: CodexThreadRef] = [:]
    private var liveTelemetry: LiveTelemetryStore
    private var lastRequestedSubscriptionIDs: [String]?

    public convenience init() {
        let launchConfiguration = AppServerLaunchConfiguration.codexAppServer()
        let appServerClient = AppServerClient(
            launchConfiguration: launchConfiguration,
            requestTimeout: .seconds(15),
            timeoutFailureThreshold: 2
        )
        let turnDetailCache = TurnDetailCache(
            directoryURL: TurnDetailCache.defaultDirectoryURL()
        )
        self.init(
            discoveryService: appServerClient,
            realtimeService: appServerClient,
            rolloutParser: RolloutParser(),
            turnDetailCache: turnDetailCache,
            notificationSender: SystemNotificationSender(),
            notificationStore: UserDefaultsNotificationStateStore()
        )
    }

    init(
        discoveryService: any ThreadDiscoveryService = AppServerClient(),
        realtimeService: (any ThreadRealtimeSubscribing)? = nil,
        rolloutParser: RolloutParser = RolloutParser(),
        turnDetailCache: TurnDetailCache = TurnDetailCache(),
        notificationSender: any NotificationSending = SystemNotificationSender(),
        notificationStore: any NotificationStatePersisting = UserDefaultsNotificationStateStore(),
        suspiciousModulo: Int = 516,
        refreshInterval: Duration = .seconds(3),
        backgroundRefreshInterval: Duration = .seconds(15),
        timelinePointLimit: Int = 240,
        threadFetchLimit: Int = 40,
        timelineLookbackSeconds: TimeInterval = 3_600,
        cwdFilters: [String] = [],
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.discoveryService = discoveryService
        self.snapshotRepository = MonitorSnapshotRepository(
            discoveryService: discoveryService,
            rolloutParser: rolloutParser,
            turnDetailCache: turnDetailCache
        )
        self.notificationSender = notificationSender
        self.notificationStore = notificationStore
        self.suspiciousModulo = suspiciousModulo
        self.refreshInterval = refreshInterval
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.timelinePointLimit = max(1, timelinePointLimit)
        self.threadFetchLimit = max(1, threadFetchLimit)
        self.timelineLookbackSeconds = timelineLookbackSeconds
        self.cwdFilters = cwdFilters
        self.nowProvider = nowProvider
        self.realtimeService = realtimeService ?? (discoveryService as? any ThreadRealtimeSubscribing)
        self.turnDetailCache = turnDetailCache
        self.timelinePresentation = TimelinePresentation.empty(
            window: .oneHour,
            referenceDate: nowProvider()
        )
        self.liveTelemetry = LiveTelemetryStore(
            configuration: LiveTelemetryConfiguration(
                suspiciousModulo: suspiciousModulo,
                lookbackSeconds: timelineLookbackSeconds,
                overviewSessionLimit: 120
            )
        )
        self.notificationState = NotificationPolicyState(
            notifiedTurnTimestamps: notificationStore.loadNotifiedTurnTimestamps()
        )
        updateStatusTitle()
    }

    var timelineSeries: [ThreadTimelineSeries] { timelinePresentation.series }

    var timelinePoints: [TimelinePoint] { timelinePresentation.points }

    var recentReasoningSessions: [CompletedSession] {
        timelinePoints.map(\.session)
    }

    var selectedTimelinePoint: TimelinePoint? {
        guard let selectedSessionKey else {
            return nil
        }
        return timelinePresentation.pointsByID[selectedSessionKey]
    }

    var selectedCompletedSession: CompletedSession? {
        selectedTimelinePoint?.session
    }

    var selectedThreadSeries: ThreadTimelineSeries? {
        guard let selectedThreadID else {
            return nil
        }
        return timelinePresentation.seriesByThreadID[selectedThreadID]
    }

    var invalidTimelineTurnCount: Int {
        timelinePresentation.invalidTurnCount
    }

    var runningThreadCount: Int {
        snapshot?.runningCount ?? 0
    }

    var observedTimelineTurnCount: Int {
        timelinePresentation.observedTurnCount
    }

    var unknownTimelineTurnCount: Int {
        timelinePresentation.unknownTurnCount
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
        timelinePresentation.dateDomain
    }

    public func start() {
        guard refreshLoopTask == nil else {
            return
        }

        Task { await notificationSender.requestAuthorization() }
        bindRealtimeServiceIfNeeded()
        requestRefresh(indicateActivity: isPopoverVisible)

        refreshLoopTask = Task { [weak self] in
            while let self, Task.isCancelled == false {
                let interval = self.isPopoverVisible
                    ? self.refreshInterval
                    : self.backgroundRefreshInterval
                try? await Task.sleep(for: interval)
                if Task.isCancelled {
                    break
                }
                await self.performRefresh(indicateActivity: false)
            }
        }
    }

    public func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        detailLoadTask?.cancel()
        detailLoadTask = nil
        windowRefreshTask?.cancel()
        windowRefreshTask = nil
        presentationUpdateTask?.cancel()
        presentationUpdateTask = nil
        lastRequestedSubscriptionIDs = nil
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
            if let discoveryClient,
               realtimeClient == nil || discoveryClient !== realtimeClient {
                await discoveryClient.shutdown()
            }
        }
    }

    func refreshNow() {
        requestRefresh(indicateActivity: true)
    }

    func setPopoverVisible(_ isVisible: Bool) {
        guard isPopoverVisible != isVisible else {
            return
        }

        isPopoverVisible = isVisible
        if isVisible {
            rebuildTimelinePresentation(force: true)
            if let selectedTimelinePoint {
                loadSelectedTurnDetails(for: selectedTimelinePoint)
            }
            requestRefresh(indicateActivity: true)
        } else {
            clearSelectedTurnDetails()
        }
        syncRealtimeSubscriptionsIfPossible()
    }

    func setTimelineWindow(_ window: TimelineWindow) {
        guard selectedTimelineWindow != window else {
            return
        }
        selectedTimelineWindow = window
        rebuildTimelinePresentation(force: true)
        updateStatusTitle()
        windowRefreshTask?.cancel()
        windowRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard Task.isCancelled == false else {
                return
            }
            await self?.performRefresh(indicateActivity: false)
        }
    }

    func selectTimelinePoint(_ pointID: String) {
        guard let point = timelinePresentation.pointsByID[pointID] else {
            return
        }
        selectedSessionKey = point.id
        selectedThreadID = point.threadID
        loadSelectedTurnDetails(for: point)
        syncRealtimeSubscriptionsIfPossible()
    }

    func selectSession(_ key: String?) {
        guard let key else {
            selectedSessionKey = nil
            clearSelectedTurnDetails()
            return
        }
        selectTimelinePoint(key)
    }

    func selectThreadLine(_ threadID: String) {
        guard timelinePresentation.seriesByThreadID[threadID] != nil else {
            return
        }
        selectedThreadID = threadID
        selectedSessionKey = nil
        clearSelectedTurnDetails()
        syncRealtimeSubscriptionsIfPossible()
    }

    func resetTimelineFocus() {
        selectedSessionKey = nil
        selectedThreadID = nil
        clearSelectedTurnDetails()
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
            clearSelectedTurnDetails()
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

    private func requestRefresh(indicateActivity: Bool) {
        Task { [weak self] in
            await self?.performRefresh(indicateActivity: indicateActivity)
        }
    }

    private func performRefresh(indicateActivity: Bool) async {
        guard refreshInFlight == false else {
            return
        }

        refreshInFlight = true
        if indicateActivity {
            isRefreshing = true
        }
        defer {
            refreshInFlight = false
            if indicateActivity {
                isRefreshing = false
            }
            recordRefreshCompletion(at: nowProvider())
        }

        do {
            let refresh = try await snapshotRepository.refresh(
                threadLimit: min(240, threadFetchLimit * selectedTimelineWindow.fetchMultiplier),
                cwdFilters: cwdFilters,
                suspiciousModulo: suspiciousModulo,
                detailCutoff: nowProvider().addingTimeInterval(-selectedTimelineWindow.duration)
            )
            let snapshot = refresh.snapshot
            let snapshotChanged = self.snapshot.map {
                snapshotsHaveEquivalentContent($0, snapshot) == false
            } ?? true
            let nextThreadsByID = Dictionary(
                uniqueKeysWithValues: refresh.discoveredThreads.map { ($0.id, $0) }
            )

            if snapshotChanged {
                self.snapshot = snapshot
            }
            if latestThreadsByID != nextThreadsByID {
                latestThreadsByID = nextThreadsByID
            }
            reconcileCompletedTurns(with: snapshot)
            consecutiveRefreshFailures = 0
            if errorMessage != nil {
                errorMessage = nil
            }
            let nextWarning = refresh.skippedRolloutCount > 0
                ? "Could not read \(refresh.skippedRolloutCount) rollout \(refresh.skippedRolloutCount == 1 ? "file" : "files"). Live data is still available."
                : nil
            if dataWarningMessage != nextWarning {
                dataWarningMessage = nextWarning
            }
            rebuildTimelinePresentation(force: snapshotChanged)
            if snapshotChanged, isPopoverVisible, let selectedTimelinePoint {
                loadSelectedTurnDetails(for: selectedTimelinePoint)
            }
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
                let message = error.localizedDescription
                if errorMessage != message {
                    errorMessage = message
                }
            }
            if dataWarningMessage != nil {
                dataWarningMessage = nil
            }
            rebuildTimelinePresentation(force: false)
            updateStatusTitle()
        }
    }

    private func rebuildTimelinePresentation(force: Bool) {
        let referenceDate = nowProvider()
        let nextUpperBound = TimelinePresentationBuilder.alignedUpperBound(for: referenceDate)
        guard force || timelinePresentation.dateDomain.upperBound != nextUpperBound else {
            return
        }

        let nextPresentation = TimelinePresentationBuilder.makePresentation(
            sessions: retainedTimelineSessions(referenceDate: referenceDate),
            searchQuery: "",
            window: selectedTimelineWindow,
            now: referenceDate,
            pointLimit: timelinePointLimit
        )
        guard timelinePresentation != nextPresentation else {
            return
        }

        timelinePresentation = nextPresentation
        timelinePresentationRevision += 1
        normalizeTimelineSelection()

        if isPopoverVisible,
           let selectedTimelinePoint,
           selectedTimelinePoint.session.reasoningSamples.isEmpty == false {
            selectedTurnReasoningSamples = mergeReasoningSamples(
                selectedTurnReasoningSamples + selectedTimelinePoint.session.reasoningSamples
            )
        }
    }

    private func recordRefreshCompletion(at date: Date) {
        let minute = Int(date.timeIntervalSinceReferenceDate / 60)
        let previousMinute = lastRefreshAt.map {
            Int($0.timeIntervalSinceReferenceDate / 60)
        }
        if previousMinute != minute {
            lastRefreshAt = date
        }
    }

    private func snapshotsHaveEquivalentContent(
        _ left: MonitorSnapshot,
        _ right: MonitorSnapshot
    ) -> Bool {
        left.suspiciousModulo == right.suspiciousModulo
            && left.threads == right.threads
            && left.projectCards == right.projectCards
            && left.completedSessions == right.completedSessions
            && left.threadTurnGroups == right.threadTurnGroups
    }

    private func normalizeTimelineSelection() {
        if let selectedThreadID,
           timelinePresentation.seriesByThreadID[selectedThreadID] == nil {
            self.selectedThreadID = nil
            selectedSessionKey = nil
            clearSelectedTurnDetails()
            return
        }

        if let selectedSessionKey {
            guard let point = timelinePresentation.pointsByID[selectedSessionKey] else {
                self.selectedSessionKey = nil
                clearSelectedTurnDetails()
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
        guard statusTitle != nextTitle else {
            return
        }
        statusTitle = nextTitle
        onStatusTitleChange?(nextTitle)
    }

    private func loadSelectedTurnDetails(for point: TimelinePoint) {
        detailLoadTask?.cancel()
        selectedTurnReasoningSamples = point.session.reasoningSamples
        guard let turnKey = point.session.turnKey else {
            isLoadingSelectedTurnDetails = false
            return
        }

        isLoadingSelectedTurnDetails = true
        detailLoadTask = Task { [weak self] in
            guard let self else {
                return
            }
            let cachedSamples = await turnDetailCache.loadReasoningSamples(for: turnKey)
            guard Task.isCancelled == false, selectedSessionKey == point.id else {
                return
            }
            let liveSamples = selectedTimelinePoint?.session.reasoningSamples ?? []
            selectedTurnReasoningSamples = mergeReasoningSamples(cachedSamples + liveSamples)
            isLoadingSelectedTurnDetails = false
        }
    }

    private func clearSelectedTurnDetails() {
        detailLoadTask?.cancel()
        detailLoadTask = nil
        selectedTurnReasoningSamples = []
        isLoadingSelectedTurnDetails = false
    }

    private func mergeReasoningSamples(
        _ samples: [TurnReasoningSample]
    ) -> [TurnReasoningSample] {
        samples
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
            if isPopoverVisible {
                scheduleTimelinePresentationRebuild()
            } else {
                rebuildTimelinePresentation(force: true)
                updateStatusTitle()
            }
        case .turnCompleted:
            requestRefresh(indicateActivity: false)
        }
    }

    private func scheduleTimelinePresentationRebuild() {
        guard presentationUpdateTask == nil else {
            return
        }

        presentationUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, Task.isCancelled == false else {
                return
            }
            presentationUpdateTask = nil
            rebuildTimelinePresentation(force: true)
            updateStatusTitle()
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
        guard lastRequestedSubscriptionIDs != subscriptionIDs else {
            return
        }
        lastRequestedSubscriptionIDs = subscriptionIDs
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

        if selectedThreadIDs.isEmpty,
           let fallback = snapshot.threads.first?.id {
            selectedThreadIDs.insert(fallback)
        }

        return snapshot.threads.map(\.id).filter { selectedThreadIDs.contains($0) }
    }

    private func retainedTimelineSessions(referenceDate: Date) -> [CompletedSession] {
        (retainedCompletedSessions(referenceDate: referenceDate)
            + retainedLiveSessions(referenceDate: referenceDate))
            .sorted(by: timelineSessionDateAscending)
    }

    private func retainedCompletedSessions(referenceDate: Date) -> [CompletedSession] {
        guard let snapshot else {
            return []
        }

        let retentionSeconds = max(timelineLookbackSeconds, selectedTimelineWindow.duration)
        let cutoff = referenceDate.addingTimeInterval(-retentionSeconds)
        return snapshot.completedSessions
            .filter { ($0.completedAt ?? $0.startedAt ?? .distantPast) >= cutoff }
            .map(liveTelemetry.applyingSignal(to:))
            .map(attachingRetainedLiveSamples(to:))
    }

    private func retainedLiveSessions(referenceDate: Date) -> [CompletedSession] {
        liveTelemetry.visibleOverviewSessions(referenceDate: referenceDate)
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

}
