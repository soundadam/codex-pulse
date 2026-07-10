import Core
import Foundation
import Testing

@testable import CodexPulseUI

struct TimelinePresentationTests {
    @Test
    func historyWindowsStartAtOneHourAndScaleDiscoveryCost() {
        #expect(TimelineWindow.allCases.map(\.shortLabel) == ["1h", "3h", "6h", "12h", "24h"])
        #expect(TimelineWindow.oneHour.duration == 3_600)
        #expect(TimelineWindow.oneDay.duration == 86_400)
        #expect(TimelineWindow.allCases.map(\.fetchMultiplier) == [1, 2, 3, 4, 6])
    }

    @Test
    func groupsTurnsIntoIndependentThreadSeries() throws {
        let now = date("2026-07-10T10:00:00.000Z")
        let series = TimelinePresentationBuilder.build(
            sessions: [
                session(thread: "a", turn: "1", at: "2026-07-10T09:40:00.000Z", reasoning: 100),
                session(thread: "b", turn: "1", at: "2026-07-10T09:45:00.000Z", reasoning: 200),
                session(thread: "a", turn: "2", at: "2026-07-10T09:50:00.000Z", reasoning: 300),
            ],
            searchQuery: "",
            window: .oneHour,
            now: now
        )

        #expect(series.count == 2)
        let threadA = try #require(series.first(where: { $0.threadID == "a" }))
        #expect(threadA.points.map(\.id) == ["a:1", "a:2"])
        #expect(try #require(series.first(where: { $0.threadID == "b" })).points.map(\.id) == ["b:1"])
    }

    @Test
    func completedTurnReplacesLiveTailAndLatestLiveTailWins() throws {
        let now = date("2026-07-10T10:00:00.000Z")
        let completed = session(
            thread: "a",
            turn: "1",
            at: "2026-07-10T09:58:00.000Z",
            reasoning: 700
        )
        let firstLive = session(
            thread: "a",
            turn: "1",
            at: "2026-07-10T09:59:00.000Z",
            reasoning: 100,
            isLive: true
        )
        let latestLive = session(
            thread: "b",
            turn: "2",
            at: "2026-07-10T09:58:00.000Z",
            reasoning: 110,
            isLive: true
        )
        let newerLive = session(
            thread: "b",
            turn: "2",
            at: "2026-07-10T09:59:00.000Z",
            reasoning: 220,
            isLive: true
        )

        let series = TimelinePresentationBuilder.build(
            sessions: [completed, firstLive, latestLive, newerLive],
            searchQuery: "",
            window: .oneHour,
            now: now
        )

        let completedPoint = try #require(series.first(where: { $0.threadID == "a" })?.points.first)
        #expect(completedPoint.session.key == "a:1")
        #expect(completedPoint.turnTotalReasoningTokens == 700)

        let livePoint = try #require(series.first(where: { $0.threadID == "b" })?.points.first)
        #expect(livePoint.turnTotalReasoningTokens == 220)
        #expect(livePoint.isRunning)
    }

    @Test
    func appliesWindowSearchAndGlobalPointLimit() throws {
        let now = date("2026-07-10T10:00:00.000Z")
        let sessions = [
            session(thread: "a", turn: "1", at: "2026-07-10T08:35:00.000Z", reasoning: 10),
            session(thread: "a", turn: "2", at: "2026-07-10T09:50:00.000Z", reasoning: 20, preview: "needle"),
            session(thread: "b", turn: "1", at: "2026-07-10T09:52:00.000Z", reasoning: 30),
            session(thread: "b", turn: "2", at: "2026-07-10T09:54:00.000Z", reasoning: 40),
        ]

        let oneHourSeries = TimelinePresentationBuilder.build(
            sessions: sessions,
            searchQuery: "needle",
            window: .oneHour,
            now: now
        )
        #expect(oneHourSeries.map(\.threadID) == ["a"])
        #expect(oneHourSeries.first?.points.map(\.id) == ["a:2"])

        let limitedSeries = TimelinePresentationBuilder.build(
            sessions: sessions,
            searchQuery: "",
            window: .oneDay,
            now: now,
            pointLimit: 3
        )
        #expect(limitedSeries.flatMap(\.points).map(\.id).sorted() == ["a:2", "b:1", "b:2"])
    }

    @Test
    func stablePaletteIndexIsDeterministicAndBounded() {
        let first = TimelinePresentationBuilder.stablePaletteIndex(threadID: "thread-a", paletteCount: 8)
        let second = TimelinePresentationBuilder.stablePaletteIndex(threadID: "thread-a", paletteCount: 8)

        #expect(first == second)
        #expect((0..<8).contains(first))
        #expect(TimelinePresentationBuilder.stablePaletteIndex(threadID: "thread-a", paletteCount: 0) == 0)
    }

    @Test
    func logScaleClampsZeroAndRoundsTheUpperDomainToADecade() {
        #expect(TimelineLogScale.plotValue(0) == 1)
        #expect(TimelineLogScale.plotValue(634) == 634)
        #expect(TimelineLogScale.domain(for: [0]) == 1...10)
        #expect(TimelineLogScale.domain(for: [0, 50, 634]) == 1...1_000)
    }

    @Test
    func nodeSizeScaleEncodesTotalTokensAsBoundedArea() {
        let scale = TimelineNodeSizeScale(tokenValues: [100, 1_000, 10_000])
        let small = scale.diameter(for: 100)
        let medium = scale.diameter(for: 1_000)
        let large = scale.diameter(for: 10_000)

        #expect(abs(small - 8) < 0.000_001)
        #expect(medium > small)
        #expect(large > medium)
        #expect(abs(large - 22) < 0.000_001)
    }

