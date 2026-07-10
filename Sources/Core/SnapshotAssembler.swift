import Foundation

public enum SnapshotAssembler {
    public static func build(
        threads: [CodexThreadRef],
        parsedRollouts: [String: ParsedRollout],
        suspiciousModulo: Int,
        generatedAt: Date = Date()
    ) -> MonitorSnapshot {
        let monitorThreads = threads
            .map { thread in
                let parsed = thread.rolloutPath.flatMap { parsedRollouts[$0] }
                let latestTurn = parsed?.latestTurn
                return MonitorThread(
                    id: thread.id,
                    name: thread.name,
                    preview: thread.preview,
                    source: thread.source,
                    cwd: thread.cwd,
                    rolloutPath: thread.rolloutPath,
                    updatedAt: thread.updatedAt,
                    latestTurn: latestTurn,
                    monitorState: evaluateMonitorState(latestTurn: latestTurn, suspiciousModulo: suspiciousModulo)
                )
            }
            .sorted(by: newestFirst)

        let projectCards = buildProjectCards(from: monitorThreads)
        let completedSessions = buildCompletedSessions(
            threads: threads,
            parsedRollouts: parsedRollouts,
            suspiciousModulo: suspiciousModulo
        )
        let threadTurnGroups = buildThreadTurnGroups(
            threads: threads,
            parsedRollouts: parsedRollouts
        )

        return MonitorSnapshot(
            generatedAt: generatedAt,
            suspiciousModulo: suspiciousModulo,
            threads: monitorThreads,
            projectCards: projectCards,
            completedSessions: completedSessions,
            threadTurnGroups: threadTurnGroups
        )
    }

    public static func evaluateMonitorState(
        latestTurn: LatestTurn?,
        suspiciousModulo: Int
    ) -> MonitorState {
        guard let latestTurn else {
            return .unknown
        }

        switch latestTurn.status {
        case .running:
            return .running
        case .aborted:
            return .aborted
        case .rolledBack:
            return .rolledBack
        case .unknown:
            return .unknown
        case .completed:
            if latestTurn.usage.reasoningOutputTokens == 0 {
                return .suspicious
            }
            if suspiciousModulo > 0,
               latestTurn.usage.reasoningOutputTokens > 0,
               latestTurn.usage.reasoningOutputTokens.isMultiple(of: suspiciousModulo) {
                return .suspicious
            }
            return .normal
        }
    }

    private static func buildProjectCards(from threads: [MonitorThread]) -> [ProjectCard] {
        var groupsByKey: [String: [MonitorThread]] = [:]
        var orderedKeys: [String] = []

        for thread in threads {
            let key: String
            if let cwd = MonitorThread.trim(thread.cwd) {
                key = cwd
            } else {
                key = "thread:\(thread.id)"
            }
            if groupsByKey[key] == nil {
                orderedKeys.append(key)
            }
            groupsByKey[key, default: []].append(thread)
        }

        return orderedKeys
            .compactMap { key -> ProjectCard? in
                guard var group = groupsByKey[key], group.isEmpty == false else {
                    return nil
                }
                group.sort(by: newestFirst)
                guard let latestThread = group.first else {
                    return nil
                }
                return ProjectCard(
                    key: key,
                    name: latestThread.projectName,
                    subtitle: latestThread.projectSubtitle,
                    latestThread: latestThread,
                    latestTurn: latestThread.latestTurn,
                    monitorState: latestThread.monitorState,
                    projectThreadCount: group.count,
                    olderThreadCount: max(0, group.count - 1)
                )
            }
            .sorted { left, right in
                newestDate(for: left.latestThread) > newestDate(for: right.latestThread)
            }
    }

    private static func buildCompletedSessions(
        threads: [CodexThreadRef],
        parsedRollouts: [String: ParsedRollout],
        suspiciousModulo: Int
    ) -> [CompletedSession] {
        threads
            .flatMap { thread -> [CompletedSession] in
                guard let rolloutPath = thread.rolloutPath,
                      let parsedRollout = parsedRollouts[rolloutPath] else {
                    return []
                }

                let threadTitle = MonitorThread.trim(thread.name)
                    ?? MonitorThread.trim(thread.preview)
                    ?? thread.id
                let projectName = projectName(for: thread)
                let subtitle = projectSubtitle(for: thread)

                return parsedRollout.turns.compactMap { turn in
                    guard turn.status == .completed else {
                        return nil
                    }

                    return CompletedSession(
                        key: completedSessionKey(threadID: thread.id, turn: turn),
                        threadId: thread.id,
                        turnId: turn.turnId,
                        projectName: projectName,
                        subtitle: subtitle,
                        threadTitle: threadTitle,
                        source: thread.source,
                        rolloutPath: rolloutPath,
                        startedAt: turn.startedAt,
                        completedAt: turn.completedAt ?? thread.updatedAt,
                        model: turn.model,
                        reasoningEffort: turn.reasoningEffort,
                        usage: turn.usage,
                        tokenUsage: turn.tokenUsage,
                        monitorState: evaluateMonitorState(latestTurn: turn, suspiciousModulo: suspiciousModulo),
                        signalState: .unknown,
                        assistantPreview: turn.lastAgentMessage
                    )
                }
            }
            .sorted(by: newestFirst)
    }

