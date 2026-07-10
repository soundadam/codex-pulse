import Foundation

public struct CodexThreadRef: Sendable, Codable, Equatable {
    public let id: String
    public let name: String?
    public let preview: String
    public let source: String?
    public let cwd: String?
    public let rolloutPath: String?
    public let updatedAt: Date?

    public init(
        id: String,
        name: String?,
        preview: String,
        source: String?,
        cwd: String?,
        rolloutPath: String?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.source = source
        self.cwd = cwd
        self.rolloutPath = rolloutPath
        self.updatedAt = updatedAt
    }
}

public struct TurnUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    public static let zero = TurnUsage()

    public mutating func add(_ other: TurnUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

public struct TurnTokenUsageSnapshot: Sendable, Codable, Equatable {
    public let last: TurnUsage
    public let total: TurnUsage

    public init(last: TurnUsage, total: TurnUsage) {
        self.last = last
        self.total = total
    }
}

public struct TurnReasoningSample: Sendable, Codable, Equatable, Identifiable {
    public let observedAt: Date
    public let tokenUsage: TurnTokenUsageSnapshot

    public init(observedAt: Date, tokenUsage: TurnTokenUsageSnapshot) {
        self.observedAt = observedAt
        self.tokenUsage = tokenUsage
    }

    public var id: String {
        "\(Int(observedAt.timeIntervalSince1970 * 1_000)):\(tokenUsage.last.reasoningOutputTokens)"
    }

    public var reasoningOutputTokens: Int {
        tokenUsage.last.reasoningOutputTokens
    }
}

public enum TurnSignalState: String, Sendable, Codable, Equatable {
    case invalid
    case valid
    case unknown
}

public struct LiveTurnSample: Sendable, Codable, Equatable, Identifiable {
    public let threadId: String
    public let turnId: String
    public let observedAt: Date
    public let tokenUsage: TurnTokenUsageSnapshot
    public let modelContextWindow: Int?
    public let hitInvalidSignal: Bool

    public init(
        threadId: String,
        turnId: String,
        observedAt: Date,
        tokenUsage: TurnTokenUsageSnapshot,
        modelContextWindow: Int?,
        hitInvalidSignal: Bool
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.observedAt = observedAt
        self.tokenUsage = tokenUsage
        self.modelContextWindow = modelContextWindow
        self.hitInvalidSignal = hitInvalidSignal
    }

    public var id: String {
        "\(threadId):\(turnId):\(Int(observedAt.timeIntervalSince1970 * 1000))"
    }
}

public enum TurnStatus: String, Sendable, Codable, Equatable {
    case running
    case completed
    case aborted
    case rolledBack = "rolled_back"
    case unknown
}

public struct LatestTurn: Sendable, Codable, Equatable {
    public let turnId: String?
    public let status: TurnStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let model: String?
    public let reasoningEffort: String?
    public let usage: TurnUsage
    public let tokenUsage: TurnTokenUsageSnapshot
    public let reasoningSamples: [TurnReasoningSample]
    public let lastAgentMessage: String?

    public init(
        turnId: String?,
        status: TurnStatus,
        startedAt: Date?,
        completedAt: Date?,
        model: String?,
        reasoningEffort: String?,
        usage: TurnUsage,
        lastAgentMessage: String?,
        tokenUsage: TurnTokenUsageSnapshot? = nil,
        reasoningSamples: [TurnReasoningSample] = []
    ) {
        self.turnId = turnId
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.usage = usage
        self.tokenUsage = tokenUsage ?? TurnTokenUsageSnapshot(last: usage, total: usage)
        self.reasoningSamples = reasoningSamples
        self.lastAgentMessage = lastAgentMessage
    }

    public var lastUsage: TurnUsage { tokenUsage.last }

    public var totalUsage: TurnUsage { tokenUsage.total }

    public func withReasoningSamples(_ reasoningSamples: [TurnReasoningSample]) -> LatestTurn {
        LatestTurn(
            turnId: turnId,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            model: model,
            reasoningEffort: reasoningEffort,
            usage: usage,
            lastAgentMessage: lastAgentMessage,
            tokenUsage: tokenUsage,
            reasoningSamples: reasoningSamples
        )
    }
}

public struct ParsedRollout: Sendable, Equatable {
    public let turns: [LatestTurn]
    public let latestTurn: LatestTurn?

    public init(turns: [LatestTurn], latestTurn: LatestTurn?) {
        self.turns = turns
        self.latestTurn = latestTurn
    }

    public func withoutReasoningSamples() -> ParsedRollout {
        let strippedTurns = turns.map { $0.withReasoningSamples([]) }
        let latestTurnID = latestTurn?.turnId
        let strippedLatest = strippedTurns.last(where: { $0.turnId == latestTurnID })
            ?? latestTurn?.withReasoningSamples([])
        return ParsedRollout(turns: strippedTurns, latestTurn: strippedLatest)
    }

    public func retainingReasoningSamples(since cutoff: Date) -> ParsedRollout {
        let filteredTurns = turns.map { turn in
            let timestamp = turn.completedAt ?? turn.startedAt ?? .distantPast
            return timestamp >= cutoff ? turn : turn.withReasoningSamples([])
        }
        let latestTurnID = latestTurn?.turnId
        let filteredLatest = filteredTurns.last(where: { $0.turnId == latestTurnID })
            ?? latestTurn?.withReasoningSamples([])
        return ParsedRollout(turns: filteredTurns, latestTurn: filteredLatest)
    }
}

public enum MonitorState: String, Sendable, Codable, Equatable {
    case running
    case normal
    case suspicious
    case aborted
    case rolledBack = "rolled_back"
    case unknown
}

public struct MonitorThread: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let preview: String
    public let source: String?
    public let cwd: String?
    public let rolloutPath: String?
    public let updatedAt: Date?
    public let latestTurn: LatestTurn?
    public let monitorState: MonitorState

    public init(
        id: String,
        name: String?,
        preview: String,
        source: String?,
        cwd: String?,
        rolloutPath: String?,
        updatedAt: Date?,
        latestTurn: LatestTurn?,
        monitorState: MonitorState
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.source = source
        self.cwd = cwd
        self.rolloutPath = rolloutPath
        self.updatedAt = updatedAt
        self.latestTurn = latestTurn
        self.monitorState = monitorState
    }

    public var threadTitle: String {
        Self.trim(name) ?? Self.trim(preview) ?? id
    }

    public var projectName: String {
        if let cwd = Self.trim(cwd) {
            return cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        return Self.trim(source) ?? "No project"
    }

    public var projectSubtitle: String {
        if let cwd = Self.trim(cwd) {
            return cwd
        }
        return Self.trim(source) ?? "No project binding"
    }

    public var latestUpdateAt: Date? {
        latestTurn?.completedAt ?? latestTurn?.startedAt ?? updatedAt
    }

    public var latestReasoningTokens: Int? {
        latestTurn?.usage.reasoningOutputTokens
    }

    public var turnKey: String? {
        guard let turnId = latestTurn?.turnId else {
            return nil
        }
        return "\(id):\(turnId)"
    }

    public func withLatestTurn(_ latestTurn: LatestTurn?) -> MonitorThread {
        MonitorThread(
            id: id,
            name: name,
            preview: preview,
            source: source,
            cwd: cwd,
            rolloutPath: rolloutPath,
            updatedAt: updatedAt,
            latestTurn: latestTurn,
            monitorState: monitorState
        )
    }

    static func trim(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct ProjectCard: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public let name: String
    public let subtitle: String
    public let latestThread: MonitorThread
    public let latestTurn: LatestTurn?
    public let monitorState: MonitorState
    public let projectThreadCount: Int
    public let olderThreadCount: Int

    public init(
        key: String,
        name: String,
        subtitle: String,
        latestThread: MonitorThread,
        latestTurn: LatestTurn?,
        monitorState: MonitorState,
        projectThreadCount: Int,
        olderThreadCount: Int
    ) {
        self.key = key
        self.name = name
        self.subtitle = subtitle
        self.latestThread = latestThread
        self.latestTurn = latestTurn
        self.monitorState = monitorState
        self.projectThreadCount = projectThreadCount
        self.olderThreadCount = olderThreadCount
    }

    public var id: String { key }

    public func matches(searchQuery: String) -> Bool {
        let trimmed = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard trimmed.isEmpty == false else {
            return true
        }

        let haystack = [
            name,
            subtitle,
            latestThread.threadTitle,
            latestTurn?.lastAgentMessage ?? "",
        ]
        .joined(separator: "\n")
        .lowercased()

        return haystack.contains(trimmed)
    }
}

public struct TurnDetailItem: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public let threadId: String
    public let turnId: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let model: String?
    public let reasoningEffort: String?
    public let lastUsage: TurnUsage
    public let totalUsage: TurnUsage
    public let hadInvalidSignal: Bool
    public let status: MonitorState
    public let assistantPreview: String?
    public let rolloutPath: String?

    public init(
        key: String,
        threadId: String,
        turnId: String?,
        startedAt: Date?,
        completedAt: Date?,
        model: String?,
        reasoningEffort: String?,
        lastUsage: TurnUsage,
        totalUsage: TurnUsage,
        hadInvalidSignal: Bool,
        status: MonitorState,
        assistantPreview: String?,
        rolloutPath: String?
    ) {
        self.key = key
        self.threadId = threadId
        self.turnId = turnId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.lastUsage = lastUsage
        self.totalUsage = totalUsage
        self.hadInvalidSignal = hadInvalidSignal
        self.status = status
        self.assistantPreview = assistantPreview
        self.rolloutPath = rolloutPath
    }

    public var id: String { key }

    public var signalState: TurnSignalState {
        if hadInvalidSignal {
            return .invalid
        }
        if status == .unknown {
            return .unknown
        }
        return .valid
    }

    public var latestAt: Date? {
        completedAt ?? startedAt
    }

    public var displayTurnID: String {
        turnId ?? "unknown-turn"
    }

    public func withSignal(hadInvalidSignal: Bool, status: MonitorState) -> TurnDetailItem {
        TurnDetailItem(
            key: key,
            threadId: threadId,
            turnId: turnId,
            startedAt: startedAt,
            completedAt: completedAt,
            model: model,
            reasoningEffort: reasoningEffort,
            lastUsage: lastUsage,
            totalUsage: totalUsage,
            hadInvalidSignal: hadInvalidSignal,
            status: status,
            assistantPreview: assistantPreview,
            rolloutPath: rolloutPath
        )
    }
}

public struct ThreadTurnGroup: Sendable, Codable, Equatable, Identifiable {
    public let threadId: String
    public let threadTitle: String
    public let projectName: String
    public let subtitle: String
    public let turns: [TurnDetailItem]

    public init(
        threadId: String,
        threadTitle: String,
        projectName: String,
        subtitle: String,
        turns: [TurnDetailItem]
    ) {
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.projectName = projectName
        self.subtitle = subtitle
        self.turns = turns
    }

    public var id: String { threadId }

    public var latestAt: Date? {
        turns.first?.latestAt
    }
}

public struct CompletedSession: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public let threadId: String
    public let turnId: String?
    public let projectName: String
    public let subtitle: String
    public let threadTitle: String
    public let source: String?
    public let rolloutPath: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let model: String?
    public let reasoningEffort: String?
    public let usage: TurnUsage
    public let tokenUsage: TurnTokenUsageSnapshot
    public let monitorState: MonitorState
    public let signalState: TurnSignalState
    public let assistantPreview: String?
    public let reasoningSamples: [TurnReasoningSample]

    public init(
        key: String,
        threadId: String,
        turnId: String?,
        projectName: String,
        subtitle: String,
        threadTitle: String,
        source: String?,
        rolloutPath: String?,
        startedAt: Date?,
        completedAt: Date?,
        model: String?,
        reasoningEffort: String?,
        usage: TurnUsage,
        tokenUsage: TurnTokenUsageSnapshot,
        monitorState: MonitorState,
        signalState: TurnSignalState = .unknown,
        assistantPreview: String?,
        reasoningSamples: [TurnReasoningSample] = []
    ) {
        self.key = key
        self.threadId = threadId
        self.turnId = turnId
        self.projectName = projectName
        self.subtitle = subtitle
        self.threadTitle = threadTitle
        self.source = source
        self.rolloutPath = rolloutPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.usage = usage
        self.tokenUsage = tokenUsage
        self.monitorState = monitorState
        self.signalState = signalState
        self.assistantPreview = assistantPreview
        self.reasoningSamples = reasoningSamples
    }

    public var id: String { key }

    public var timelineReasoningTokens: Int {
        tokenUsage.last.reasoningOutputTokens
    }

    public var isInvalidReasoning: Bool {
        signalState == .invalid
    }

    public var isKnownSignal: Bool {
        signalState != .unknown
    }

    public var turnKey: String? {
        guard let turnId else {
            return nil
        }
        return "\(threadId):\(turnId)"
    }

    public func withSignalState(_ signalState: TurnSignalState) -> CompletedSession {
        CompletedSession(
            key: key,
            threadId: threadId,
            turnId: turnId,
            projectName: projectName,
            subtitle: subtitle,
            threadTitle: threadTitle,
            source: source,
            rolloutPath: rolloutPath,
            startedAt: startedAt,
            completedAt: completedAt,
            model: model,
            reasoningEffort: reasoningEffort,
            usage: usage,
            tokenUsage: tokenUsage,
            monitorState: monitorState,
            signalState: signalState,
            assistantPreview: assistantPreview,
            reasoningSamples: reasoningSamples
        )
    }

    public func withReasoningSamples(_ reasoningSamples: [TurnReasoningSample]) -> CompletedSession {
        CompletedSession(
            key: key,
            threadId: threadId,
            turnId: turnId,
            projectName: projectName,
            subtitle: subtitle,
            threadTitle: threadTitle,
            source: source,
            rolloutPath: rolloutPath,
            startedAt: startedAt,
            completedAt: completedAt,
            model: model,
            reasoningEffort: reasoningEffort,
            usage: usage,
            tokenUsage: tokenUsage,
            monitorState: monitorState,
            signalState: signalState,
            assistantPreview: assistantPreview,
            reasoningSamples: reasoningSamples
        )
    }

    public func matches(searchQuery: String) -> Bool {
        let trimmed = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard trimmed.isEmpty == false else {
            return true
        }

        let haystack = [
            projectName,
            subtitle,
            threadTitle,
            assistantPreview ?? "",
            model ?? "",
        ]
        .joined(separator: "\n")
        .lowercased()

        return haystack.contains(trimmed)
    }
}

