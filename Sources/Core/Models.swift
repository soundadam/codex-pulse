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
        tokenUsage: TurnTokenUsageSnapshot? = nil
    ) {
        self.turnId = turnId
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.usage = usage
        self.tokenUsage = tokenUsage ?? TurnTokenUsageSnapshot(last: usage, total: usage)
        self.lastAgentMessage = lastAgentMessage
    }

    public var lastUsage: TurnUsage { tokenUsage.last }

    public var totalUsage: TurnUsage { tokenUsage.total }
}

public struct ParsedRollout: Sendable, Equatable {
    public let turns: [LatestTurn]
    public let latestTurn: LatestTurn?

    public init(turns: [LatestTurn], latestTurn: LatestTurn?) {
        self.turns = turns
        self.latestTurn = latestTurn
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

public struct CompletedSession: Sendable, Codable, Equatable, Identifiable {
    private static let invalidReasoningModulo = 516

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
    public let assistantPreview: String?

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
        assistantPreview: String?
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
        self.assistantPreview = assistantPreview
    }

    public var id: String { key }

    public var timelineReasoningTokens: Int {
        tokenUsage.last.reasoningOutputTokens
    }

    public var isInvalidReasoning: Bool {
        let values = [
            tokenUsage.last.reasoningOutputTokens,
            usage.reasoningOutputTokens,
        ]

        if values.contains(0) {
            return true
        }

        return values.contains {
            $0 > 0 && $0.isMultiple(of: Self.invalidReasoningModulo)
        }
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

    public init(
        generatedAt: Date,
        suspiciousModulo: Int,
        threads: [MonitorThread],
        projectCards: [ProjectCard],
        completedSessions: [CompletedSession] = []
    ) {
        self.generatedAt = generatedAt
        self.suspiciousModulo = suspiciousModulo
        self.threads = threads
        self.projectCards = projectCards
        self.completedSessions = completedSessions
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
