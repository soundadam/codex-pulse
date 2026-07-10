import Foundation

public protocol ThreadDiscoveryService: Sendable {
    func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef]
}

public struct ThreadTokenUsageUpdate: Sendable, Equatable {
    public let threadId: String
    public let turnId: String
    public let tokenUsage: TurnTokenUsageSnapshot
    public let modelContextWindow: Int?
    public let observedAt: Date

    public init(
        threadId: String,
        turnId: String,
        tokenUsage: TurnTokenUsageSnapshot,
        modelContextWindow: Int?,
        observedAt: Date
    ) {
        self.threadId = threadId
        self.turnId = turnId
        self.tokenUsage = tokenUsage
        self.modelContextWindow = modelContextWindow
        self.observedAt = observedAt
    }
}

public struct TurnCompletionEvent: Sendable, Equatable {
    public let threadId: String
    public let turnId: String?
    public let completedAt: Date?

    public init(threadId: String, turnId: String?, completedAt: Date?) {
        self.threadId = threadId
        self.turnId = turnId
        self.completedAt = completedAt
    }
}

public enum AppServerEvent: Sendable, Equatable {
    case tokenUsageUpdated(ThreadTokenUsageUpdate)
    case turnCompleted(TurnCompletionEvent)
}

public protocol ThreadRealtimeSubscribing: Sendable {
    func setEventHandler(_ handler: (@Sendable (AppServerEvent) async -> Void)?) async
    func syncSubscriptions(threadIDs: [String]) async
}
