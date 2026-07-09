import Foundation

public enum NotificationPolicy {
    public static func collectNewSuspiciousCompletedTurns(
        snapshot: MonitorSnapshot,
        state: inout NotificationPolicyState,
        observedAt: Date = Date(),
        maxPersistedNotifications: Int = 2_000
    ) -> [SuspiciousCompletion] {
        if state.hasPrimedCompletedTurns == false {
            for session in snapshot.completedSessions {
                state.seenCompletedTurnKeys.insert(session.key)
            }
            state.hasPrimedCompletedTurns = true
            return []
        }

        var completions: [SuspiciousCompletion] = []

        for session in snapshot.completedSessions {
            guard let turnId = session.turnId else {
                continue
            }

            let alreadySeen = state.seenCompletedTurnKeys.contains(session.key)
            state.seenCompletedTurnKeys.insert(session.key)

            guard alreadySeen == false,
                  session.monitorState == .suspicious,
                  state.notifiedTurnTimestamps[session.key] == nil else {
                continue
            }

            state.notifiedTurnTimestamps[session.key] = observedAt
            completions.append(
                SuspiciousCompletion(
                    threadId: session.threadId,
                    turnId: turnId,
                    projectName: session.projectName,
                    threadTitle: session.threadTitle,
                    rolloutPath: session.rolloutPath,
                    reasoningOutputTokens: session.usage.reasoningOutputTokens
                )
            )
        }

        state.notifiedTurnTimestamps = trimNotifications(
            state.notifiedTurnTimestamps,
            limit: maxPersistedNotifications
        )
        return completions
    }

    private static func trimNotifications(
        _ timestamps: [String: Date],
        limit: Int
    ) -> [String: Date] {
        guard timestamps.count > limit else {
            return timestamps
        }

        let retained = timestamps
            .sorted { left, right in
                if left.value == right.value {
                    return left.key > right.key
                }
                return left.value > right.value
            }
            .prefix(limit)
            .map { ($0.key, $0.value) }

        return Dictionary(uniqueKeysWithValues: retained)
    }
}
