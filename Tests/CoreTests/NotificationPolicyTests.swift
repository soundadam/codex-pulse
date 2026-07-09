import Core
import Foundation
import Testing

struct NotificationPolicyTests {
    @Test
    func primesWithoutBackfillingThenDeliversOnlyNewSuspiciousCompletion() {
        var state = NotificationPolicyState()
        let firstSnapshot = makeSnapshot(turnId: "turn-1", reasoning: 516)

        let primed = NotificationPolicy.collectNewSuspiciousCompletedTurns(
            snapshot: firstSnapshot,
            state: &state,
            observedAt: date("2026-07-09T00:00:00.000Z")
        )
        #expect(primed.isEmpty)
        #expect(state.hasPrimedCompletedTurns)

        let secondSnapshot = makeSnapshot(turnId: "turn-2", reasoning: 516)
        let completions = NotificationPolicy.collectNewSuspiciousCompletedTurns(
            snapshot: secondSnapshot,
            state: &state,
            observedAt: date("2026-07-09T00:01:00.000Z")
        )

        #expect(completions.count == 1)
        #expect(completions.first?.turnId == "turn-2")

        let duplicate = NotificationPolicy.collectNewSuspiciousCompletedTurns(
            snapshot: secondSnapshot,
            state: &state,
            observedAt: date("2026-07-09T00:02:00.000Z")
        )
        #expect(duplicate.isEmpty)
    }

    @Test
    func trimsPersistedNotificationsToLimit() {
        var timestamps: [String: Date] = [:]
        for index in 0..<2_500 {
            timestamps["thread:\(index)"] = date("2026-07-09T00:\(String(format: "%02d", index % 60)):00.000Z")
        }

        var state = NotificationPolicyState(
            hasPrimedCompletedTurns: true,
            seenCompletedTurnKeys: [],
            notifiedTurnTimestamps: timestamps
        )

        _ = NotificationPolicy.collectNewSuspiciousCompletedTurns(
            snapshot: makeSnapshot(turnId: "turn-new", reasoning: 516),
            state: &state,
            observedAt: date("2026-07-09T01:00:00.000Z")
        )

        #expect(state.notifiedTurnTimestamps.count == 2_000)
    }

    private func makeSnapshot(turnId: String, reasoning: Int) -> MonitorSnapshot {
        let turn = LatestTurn(
            turnId: turnId,
            status: .completed,
            startedAt: date("2026-07-09T00:00:00.000Z"),
            completedAt: date("2026-07-09T00:00:10.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: reasoning),
            lastAgentMessage: "preview"
        )
        let thread = MonitorThread(
            id: "thread-1",
            name: "Thread",
            preview: "preview",
            source: "cli",
            cwd: "/tmp/project",
            rolloutPath: "/tmp/rollout.jsonl",
            updatedAt: nil,
            latestTurn: turn,
            monitorState: reasoning == 516 ? .suspicious : .normal
        )
        let card = ProjectCard(
            key: "/tmp/project",
            name: "project",
            subtitle: "/tmp/project",
            latestThread: thread,
            latestTurn: turn,
            monitorState: thread.monitorState,
            projectThreadCount: 1,
            olderThreadCount: 0
        )
        return MonitorSnapshot(
            generatedAt: date("2026-07-09T00:00:20.000Z"),
            suspiciousModulo: 516,
            threads: [thread],
            projectCards: [card],
            completedSessions: [
                CompletedSession(
                    key: "thread-1:\(turnId)",
                    threadId: "thread-1",
                    turnId: turnId,
                    projectName: "project",
                    subtitle: "/tmp/project",
                    threadTitle: "Thread",
                    source: "cli",
                    rolloutPath: "/tmp/rollout.jsonl",
                    startedAt: turn.startedAt,
                    completedAt: turn.completedAt,
                    model: turn.model,
                    reasoningEffort: turn.reasoningEffort,
                    usage: turn.usage,
                    tokenUsage: turn.tokenUsage,
                    monitorState: thread.monitorState,
                    assistantPreview: turn.lastAgentMessage
                )
            ]
        )
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
