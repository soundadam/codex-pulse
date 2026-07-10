import Core
import CodexPulseUI
import Foundation
import Testing

@testable import CodexPulseUI

@MainActor
struct AppModelTests {
    @Test
    func statusItemTitleFormatsCountsAndErrors() {
        let snapshot = MonitorSnapshot(
            generatedAt: Self.date("2026-07-09T00:00:00.000Z"),
            suspiciousModulo: 516,
            threads: [
                makeThread(id: "1", state: .suspicious, reasoning: 516),
                makeThread(id: "2", state: .running, reasoning: 0),
            ],
            projectCards: []
        )

        #expect(StatusItemTitleFormatter.title(snapshot: snapshot, errorMessage: nil) == "Cdx !1 ~1")
        #expect(StatusItemTitleFormatter.title(snapshot: snapshot, errorMessage: "boom") == "Cdx !1 ~1?")
        #expect(StatusItemTitleFormatter.title(snapshot: nil, errorMessage: nil) == "Cdx")
    }

    @Test
    func refreshBuildsSnapshotAndCompletedTurnsStartUnknown() async throws {
        let rolloutURL = try writeCompletedRollout()
        let discovery = MockThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First thread",
                    preview: "Preview text",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T00:00:05.000Z")
                )
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { Self.date("2026-07-09T00:30:00.000Z") }
        )

        model.refreshNow()
        try await eventually {
            model.snapshot != nil
        }

        #expect(model.statusTitle == "Cdx")
        #expect(model.recentReasoningSessions.count == 1)
        #expect(model.recentReasoningSessions.first?.key == "thread-1:turn-1")
        #expect(model.recentReasoningSessions.first?.signalState == .unknown)
        #expect(model.selectedCompletedSession == nil)
        #expect(model.selectedThreadID == nil)
        #expect(model.snapshot?.completedSessions.first?.reasoningSamples.isEmpty == true)

        model.selectTimelinePoint("thread-1:turn-1")
        try await eventually {
            model.selectedTurnReasoningSamples.count == 1
                && model.isLoadingSelectedTurnDetails == false
        }
        #expect(model.selectedTurnReasoningSamples.first?.reasoningOutputTokens == 516)
    }

    @Test
    func keepsLastSnapshotQuietlyAcrossOneTransientDiscoveryFailure() async throws {
        let rolloutURL = try writeCompletedRollout()
        let discovery = ToggleThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First thread",
                    preview: "Preview text",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T00:00:05.000Z")
                )
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { Self.date("2026-07-09T00:30:00.000Z") }
        )

        model.refreshNow()
        try await eventuallyAsync {
            await discovery.callCount == 1 && model.snapshot != nil
        }

        await discovery.setShouldFail(true)
        model.refreshNow()
        try await eventuallyAsync {
            await discovery.callCount == 2 && model.isRefreshing == false
        }
        #expect(model.snapshot?.threads.map(\.id) == ["thread-1"])
        #expect(model.errorMessage == nil)

        model.refreshNow()
        try await eventuallyAsync {
            await discovery.callCount == 3 && model.isRefreshing == false
        }
        #expect(model.errorMessage?.contains("thread/list") == true)
    }

    @Test
    func equivalentPollingRefreshDoesNotRepublishTimelinePresentation() async throws {
        let rolloutURL = try writeCompletedRollout(reasoning: 240)
        let discovery = ToggleThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-stable",
                    name: "Stable thread",
                    preview: "unchanged",
                    source: "cli",
                    cwd: "/tmp/stable-project",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T00:00:05.000Z")
                )
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { Self.date("2026-07-09T00:30:00.000Z") }
        )

        model.refreshNow()
        try await eventuallyAsync {
            await discovery.callCount == 1 && model.timelinePresentationRevision > 0
        }
        let firstRevision = model.timelinePresentationRevision

        model.refreshNow()
        try await eventuallyAsync {
            await discovery.callCount == 2 && model.isRefreshing == false
        }

        #expect(model.timelinePresentationRevision == firstRevision)
        #expect(model.timelinePoints.map(\.id) == ["thread-stable:turn-1"])
    }

    @Test
    func sendsRealtimeSubscriptionsToConfiguredService() async throws {
        let rolloutURL = try writeCompletedRollout()
        let thread = CodexThreadRef(
            id: "thread-1",
            name: "First thread",
            preview: "Preview text",
            source: "cli",
            cwd: "/tmp/project-a",
            rolloutPath: rolloutURL.path,
            updatedAt: Self.date("2026-07-09T00:00:05.000Z")
        )
        let discovery = MockThreadDiscoveryService(threads: [thread])
        let realtime = MockRealtimeThreadService(threads: [])
        let model = AppModel(
            discoveryService: discovery,
            realtimeService: realtime,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { Self.date("2026-07-09T00:30:00.000Z") }
        )
        defer { model.stop() }

        model.start()
        try await eventuallyAsync {
            await realtime.lastSubscribedThreadIDs == ["thread-1"]
        }

        #expect(model.snapshot?.threads.map(\.id) == ["thread-1"])
    }

    @Test
    func timelineFocusResetsAndNormalizesWhenBaseWindowHidesSelection() async throws {
        let rolloutURL = try writeCompletedRollout(reasoning: 120)
        let discovery = MockThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First thread",
                    preview: "Preview text",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T00:00:05.000Z")
                )
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { Self.date("2026-07-09T02:00:00.000Z") }
        )

        model.setTimelineWindow(.threeHours)
        try await eventually {
            model.timelinePoints.count == 1
        }

        model.selectThreadLine("thread-1")
        #expect(model.selectedThreadID == "thread-1")
        #expect(model.selectedTimelinePoint == nil)

        model.selectTimelinePoint("thread-1:turn-1")
        #expect(model.selectedTimelinePoint?.id == "thread-1:turn-1")

        model.setTimelineWindow(.oneHour)
        #expect(model.timelinePoints.isEmpty)
        #expect(model.selectedThreadID == nil)
        #expect(model.selectedTimelinePoint == nil)

        model.setTimelineWindow(.threeHours)
        model.selectThreadLine("thread-1")
        model.resetTimelineFocus()
        #expect(model.selectedThreadID == nil)
        #expect(model.selectedTimelinePoint == nil)
    }

    @Test
    func oneHourWindowKeepsAllRecentTurnsWithinPointLimit() async throws {
        var threads: [CodexThreadRef] = []
        for index in 1...12 {
            let rolloutURL = try writeNamedTurnRollout(
                turnID: "turn-\(index)",
                minute: index,
                reasoning: index * 11
            )
            threads.append(
                CodexThreadRef(
                    id: "thread-\(index)",
                    name: "Thread \(index)",
                    preview: "preview-\(index)",
                    source: "cli",
                    cwd: "/tmp/project-\(index)",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T01:\(String(format: "%02d", index)):59.000Z")
                )
            )
        }

        let discovery = MockThreadDiscoveryService(threads: threads)
        let now = Self.date("2026-07-09T01:59:59.000Z")
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { now }
        )

        model.refreshNow()
        try await eventually {
            model.snapshot != nil
        }
        model.setTimelineWindow(.oneHour)

        #expect(model.snapshot?.threads.count == 12)
        #expect(model.recentReasoningSessions.count == 12)
        #expect(model.recentReasoningSessions.map(\.key) == [
            "thread-1:turn-1",
            "thread-2:turn-2",
            "thread-3:turn-3",
            "thread-4:turn-4",
            "thread-5:turn-5",
            "thread-6:turn-6",
            "thread-7:turn-7",
            "thread-8:turn-8",
            "thread-9:turn-9",
            "thread-10:turn-10",
            "thread-11:turn-11",
            "thread-12:turn-12",
        ])
        #expect(model.selectedCompletedSession == nil)
    }

    @Test
    func filtersTimelineTurnsOlderThanOneHour() async throws {
        let recentRollout = try writeNamedTurnRollout(turnID: "turn-recent", minute: 10, reasoning: 123)
        let oldRollout = try writeRollout(
            """
            {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"turn-old","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:10.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":88,"total_tokens":103},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":88,"total_tokens":103}}}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:20.000Z","payload":{"type":"task_complete"}}
            """
        )

        let discovery = MockThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-recent",
                    name: "Recent thread",
                    preview: "recent",
                    source: "cli",
                    cwd: "/tmp/project-recent",
                    rolloutPath: recentRollout.path,
                    updatedAt: Self.date("2026-07-09T01:10:59.000Z")
                ),
                CodexThreadRef(
                    id: "thread-old",
                    name: "Old thread",
                    preview: "old",
                    source: "cli",
                    cwd: "/tmp/project-old",
                    rolloutPath: oldRollout.path,
                    updatedAt: Self.date("2026-07-09T00:00:20.000Z")
                ),
            ]
        )

        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            nowProvider: { Self.date("2026-07-09T01:30:00.000Z") }
        )

        model.refreshNow()
        try await eventually {
            model.snapshot != nil
        }

        #expect(model.recentReasoningSessions.map(\.threadId) == ["thread-recent"])
        #expect(model.timelineSeries.map(\.threadID) == ["thread-recent"])
    }

    @Test
    func liveTokenUsageUpdatesFeedMultiThreadTimelineAndInspector() async throws {
        let discovery = MockRealtimeThreadService(
            threads: [
                CodexThreadRef(
                    id: "thread-live",
                    name: "Live thread",
                    preview: "working",
                    source: "vscode",
                    cwd: "/tmp/live-project",
                    rolloutPath: nil,
                    updatedAt: Self.date("2026-07-09T02:00:00.000Z")
                )
            ]
        )
        let now = Self.date("2026-07-09T02:00:30.000Z")
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { now }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot != nil
        }
        try await eventuallyAsync {
            await discovery.lastSubscribedThreadIDs == ["thread-live"]
        }

        await discovery.emit(
            .tokenUsageUpdated(
                ThreadTokenUsageUpdate(
                    threadId: "thread-live",
                    turnId: "turn-live",
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(
                            inputTokens: 10,
                            cachedInputTokens: 2,
                            outputTokens: 3,
                            reasoningOutputTokens: 516,
                            totalTokens: 531
                        ),
                        total: TurnUsage(
                            inputTokens: 40,
                            cachedInputTokens: 10,
                            outputTokens: 12,
                            reasoningOutputTokens: 650,
                            totalTokens: 702
                        )
                    ),
                    modelContextWindow: 258_400,
                    observedAt: Self.date("2026-07-09T02:00:10.000Z")
                )
            )
        )

        try await eventually {
            model.recentReasoningSessions.count == 1
        }

        #expect(model.recentReasoningSessions.first?.projectName == "live-project")
        #expect(model.recentReasoningSessions.first?.timelineReasoningTokens == 516)
        #expect(model.recentReasoningSessions.first?.signalState == .invalid)
        model.selectTimelinePoint("thread-live:turn-live")
        #expect(model.selectedTimelineTurnDetail?.key == "thread-live:turn-live")
        #expect(model.selectedTimelineTurnDetail?.signalState == .invalid)
        #expect(model.selectedTimelineTurnSamples.count == 1)
        #expect(model.selectedThreadID == "thread-live")
    }

    @Test
    func liveSamplingCoalescesBurstUpdatesForOverview() async throws {
        let discovery = MockRealtimeThreadService(
            threads: [
                CodexThreadRef(
                    id: "thread-live",
                    name: "Live thread",
                    preview: "working",
                    source: "vscode",
                    cwd: "/tmp/live-project",
                    rolloutPath: nil,
                    updatedAt: Self.date("2026-07-09T02:00:00.000Z")
                )
            ]
        )
        let now = Self.date("2026-07-09T02:00:30.000Z")
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { now }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot != nil
        }

        await discovery.emit(
            .tokenUsageUpdated(
                ThreadTokenUsageUpdate(
                    threadId: "thread-live",
                    turnId: "turn-live",
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(reasoningOutputTokens: 100),
                        total: TurnUsage(reasoningOutputTokens: 400)
                    ),
                    modelContextWindow: 258_400,
                    observedAt: Self.date("2026-07-09T02:00:01.000Z")
                )
            )
        )
        await discovery.emit(
            .tokenUsageUpdated(
                ThreadTokenUsageUpdate(
                    threadId: "thread-live",
                    turnId: "turn-live",
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(reasoningOutputTokens: 120),
                        total: TurnUsage(reasoningOutputTokens: 430)
                    ),
                    modelContextWindow: 258_400,
                    observedAt: Self.date("2026-07-09T02:00:01.400Z")
                )
            )
        )

        try await eventually {
            model.recentReasoningSessions.count == 1
        }

        #expect(model.recentReasoningSessions.first?.timelineReasoningTokens == 120)
        model.selectTimelinePoint("thread-live:turn-live")
        #expect(model.selectedTimelineTurnSamples.count == 2)
        #expect(model.selectedTimelinePoint?.reasoningSamples.map(\.reasoningTokens) == [100, 120])
    }

    @Test
    func retainsRealtimeHistoryBeforeAThreadIsSelected() async throws {
        let firstRollout = try writeRunningRollout(turnID: "turn-1")
        let secondRollout = try writeRunningRollout(turnID: "turn-2")
        let discovery = MockRealtimeThreadService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First",
                    preview: "one",
                    source: "cli",
                    cwd: "/tmp/project-1",
                    rolloutPath: firstRollout.path,
                    updatedAt: Self.date("2026-07-09T02:00:00.000Z")
                ),
                CodexThreadRef(
                    id: "thread-2",
                    name: "Second",
                    preview: "two",
                    source: "cli",
                    cwd: "/tmp/project-2",
                    rolloutPath: secondRollout.path,
                    updatedAt: Self.date("2026-07-09T02:00:01.000Z")
                ),
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { Self.date("2026-07-09T02:00:30.000Z") }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot != nil
        }
        #expect(model.selectedThreadID == nil)

        for (reasoning, timestamp) in [(100, 10), (130, 11)] {
            await discovery.emit(
                .tokenUsageUpdated(
                    ThreadTokenUsageUpdate(
                        threadId: "thread-2",
                        turnId: "turn-2",
                        tokenUsage: TurnTokenUsageSnapshot(
                            last: TurnUsage(reasoningOutputTokens: reasoning),
                            total: TurnUsage(reasoningOutputTokens: reasoning + 300)
                        ),
                        modelContextWindow: 258_400,
                        observedAt: Self.date("2026-07-09T02:00:\(timestamp).000Z")
                    )
                )
            )
        }

        model.selectTimelinePoint("thread-2:turn-2")

        #expect(model.selectedTimelineTurnDetail?.key == "thread-2:turn-2")
        #expect(model.selectedTimelineTurnSamples.count == 2)
        #expect(model.selectedTimelinePoint?.reasoningSamples.map(\.reasoningTokens) == [100, 130])
    }

    @Test
    func turnCompletedReconcilesOverviewLiveSamplesIntoCompletedHistory() async throws {
        let rolloutURL = try writeRunningRollout(turnID: "turn-live")
        let discovery = MockRealtimeThreadService(
            threads: [
                CodexThreadRef(
                    id: "thread-live",
                    name: "Live thread",
                    preview: "working",
                    source: "vscode",
                    cwd: "/tmp/live-project",
                    rolloutPath: rolloutURL.path,
                    updatedAt: Self.date("2026-07-09T02:00:00.000Z")
                )
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { Self.date("2026-07-09T02:05:00.000Z") }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot != nil
        }

        await discovery.emit(
            .tokenUsageUpdated(
                ThreadTokenUsageUpdate(
                    threadId: "thread-live",
                    turnId: "turn-live",
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(reasoningOutputTokens: 516),
                        total: TurnUsage(reasoningOutputTokens: 700)
                    ),
                    modelContextWindow: 258_400,
                    observedAt: Self.date("2026-07-09T02:00:10.000Z")
                )
            )
        )

        try await eventually {
            model.recentReasoningSessions.first?.key.hasPrefix("live:thread-live:turn-live") == true
        }
        model.selectTimelinePoint("thread-live:turn-live")

        try overwriteRollout(
            at: rolloutURL,
            contents:
                """
                {"type":"turn_context","timestamp":"2026-07-09T02:00:00.000Z","payload":{"turn_id":"turn-live","model":"gpt-5.5","effort":"high"}}
                {"type":"event_msg","timestamp":"2026-07-09T02:00:20.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":700,"total_tokens":715},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":700,"total_tokens":715}}}}
                {"type":"event_msg","timestamp":"2026-07-09T02:00:30.000Z","payload":{"type":"task_complete"}}
                """
        )

        await discovery.emit(
            .turnCompleted(
                TurnCompletionEvent(
                    threadId: "thread-live",
                    turnId: "turn-live",
                    completedAt: Self.date("2026-07-09T02:00:30.000Z")
                )
            )
        )

        try await eventually {
            model.recentReasoningSessions.contains(where: { $0.key == "thread-live:turn-live" })
        }

        #expect(model.recentReasoningSessions.contains(where: { $0.key.hasPrefix("live:thread-live:turn-live") }) == false)
        #expect(model.recentReasoningSessions.first(where: { $0.key == "thread-live:turn-live" })?.signalState == .invalid)
        #expect(model.selectedTimelineTurnDetail?.key == "thread-live:turn-live")
        #expect(model.selectedTimelineTurnSamples.count == 1)
    }

    @Test
    func selectedThreadIsForcedIntoRealtimeSubscriptions() async throws {
        let discovery = MockRealtimeThreadService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First",
                    preview: "one",
                    source: "cli",
                    cwd: "/tmp/project-1",
                    rolloutPath: nil,
                    updatedAt: Self.date("2026-07-09T03:00:00.000Z")
                ),
                CodexThreadRef(
                    id: "thread-2",
                    name: "Second",
                    preview: "two",
                    source: "cli",
                    cwd: "/tmp/project-2",
                    rolloutPath: nil,
                    updatedAt: Self.date("2026-07-09T03:00:01.000Z")
                ),
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { Self.date("2026-07-09T03:05:00.000Z") }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot != nil
        }
        try await eventuallyAsync {
            await discovery.lastSubscribedThreadIDs == ["thread-2"]
        }

        await discovery.emit(
            .tokenUsageUpdated(
                ThreadTokenUsageUpdate(
                    threadId: "thread-1",
                    turnId: "turn-1",
                    tokenUsage: TurnTokenUsageSnapshot(
                        last: TurnUsage(reasoningOutputTokens: 120),
                        total: TurnUsage(reasoningOutputTokens: 420)
                    ),
                    modelContextWindow: 258_400,
                    observedAt: Self.date("2026-07-09T03:04:00.000Z")
                )
            )
        )
        try await eventually {
            model.timelineSeries.contains(where: { $0.threadID == "thread-1" })
        }
        model.selectThreadLine("thread-1")
        try await eventuallyAsync {
            await discovery.lastSubscribedThreadIDs.contains("thread-1")
        }
    }

    @Test
    func allRunningThreadsAreSubscribedWithoutAThreeThreadCap() async throws {
        var threads: [CodexThreadRef] = []
        let expectedIDs = Set((1...5).map { "thread-\($0)" })

        for index in 1...5 {
            let rollout = try writeRunningRollout(turnID: "turn-\(index)")
            threads.append(
                CodexThreadRef(
                    id: "thread-\(index)",
                    name: "Running \(index)",
                    preview: "working",
                    source: "cli",
                    cwd: "/tmp/project-\(index)",
                    rolloutPath: rollout.path,
                    updatedAt: Self.date("2026-07-09T02:00:0\(index).000Z")
                )
            )
        }

        let discovery = MockRealtimeThreadService(threads: threads)
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore(),
            refreshInterval: .seconds(3_600),
            nowProvider: { Self.date("2026-07-09T02:05:00.000Z") }
        )

        model.start()
        defer { model.stop() }

        try await eventually {
            model.snapshot?.runningCount == 5
        }
        try await eventuallyAsync {
            Set(await discovery.lastSubscribedThreadIDs) == expectedIDs
        }
    }

    private func makeThread(id: String, state: MonitorState, reasoning: Int) -> MonitorThread {
        let turn = LatestTurn(
            turnId: "turn-\(id)",
            status: state == .running ? .running : .completed,
            startedAt: Self.date("2026-07-09T00:00:00.000Z"),
            completedAt: state == .running ? nil : Self.date("2026-07-09T00:00:05.000Z"),
            model: "gpt-5.5",
            reasoningEffort: "high",
            usage: TurnUsage(reasoningOutputTokens: reasoning),
            lastAgentMessage: "preview"
        )
        return MonitorThread(
            id: id,
            name: "Thread \(id)",
            preview: "preview",
            source: "cli",
            cwd: "/tmp/project-\(id)",
            rolloutPath: "/tmp/\(id).jsonl",
            updatedAt: nil,
            latestTurn: turn,
            monitorState: state
        )
    }

    private func writeCompletedRollout(reasoning: Int = 516) throws -> URL {
        try writeRollout(completedRolloutText(turnID: "turn-1", reasoning: reasoning))
    }

    private func completedRolloutText(turnID: String, reasoning: Int) -> String {
        """
        {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"\(turnID)","model":"gpt-5.5","effort":"high"}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":531},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":531}}}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"task_complete"}}
        """
    }

    private func writeRunningRollout(turnID: String) throws -> URL {
        try writeRollout(
            """
            {"type":"turn_context","timestamp":"2026-07-09T02:00:00.000Z","payload":{"turn_id":"\(turnID)","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T02:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":100,"total_tokens":115},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":100,"total_tokens":115}}}}
            """
        )
    }

    private func writeNamedTurnRollout(turnID: String, minute: Int, reasoning: Int) throws -> URL {
        try writeRollout(
            """
            {"type":"turn_context","timestamp":"2026-07-09T01:\(String(format: "%02d", minute)):00.000Z","payload":{"turn_id":"\(turnID)","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T01:\(String(format: "%02d", minute)):30.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":\(reasoning + 13)},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":\(reasoning + 13)}}}}
            {"type":"event_msg","timestamp":"2026-07-09T01:\(String(format: "%02d", minute)):59.000Z","payload":{"type":"task_complete"}}
            """
        )
    }

    private func writeRollout(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func overwriteRollout(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for condition")
        throw CancellationError()
    }

    private func eventuallyAsync(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: interval)
        }
        Issue.record("Timed out waiting for async condition")
        throw CancellationError()
    }

    nonisolated private static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}

