import Foundation

public struct LiveTelemetryConfiguration: Sendable, Equatable {
    public let suspiciousModulo: Int
    public let lookbackSeconds: TimeInterval
    public let overviewSampleMinimumInterval: TimeInterval
    public let overviewSampleReasoningStep: Int
    public let overviewSessionLimit: Int
    public let sampleLimitPerTurn: Int

    public init(
        suspiciousModulo: Int = 516,
        lookbackSeconds: TimeInterval = 3_600,
        overviewSampleMinimumInterval: TimeInterval = 2,
        overviewSampleReasoningStep: Int = 128,
        overviewSessionLimit: Int = 30,
        sampleLimitPerTurn: Int = 240
    ) {
        self.suspiciousModulo = suspiciousModulo
        self.lookbackSeconds = lookbackSeconds
        self.overviewSampleMinimumInterval = overviewSampleMinimumInterval
        self.overviewSampleReasoningStep = overviewSampleReasoningStep
        self.overviewSessionLimit = max(1, overviewSessionLimit)
        self.sampleLimitPerTurn = max(1, sampleLimitPerTurn)
    }
}

public struct LiveSessionContext: Sendable, Equatable {
    public let projectName: String
    public let projectSubtitle: String
    public let threadTitle: String
    public let source: String?
    public let rolloutPath: String?
    public let startedAt: Date?
    public let model: String?
    public let reasoningEffort: String?
    public let assistantPreview: String?

    public init(
        projectName: String,
        projectSubtitle: String,
        threadTitle: String,
        source: String?,
        rolloutPath: String?,
        startedAt: Date?,
        model: String?,
        reasoningEffort: String?,
        assistantPreview: String?
    ) {
        self.projectName = projectName
        self.projectSubtitle = projectSubtitle
        self.threadTitle = threadTitle
        self.source = source
        self.rolloutPath = rolloutPath
        self.startedAt = startedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.assistantPreview = assistantPreview
    }
}

public enum ReasoningSignalRule {
    public static func hitsInvalidSignal(
        _ tokenUsage: TurnTokenUsageSnapshot,
        suspiciousModulo: Int
    ) -> Bool {
        let values = [
            tokenUsage.last.reasoningOutputTokens,
            tokenUsage.total.reasoningOutputTokens,
        ]

        if values.contains(0) {
            return true
        }

        guard suspiciousModulo > 0 else {
            return false
        }
        return values.contains { value in
            value > 0 && value.isMultiple(of: suspiciousModulo)
        }
    }
}

/// A bounded, deterministic store for realtime signal state and sample history.
/// It retains full samples for every subscribed thread, not only the selected one.
public struct LiveTelemetryStore: Sendable {
    public let configuration: LiveTelemetryConfiguration

    private var overviewSessions: [CompletedSession] = []
    private var observedTurnKeys: Set<String> = []
    private var invalidTurnKeys: Set<String> = []
    private var samplesByTurnKey: [String: [LiveTurnSample]] = [:]

    public init(configuration: LiveTelemetryConfiguration) {
        self.configuration = configuration
    }

    public mutating func ingest(
        _ update: ThreadTokenUsageUpdate,
        context: LiveSessionContext,
        referenceDate: Date
    ) {
        let turnKey = Self.turnKey(threadID: update.threadId, turnID: update.turnId)
        observedTurnKeys.insert(turnKey)
        if ReasoningSignalRule.hitsInvalidSignal(
            update.tokenUsage,
            suspiciousModulo: configuration.suspiciousModulo
        ) {
            invalidTurnKeys.insert(turnKey)
        }

        let signalState = signalState(for: turnKey)
        let sample = LiveTurnSample(
            threadId: update.threadId,
            turnId: update.turnId,
            observedAt: update.observedAt,
            tokenUsage: update.tokenUsage,
            modelContextWindow: update.modelContextWindow,
            hitInvalidSignal: signalState == .invalid
        )
        samplesByTurnKey[turnKey, default: []].append(sample)

        appendOverviewSession(
            CompletedSession(
                key: "live:\(update.threadId):\(update.turnId):\(Int(update.observedAt.timeIntervalSince1970 * 1_000))",
                threadId: update.threadId,
                turnId: update.turnId,
                projectName: context.projectName,
                subtitle: context.projectSubtitle,
                threadTitle: context.threadTitle,
                source: context.source,
                rolloutPath: context.rolloutPath,
                startedAt: context.startedAt,
                completedAt: update.observedAt,
                model: context.model,
                reasoningEffort: context.reasoningEffort,
                usage: update.tokenUsage.total,
                tokenUsage: update.tokenUsage,
                monitorState: signalState == .invalid ? .suspicious : .running,
                signalState: signalState,
                assistantPreview: context.assistantPreview,
                reasoningSamples: [
                    TurnReasoningSample(
                        observedAt: update.observedAt,
                        tokenUsage: update.tokenUsage
                    )
                ]
            )
        )

        prune(referenceDate: referenceDate)
    }