    private static func buildThreadTurnGroups(
        threads: [CodexThreadRef],
        parsedRollouts: [String: ParsedRollout]
    ) -> [ThreadTurnGroup] {
        threads
            .compactMap { thread -> ThreadTurnGroup? in
                guard let rolloutPath = thread.rolloutPath,
                      let parsedRollout = parsedRollouts[rolloutPath] else {
                    return nil
                }

                let turns = parsedRollout.turns.compactMap { turn -> TurnDetailItem? in
                    guard turn.status == .completed else {
                        return nil
                    }

                    return TurnDetailItem(
                        key: completedSessionKey(threadID: thread.id, turn: turn),
                        threadId: thread.id,
                        turnId: turn.turnId,
                        startedAt: turn.startedAt,
                        completedAt: turn.completedAt ?? thread.updatedAt,
                        model: turn.model,
                        reasoningEffort: turn.reasoningEffort,
                        lastUsage: turn.tokenUsage.last,
                        totalUsage: turn.tokenUsage.total,
                        hadInvalidSignal: false,
                        status: .unknown,
                        assistantPreview: turn.lastAgentMessage,
                        rolloutPath: rolloutPath
                    )
                }
                .sorted(by: newestFirst)

                guard turns.isEmpty == false else {
                    return nil
                }

                return ThreadTurnGroup(
                    threadId: thread.id,
                    threadTitle: MonitorThread.trim(thread.name)
                        ?? MonitorThread.trim(thread.preview)
                        ?? thread.id,
                    projectName: projectName(for: thread),
                    subtitle: projectSubtitle(for: thread),
                    turns: turns
                )
            }
            .sorted { left, right in
                let leftDate = left.latestAt ?? .distantPast
                let rightDate = right.latestAt ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return left.threadTitle.localizedCaseInsensitiveCompare(right.threadTitle) == .orderedAscending
            }
    }

    private static func newestDate(for thread: MonitorThread) -> Date {
        thread.latestUpdateAt ?? .distantPast
    }

    private static func newestDate(for session: CompletedSession) -> Date {
        session.completedAt ?? session.startedAt ?? .distantPast
    }

    private static func newestDate(for turn: TurnDetailItem) -> Date {
        turn.completedAt ?? turn.startedAt ?? .distantPast
    }

    private static func newestFirst(_ left: MonitorThread, _ right: MonitorThread) -> Bool {
        let leftDate = newestDate(for: left)
        let rightDate = newestDate(for: right)
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return left.threadTitle.localizedCaseInsensitiveCompare(right.threadTitle) == .orderedAscending
    }

    private static func newestFirst(_ left: CompletedSession, _ right: CompletedSession) -> Bool {
        let leftDate = newestDate(for: left)
        let rightDate = newestDate(for: right)
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending
    }

    private static func newestFirst(_ left: TurnDetailItem, _ right: TurnDetailItem) -> Bool {
        let leftDate = newestDate(for: left)
        let rightDate = newestDate(for: right)
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return left.key.localizedCaseInsensitiveCompare(right.key) == .orderedAscending
    }

    private static func projectName(for thread: CodexThreadRef) -> String {
        if let cwd = MonitorThread.trim(thread.cwd) {
            return cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        return MonitorThread.trim(thread.source) ?? "No project"
    }

    private static func projectSubtitle(for thread: CodexThreadRef) -> String {
        if let cwd = MonitorThread.trim(thread.cwd) {
            return cwd
        }
        return MonitorThread.trim(thread.source) ?? "No project binding"
    }

    private static func completedSessionKey(threadID: String, turn: LatestTurn) -> String {
        if let turnID = turn.turnId {
            return "\(threadID):\(turnID)"
        }
        if let completedAt = turn.completedAt {
            return "\(threadID):\(completedAt.timeIntervalSince1970)"
        }
        return "\(threadID):unknown"
    }
}