actor MockThreadDiscoveryService: ThreadDiscoveryService {
    let threads: [CodexThreadRef]

    init(threads: [CodexThreadRef]) {
        self.threads = threads
    }

    func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef] {
        Array(threads.prefix(limit))
    }
}

actor ToggleThreadDiscoveryService: ThreadDiscoveryService {
    let threads: [CodexThreadRef]
    private(set) var callCount = 0
    private var shouldFail = false

    init(threads: [CodexThreadRef]) {
        self.threads = threads
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef] {
        callCount += 1
        if shouldFail {
            throw AppServerClientError.requestTimedOut(method: "thread/list")
        }
        return Array(threads.prefix(limit))
    }
}

actor MockRealtimeThreadService: ThreadDiscoveryService, ThreadRealtimeSubscribing {
    let threads: [CodexThreadRef]
    private var eventHandler: (@Sendable (AppServerEvent) async -> Void)?
    private(set) var lastSubscribedThreadIDs: [String] = []

    init(threads: [CodexThreadRef]) {
        self.threads = threads
    }

    func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef] {
        Array(threads.prefix(limit))
    }

    func setEventHandler(_ handler: (@Sendable (AppServerEvent) async -> Void)?) async {
        eventHandler = handler
    }

    func syncSubscriptions(threadIDs: [String]) async {
        lastSubscribedThreadIDs = threadIDs
    }

    func emit(_ event: AppServerEvent) async {
        await eventHandler?(event)
    }
}

actor MockNotificationSender: NotificationSending {
    private(set) var delivered: [SuspiciousCompletion] = []

    func requestAuthorization() async {}

    func deliver(_ completion: SuspiciousCompletion) async {
        delivered.append(completion)
    }
}

struct InMemoryNotificationStore: NotificationStatePersisting {
    func loadNotifiedTurnTimestamps() -> [String : Date] { [:] }
    func saveNotifiedTurnTimestamps(_ timestamps: [String : Date]) {}
}