    public mutating func reconcile(completedSessions: [CompletedSession]) {
        let completedKeys = Set(completedSessions.compactMap(\.turnKey))
        guard completedKeys.isEmpty == false else {
            return
        }
        overviewSessions.removeAll { session in
            session.turnKey.map(completedKeys.contains) ?? false
        }
    }

    public mutating func prune(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-configuration.lookbackSeconds)
        overviewSessions.removeAll {
            ($0.completedAt ?? $0.startedAt ?? .distantPast) < cutoff
        }
        if overviewSessions.count > configuration.overviewSessionLimit {
            overviewSessions = Array(overviewSessions.suffix(configuration.overviewSessionLimit))
        }

        samplesByTurnKey = samplesByTurnKey.reduce(into: [:]) { result, entry in
            let samples = entry.value
                .filter { $0.observedAt >= cutoff }
                .sorted(by: Self.sampleDateAscending)
            guard samples.isEmpty == false else {
                return
            }
            result[entry.key] = Array(samples.suffix(configuration.sampleLimitPerTurn))
        }

        let retainedKeys = Set(samplesByTurnKey.keys).union(overviewSessions.compactMap(\.turnKey))
        observedTurnKeys.formIntersection(retainedKeys)
        invalidTurnKeys.formIntersection(retainedKeys)
    }

    public func visibleOverviewSessions(referenceDate: Date) -> [CompletedSession] {
        let cutoff = referenceDate.addingTimeInterval(-configuration.lookbackSeconds)
        return overviewSessions.filter {
            ($0.completedAt ?? $0.startedAt ?? .distantPast) >= cutoff
        }
    }

    public func signalState(for turnKey: String?) -> TurnSignalState {
        guard let turnKey else {
            return .unknown
        }
        if invalidTurnKeys.contains(turnKey) {
            return .invalid
        }
        if observedTurnKeys.contains(turnKey) {
            return .valid
        }
        return .unknown
    }

    public func applyingSignal(to session: CompletedSession) -> CompletedSession {
        session.withSignalState(signalState(for: session.turnKey))
    }

    public func applyingSignal(to item: TurnDetailItem) -> TurnDetailItem {
        switch signalState(for: item.key) {
        case .invalid:
            return item.withSignal(hadInvalidSignal: true, status: .suspicious)
        case .valid:
            return item.withSignal(hadInvalidSignal: false, status: .normal)
        case .unknown:
            return item.withSignal(hadInvalidSignal: false, status: .unknown)
        }
    }

    public func samples(forTurnKey turnKey: String) -> [LiveTurnSample] {
        (samplesByTurnKey[turnKey] ?? []).sorted(by: Self.sampleDateAscending)
    }

    public func sampleBuckets(forThreadID threadID: String) -> [String: [LiveTurnSample]] {
        samplesByTurnKey.reduce(into: [:]) { result, entry in
            guard entry.value.first?.threadId == threadID else {
                return
            }
            result[entry.key] = entry.value.sorted(by: Self.sampleDateAscending)
        }
    }

    public func latestObservedAt(forTurnKey turnKey: String) -> Date? {
        samplesByTurnKey[turnKey]?.map(\.observedAt).max()
    }

    public func hasActivity(threadID: String, since cutoff: Date) -> Bool {
        samplesByTurnKey.values.contains { samples in
            samples.contains { $0.threadId == threadID && $0.observedAt >= cutoff }
        }
    }

    private mutating func appendOverviewSession(_ next: CompletedSession) {
        if let index = overviewSessions.lastIndex(where: {
            $0.threadId == next.threadId && $0.turnId == next.turnId
        }) {
            let previous = overviewSessions.remove(at: index)
            if shouldKeep(previous: previous, before: next) {
                overviewSessions.append(previous)
            }
        }
        overviewSessions.append(next)
    }

    private func shouldKeep(previous: CompletedSession, before next: CompletedSession) -> Bool {
        if previous.isInvalidReasoning != next.isInvalidReasoning {
            return true
        }

        let previousTime = previous.completedAt ?? previous.startedAt ?? .distantPast
        let nextTime = next.completedAt ?? next.startedAt ?? .distantPast
        if nextTime.timeIntervalSince(previousTime) >= configuration.overviewSampleMinimumInterval {
            return true
        }

        let lastDelta = abs(
            next.tokenUsage.last.reasoningOutputTokens
                - previous.tokenUsage.last.reasoningOutputTokens
        )
        let totalDelta = abs(
            next.tokenUsage.total.reasoningOutputTokens
                - previous.tokenUsage.total.reasoningOutputTokens
        )
        return max(lastDelta, totalDelta) >= configuration.overviewSampleReasoningStep
    }

    private static func turnKey(threadID: String, turnID: String) -> String {
        "\(threadID):\(turnID)"
    }

    private static func sampleDateAscending(_ left: LiveTurnSample, _ right: LiveTurnSample) -> Bool {
        if left.observedAt != right.observedAt {
            return left.observedAt < right.observedAt
        }
        return left.id < right.id
    }
}