    @Test
    func largeTurnNodeUsesTheSumOfInternalReasoningCalls() throws {
        let item = session(
            thread: "a",
            turn: "sum",
            at: "2026-07-10T09:50:00.000Z",
            reasoning: 999,
            sampleReasoning: [8, 516, 100]
        )
        let point = TimelinePoint(
            id: "a:sum",
            session: item,
            timestamp: try #require(item.completedAt)
        )

        #expect(point.turnTotalReasoningTokens == 624)
        #expect(point.reasoningSamples.map(\.reasoningTokens) == [8, 516, 100])
    }

    @Test
    func turnNodeTotalTokensUsesReportedTurnTotal() throws {
        let item = session(
            thread: "a",
            turn: "tokens",
            at: "2026-07-10T09:50:00.000Z",
            reasoning: 400,
            totalTokens: 120_000
        )
        let point = TimelinePoint(
            id: "a:tokens",
            session: item,
            timestamp: try #require(item.completedAt)
        )

        #expect(point.turnTotalTokens == 120_000)
    }

    @Test
    func reasoningSampleSummaryReportsRangeMedianAndDuration() {
        let samples = [
            TimelineSamplePoint(id: "1", timestamp: date("2026-07-10T09:50:00.000Z"), reasoningTokens: 8),
            TimelineSamplePoint(id: "2", timestamp: date("2026-07-10T09:50:05.000Z"), reasoningTokens: 516),
            TimelineSamplePoint(id: "3", timestamp: date("2026-07-10T09:50:12.000Z"), reasoningTokens: 100),
        ]
        let summary = ReasoningSampleSummary(samples: samples)

        #expect(summary.count == 3)
        #expect(summary.minimum == 8)
        #expect(summary.maximum == 516)
        #expect(summary.median == 100)
        #expect(summary.duration == 12)
    }

    @Test
    func sampleDownsamplingPreservesEndpointsAndExtrema() {
        let start = date("2026-07-10T09:50:00.000Z")
        let samples = (0..<100).map { index in
            TimelineSamplePoint(
                id: "\(index)",
                timestamp: start.addingTimeInterval(Double(index)),
                reasoningTokens: index == 50 ? 5_000 : index
            )
        }
        let reduced = TimelineSampleDownsampler.reduce(samples, limit: 20)

        #expect(reduced.count <= 20)
        #expect(reduced.first?.id == "0")
        #expect(reduced.last?.id == "99")
        #expect(reduced.contains(where: { $0.reasoningTokens == 5_000 }))
    }

    @Test
    func hitTestingPrefersNodesThenLinesAndIgnoresBlankSpace() {
        let series = [
            TimelineRenderedSeries(
                threadID: "a",
                points: [
                    TimelineRenderedPoint(pointID: "a:1", position: CGPoint(x: 10, y: 10)),
                    TimelineRenderedPoint(pointID: "a:2", position: CGPoint(x: 100, y: 10)),
                ]
            ),
            TimelineRenderedSeries(
                threadID: "b",
                points: [
                    TimelineRenderedPoint(pointID: "b:1", position: CGPoint(x: 10, y: 30)),
                    TimelineRenderedPoint(pointID: "b:2", position: CGPoint(x: 100, y: 30)),
                ]
            ),
            TimelineRenderedSeries(
                threadID: "c",
                points: [
                    TimelineRenderedPoint(pointID: "c:1", position: CGPoint(x: 10, y: 90)),
                ],
                lineRuns: [[CGPoint(x: 20, y: 45), CGPoint(x: 80, y: 55)]]
            ),
        ]

        #expect(TimelineHitTester.hitTest(location: CGPoint(x: 11, y: 11), series: series) == .point("a:1"))
        #expect(TimelineHitTester.hitTest(location: CGPoint(x: 50, y: 14), series: series) == .thread("a"))
        #expect(TimelineHitTester.hitTest(location: CGPoint(x: 50, y: 26), series: series) == .thread("b"))
        #expect(TimelineHitTester.hitTest(location: CGPoint(x: 50, y: 50), series: series) == .thread("c"))
        #expect(TimelineHitTester.hitTest(location: CGPoint(x: 50, y: 60), series: series) == nil)
    }

    private func session(
        thread: String,
        turn: String,
        at timestamp: String,
        reasoning: Int,
        isLive: Bool = false,
        preview: String = "preview",
        sampleReasoning: [Int] = [],
        totalTokens: Int = 0
    ) -> CompletedSession {
        let date = date(timestamp)
        return CompletedSession(
            key: isLive ? "live:\(thread):\(turn):\(Int(date.timeIntervalSince1970 * 1_000))" : "\(thread):\(turn)",
            threadId: thread,
            turnId: turn,
            projectName: "project-\(thread)",
            subtitle: "/tmp/project-\(thread)",
            threadTitle: "Thread \(thread)",
            source: "cli",
            rolloutPath: "/tmp/\(thread).jsonl",
            startedAt: date.addingTimeInterval(-30),
            completedAt: date,
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: reasoning),
            tokenUsage: TurnTokenUsageSnapshot(
                last: TurnUsage(reasoningOutputTokens: reasoning),
                total: TurnUsage(
                    reasoningOutputTokens: reasoning * 2,
                    totalTokens: totalTokens
                )
            ),
            monitorState: isLive ? .running : .normal,
            signalState: .valid,
            assistantPreview: preview,
            reasoningSamples: sampleReasoning.enumerated().map { index, value in
                TurnReasoningSample(
                    observedAt: date.addingTimeInterval(Double(index)),
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(reasoningOutputTokens: value),
                        total: TurnUsage(reasoningOutputTokens: value)
                    )
                )
            }
        )
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