public struct MonitorSnapshot: Sendable, Codable, Equatable {
    public let generatedAt: Date
    public let suspiciousModulo: Int
    public let threads: [MonitorThread]
    public let projectCards: [ProjectCard]
    public let completedSessions: [CompletedSession]
    public let threadTurnGroups: [ThreadTurnGroup]

    public init(
        generatedAt: Date,
        suspiciousModulo: Int,
        threads: [MonitorThread],
        projectCards: [ProjectCard],
        completedSessions: [CompletedSession] = [],
        threadTurnGroups: [ThreadTurnGroup] = []
    ) {
        self.generatedAt = generatedAt
        self.suspiciousModulo = suspiciousModulo
        self.threads = threads
        self.projectCards = projectCards
        self.completedSessions = completedSessions
        self.threadTurnGroups = threadTurnGroups
    }

    public var suspiciousCount: Int {
        if completedSessions.isEmpty == false {
            return completedSessions.filter(\.isInvalidReasoning).count
        }
        return threads.filter { $0.monitorState == .suspicious }.count
    }

    public var runningCount: Int {
        threads.filter { $0.monitorState == .running }.count
    }
}

public struct SuspiciousCompletion: Sendable, Equatable {
    public let threadId: String
    public let turnId: String
    public let projectName: String
    public let threadTitle: String
    public let rolloutPath: String?
    public let reasoningOutputTokens: Int

    public init(
        threadId: String,
        turnId: String,
        projectName: String,
        threadTitle: String,
        rolloutPath: String?,
        reasoningOutputTokens: Int
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.projectName = projectName
        self.threadTitle = threadTitle
        self.rolloutPath = rolloutPath
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

public struct NotificationPolicyState: Sendable, Codable, Equatable {
    public var hasPrimedCompletedTurns: Bool
    public var seenCompletedTurnKeys: Set<String>
    public var notifiedTurnTimestamps: [String: Date]

    public init(
        hasPrimedCompletedTurns: Bool = false,
        seenCompletedTurnKeys: Set<String> = [],
        notifiedTurnTimestamps: [String: Date] = [:]
    ) {
        self.hasPrimedCompletedTurns = hasPrimedCompletedTurns
        self.seenCompletedTurnKeys = seenCompletedTurnKeys
        self.notifiedTurnTimestamps = notifiedTurnTimestamps
    }
}

enum CoreDateParser {
    static func parse(_ text: String?) -> Date? {
        guard let text else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: text)
    }
}
