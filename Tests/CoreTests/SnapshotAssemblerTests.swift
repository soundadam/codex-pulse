import Core
import Foundation
import Testing

struct SnapshotAssemblerTests {
    @Test
    func groupsByProjectAndSortsNewestFirst() {
        let olderTurn = LatestTurn(
            turnId: "turn-1",
            status: .completed,
            startedAt: date("2026-07-09T00:00:00.000Z"),
            completedAt: date("2026-07-09T00:00:10.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 32),
            lastAgentMessage: "older"
        )
        let suspiciousTurn = LatestTurn(
            turnId: "turn-2",
            status: .completed,
            startedAt: date("2026-07-09T00:01:00.000Z"),
            completedAt: date("2026-07-09T00:01:10.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 516),
            lastAgentMessage: "latest"
        )
        let runningTurn = LatestTurn(
            turnId: "turn-3",
            status: .running,
            startedAt: date("2026-07-09T00:02:00.000Z"),
            completedAt: nil,
            model: "gpt-5.5",
            reasoningEffort: nil,
            usage: TurnUsage(reasoningOutputTokens: 0),
            lastAgentMessage: nil
        )

        let threads = [
            CodexThreadRef(id: "1", name: "Older", preview: "", source: "cli", cwd: "/tmp/project-a", rolloutPath: "/tmp/1.jsonl", updatedAt: nil),
            CodexThreadRef(id: "2", name: "Latest", preview: "", source: "cli", cwd: "/tmp/project-a", rolloutPath: "/tmp/2.jsonl", updatedAt: nil),
            CodexThreadRef(id: "3", name: nil, preview: "No cwd", source: "vscode", cwd: nil, rolloutPath: "/tmp/3.jsonl", updatedAt: nil),
        ]

        let snapshot = SnapshotAssembler.build(
            threads: threads,
            parsedRollouts: [
                "/tmp/1.jsonl": ParsedRollout(turns: [olderTurn], latestTurn: olderTurn),
                "/tmp/2.jsonl": ParsedRollout(turns: [suspiciousTurn], latestTurn: suspiciousTurn),
                "/tmp/3.jsonl": ParsedRollout(turns: [runningTurn], latestTurn: runningTurn),
            ],
            suspiciousModulo: 516,
            generatedAt: date("2026-07-09T00:03:00.000Z")
        )

        #expect(snapshot.threads.map(\.id) == ["3", "2", "1"])
        #expect(snapshot.projectCards.count == 2)
        #expect(snapshot.projectCards[0].key == "thread:3")
        #expect(snapshot.projectCards[1].key == "/tmp/project-a")
        #expect(snapshot.projectCards[1].latestThread.id == "2")
        #expect(snapshot.projectCards[1].olderThreadCount == 1)
        #expect(snapshot.projectCards[1].monitorState == .suspicious)
        #expect(snapshot.completedSessions.map(\.key) == ["2:turn-2", "1:turn-1"])
        #expect(snapshot.completedSessions.first?.tokenUsage.total.reasoningOutputTokens == 516)
        #expect(snapshot.threadTurnGroups.map(\.threadId) == ["2", "1"])
        #expect(snapshot.threadTurnGroups.first?.turns.first?.displayTurnID == "turn-2")
    }

    @Test
    func marksUnknownWhenRolloutIsMissing() {
        let snapshot = SnapshotAssembler.build(
            threads: [
                CodexThreadRef(id: "1", name: nil, preview: "missing", source: "cli", cwd: nil, rolloutPath: nil, updatedAt: nil)
            ],
            parsedRollouts: [:],
            suspiciousModulo: 516
        )

        #expect(snapshot.threads.first?.monitorState == .unknown)
    }

    @Test
    func keepsCompletedSessionsWhenLatestTurnIsRunning() {
        let completedTurn = LatestTurn(
            turnId: "turn-completed",
            status: .completed,
            startedAt: date("2026-07-09T00:00:00.000Z"),
            completedAt: date("2026-07-09T00:00:10.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 120),
            lastAgentMessage: "done"
        )
        let runningTurn = LatestTurn(
            turnId: "turn-running",
            status: .running,
            startedAt: date("2026-07-09T00:01:00.000Z"),
            completedAt: nil,
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 0),
            lastAgentMessage: "working"
        )

        let snapshot = SnapshotAssembler.build(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "Thread",
                    preview: "preview",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: "/tmp/1.jsonl",
                    updatedAt: date("2026-07-09T00:01:10.000Z")
                )
            ],
            parsedRollouts: [
                "/tmp/1.jsonl": ParsedRollout(
                    turns: [completedTurn, runningTurn],
                    latestTurn: runningTurn
                )
            ],
            suspiciousModulo: 516
        )

        #expect(snapshot.threads.first?.monitorState == .running)
        #expect(snapshot.completedSessions.count == 1)
        #expect(snapshot.completedSessions.first?.turnId == "turn-completed")
    }

    @Test
    func marksZeroReasoningCompletedTurnAsUnknownWithoutLiveSignal() {
        let zeroTurn = LatestTurn(
            turnId: "turn-zero",
            status: .completed,
            startedAt: date("2026-07-09T00:00:00.000Z"),
            completedAt: date("2026-07-09T00:00:05.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 0),
            lastAgentMessage: "done"
        )

        let snapshot = SnapshotAssembler.build(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "Thread",
                    preview: "preview",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: "/tmp/1.jsonl",
                    updatedAt: date("2026-07-09T00:00:05.000Z")
                )
            ],
            parsedRollouts: [
                "/tmp/1.jsonl": ParsedRollout(turns: [zeroTurn], latestTurn: zeroTurn)
            ],
            suspiciousModulo: 516
        )

        #expect(snapshot.threads.first?.monitorState == .suspicious)
        #expect(snapshot.completedSessions.first?.signalState == .unknown)
        #expect(snapshot.completedSessions.first?.isInvalidReasoning == false)
        #expect(snapshot.suspiciousCount == 0)
        #expect(snapshot.threadTurnGroups.first?.turns.first?.status == .unknown)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
