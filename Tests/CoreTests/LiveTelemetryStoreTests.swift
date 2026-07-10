import Core
import Foundation
import Testing

struct LiveTelemetryStoreTests {
    @Test
    func coalescesOverviewBurstsButRetainsFullTurnHistory() {
        let now = date("2026-07-09T02:00:30.000Z")
        var store = makeStore()

        store.ingest(
            update(reasoning: 100, total: 400, at: "2026-07-09T02:00:01.000Z"),
            context: context,
            referenceDate: now
        )
        store.ingest(
            update(reasoning: 120, total: 430, at: "2026-07-09T02:00:01.400Z"),
            context: context,
            referenceDate: now
        )

        #expect(store.visibleOverviewSessions(referenceDate: now).count == 1)
        #expect(store.visibleOverviewSessions(referenceDate: now).first?.timelineReasoningTokens == 120)
        #expect(store.samples(forTurnKey: "thread-1:turn-1").count == 2)
    }

    @Test
    func keepsInvalidSignalStickyAndPreservesSamplesAfterCompletion() {
        let now = date("2026-07-09T02:00:30.000Z")
        var store = makeStore()

        store.ingest(
            update(reasoning: 516, total: 700, at: "2026-07-09T02:00:01.000Z"),
            context: context,
            referenceDate: now
        )
        store.ingest(
            update(reasoning: 241, total: 941, at: "2026-07-09T02:00:04.000Z"),
            context: context,
            referenceDate: now
        )

        #expect(store.signalState(for: "thread-1:turn-1") == .invalid)
        #expect(store.samples(forTurnKey: "thread-1:turn-1").allSatisfy { $0.hitInvalidSignal })

        let completed = CompletedSession(
            key: "thread-1:turn-1",
            threadId: "thread-1",
            turnId: "turn-1",
            projectName: "project-a",
            subtitle: "/tmp/project-a",
            threadTitle: "Investigate telemetry",
            source: "cli",
            rolloutPath: "/tmp/thread-1.jsonl",
            startedAt: date("2026-07-09T02:00:00.000Z"),
            completedAt: date("2026-07-09T02:00:05.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: 941),
            tokenUsage: TurnTokenUsageSnapshot(
                last: TurnUsage(reasoningOutputTokens: 241),
                total: TurnUsage(reasoningOutputTokens: 941)
            ),
            monitorState: .normal,
            assistantPreview: "done"
        )
        store.reconcile(completedSessions: [completed])

        #expect(store.visibleOverviewSessions(referenceDate: now).isEmpty)
        #expect(store.samples(forTurnKey: "thread-1:turn-1").count == 2)
        #expect(store.applyingSignal(to: completed).signalState == .invalid)
    }

    @Test
    func invalidModuloConfigurationDoesNotTrap() {
        let usage = TurnTokenUsageSnapshot(
            last: TurnUsage(reasoningOutputTokens: 10),
            total: TurnUsage(reasoningOutputTokens: 20)
        )

        #expect(ReasoningSignalRule.hitsInvalidSignal(usage, suspiciousModulo: 0) == false)
    }

    private func makeStore() -> LiveTelemetryStore {
        LiveTelemetryStore(
            configuration: LiveTelemetryConfiguration(
                suspiciousModulo: 516,
                lookbackSeconds: 3_600,
                overviewSampleMinimumInterval: 2,
                overviewSampleReasoningStep: 128,
                overviewSessionLimit: 24,
                sampleLimitPerTurn: 240
            )
        )
    }

    private var context: LiveSessionContext {
        LiveSessionContext(
            projectName: "project-a",
            projectSubtitle: "/tmp/project-a",
            threadTitle: "Investigate telemetry",
            source: "cli",
            rolloutPath: "/tmp/thread-1.jsonl",
            startedAt: date("2026-07-09T02:00:00.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            assistantPreview: "working"
        )
    }

    private func update(reasoning: Int, total: Int, at timestamp: String) -> ThreadTokenUsageUpdate {
        ThreadTokenUsageUpdate(
            threadId: "thread-1",
            turnId: "turn-1",
            tokenUsage: TurnTokenUsageSnapshot(
                last: TurnUsage(reasoningOutputTokens: reasoning),
                total: TurnUsage(reasoningOutputTokens: total)
            ),
            modelContextWindow: 258_400,
            observedAt: date(timestamp)
        )
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
