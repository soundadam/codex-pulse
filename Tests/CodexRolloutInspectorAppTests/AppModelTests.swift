import Core
import CodexRolloutInspectorUI
import Foundation
import Testing

@testable import CodexRolloutInspectorUI

@MainActor
struct AppModelTests {
    @Test
    func statusItemTitleFormatsCountsAndErrors() {
        let snapshot = MonitorSnapshot(
            generatedAt: date("2026-07-09T00:00:00.000Z"),
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
    func refreshBuildsSnapshotAndFiltersSelection() async throws {
        let rolloutURL = try writeRollout()
        let discovery = MockThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First thread",
                    preview: "Preview text",
                    source: "cli",
                    cwd: "/tmp/project-a",
                    rolloutPath: rolloutURL.path,
                    updatedAt: date("2026-07-09T00:00:05.000Z")
                )
            ]
        )
        let notificationSender = MockNotificationSender()
        let notificationStore = InMemoryNotificationStore()
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: notificationSender,
            notificationStore: notificationStore
        )

        model.refreshNow()
        try await eventually {
            model.snapshot != nil
        }

        #expect(model.statusTitle == "Cdx !1 ~0")
        #expect(model.recentReasoningSessions.count == 1)
        #expect(model.recentReasoningSessions.first?.key == "thread-1:turn-1")
        #expect(model.recentReasoningSessions.first?.tokenUsage.total.reasoningOutputTokens == 516)
    }

    @Test
    func refreshKeepsOnlyThreeMostRecentReasoningSessions() async throws {
        let firstRolloutURL = try writeNamedTurnRollout(turnID: "turn-1", timestampSecond: 1, reasoning: 11)
        let secondRolloutURL = try writeNamedTurnRollout(turnID: "turn-2", timestampSecond: 2, reasoning: 22)
        let thirdRolloutURL = try writeNamedTurnRollout(turnID: "turn-3", timestampSecond: 3, reasoning: 33)
        let fourthRolloutURL = try writeNamedTurnRollout(turnID: "turn-4", timestampSecond: 4, reasoning: 44)
        let discovery = MockThreadDiscoveryService(
            threads: [
                CodexThreadRef(
                    id: "thread-1",
                    name: "First thread",
                    preview: "first",
                    source: "cli",
                    cwd: "/tmp/project-1",
                    rolloutPath: firstRolloutURL.path,
                    updatedAt: date("2026-07-09T00:00:01.000Z")
                ),
                CodexThreadRef(
                    id: "thread-2",
                    name: "Second thread",
                    preview: "second",
                    source: "cli",
                    cwd: "/tmp/project-2",
                    rolloutPath: secondRolloutURL.path,
                    updatedAt: date("2026-07-09T00:00:02.000Z")
                ),
                CodexThreadRef(
                    id: "thread-3",
                    name: "Third thread",
                    preview: "third",
                    source: "cli",
                    cwd: "/tmp/project-3",
                    rolloutPath: thirdRolloutURL.path,
                    updatedAt: date("2026-07-09T00:00:03.000Z")
                ),
                CodexThreadRef(
                    id: "thread-4",
                    name: "Fourth thread",
                    preview: "fourth",
                    source: "cli",
                    cwd: "/tmp/project-4",
                    rolloutPath: fourthRolloutURL.path,
                    updatedAt: date("2026-07-09T00:00:04.000Z")
                ),
            ]
        )
        let model = AppModel(
            discoveryService: discovery,
            rolloutParser: RolloutParser(),
            notificationSender: MockNotificationSender(),
            notificationStore: InMemoryNotificationStore()
        )

        model.refreshNow()
        try await eventually {
            model.snapshot != nil
        }

        #expect(model.snapshot?.threads.count == 4)
        #expect(model.recentReasoningSessions.map(\.key) == ["thread-4:turn-4", "thread-3:turn-3", "thread-2:turn-2"])
        #expect(model.recentReasoningSessions.map { $0.tokenUsage.total.reasoningOutputTokens } == [44, 33, 22])
    }

    private func makeThread(id: String, state: MonitorState, reasoning: Int) -> MonitorThread {
        let turn = LatestTurn(
            turnId: "turn-\(id)",
            status: state == .running ? .running : .completed,
            startedAt: date("2026-07-09T00:00:00.000Z"),
            completedAt: state == .running ? nil : date("2026-07-09T00:00:05.000Z"),
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

    private func writeRollout(reasoning: Int = 516) throws -> URL {
        try writeRollout(
            """
            {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"turn-1","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":531},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":531}}}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"task_complete"}}
            """
        )
    }

    private func writeNamedTurnRollout(turnID: String, timestampSecond: Int, reasoning: Int) throws -> URL {
        try writeRollout(
            """
            {"type":"turn_context","timestamp":"2026-07-09T00:00:0\(timestampSecond).000Z","payload":{"turn_id":"\(turnID)","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:0\(timestampSecond).500Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":\(reasoning + 13)},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":\(reasoning),"total_tokens":\(reasoning + 13)}}}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:0\(timestampSecond).900Z","payload":{"type":"task_complete"}}
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

    private func date(_ text: String) -> Date {
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
