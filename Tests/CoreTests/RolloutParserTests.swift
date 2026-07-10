import Core
import Foundation
import Testing

@testable import Core

struct RolloutParserTests {
    @Test
    func parsesCompletedTurnAndCapturesLastAndTotalUsage() async throws {
        let parser = RolloutParser()
        let parsed = await parser.parseRolloutText(
            """
            {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"turn-1","model":"gpt-5.5","effort":"high"}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":500,"total_tokens":515},"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":500,"total_tokens":515}}}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":16,"total_tokens":19},"total_token_usage":{"input_tokens":11,"cached_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":516,"total_tokens":534}}}}
            {"type":"response_item","timestamp":"2026-07-09T00:00:03.000Z","payload":{"type":"message","content":[{"type":"output_text","text":"final answer"}]}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:04.000Z","payload":{"type":"task_complete"}}
            """
        )

        #expect(parsed.turns.count == 1)
        let latest = try #require(parsed.latestTurn)
        #expect(latest.status == .completed)
        #expect(latest.model == "gpt-5.5")
        #expect(latest.reasoningEffort == "high")
        #expect(latest.usage.inputTokens == 11)
        #expect(latest.usage.cachedInputTokens == 2)
        #expect(latest.usage.outputTokens == 5)
        #expect(latest.usage.reasoningOutputTokens == 516)
        #expect(latest.usage.totalTokens == 534)
        #expect(latest.lastUsage.reasoningOutputTokens == 16)
        #expect(latest.lastUsage.totalTokens == 19)
        #expect(latest.totalUsage.reasoningOutputTokens == 516)
        #expect(latest.totalUsage.totalTokens == 534)
        #expect(latest.reasoningSamples.map(\.reasoningOutputTokens) == [500, 16])
        #expect(latest.reasoningSamples.map(\.observedAt) == [
            date("2026-07-09T00:00:01.000Z"),
            date("2026-07-09T00:00:02.000Z"),
        ])
        #expect(latest.lastAgentMessage == "final answer")
    }

    @Test
    func ignoresMalformedLinesAndClosesPreviousRunningTurnAsUnknown() async throws {
        let parser = RolloutParser()
        let parsed = await parser.parseRolloutText(
            """
            {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"turn-1"}}
            not-json
            {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"agent_message","message":"draft"}}
            {"type":"turn_context","timestamp":"2026-07-09T00:00:02.000Z","payload":{"turn_id":"turn-2"}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:03.000Z","payload":{"type":"turn_aborted"}}
            """
        )

        #expect(parsed.turns.count == 2)
        #expect(parsed.turns[0].status == .unknown)
        #expect(parsed.turns[0].lastAgentMessage == "draft")
        #expect(parsed.turns[1].status == .aborted)
        #expect(parsed.latestTurn?.turnId == "turn-2")
    }

    @Test
    func reparsesWhenHistoryWindowExpandsBeyondCachedDetailCutoff() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let rolloutURL = directoryURL.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"old"}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"reasoning_output_tokens":100}}}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"task_complete"}}
        {"type":"turn_context","timestamp":"2026-07-09T02:00:00.000Z","payload":{"turn_id":"new"}}
        {"type":"event_msg","timestamp":"2026-07-09T02:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"reasoning_output_tokens":200}}}}
        {"type":"event_msg","timestamp":"2026-07-09T02:00:02.000Z","payload":{"type":"task_complete"}}
        """.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let parser = RolloutParser()
        let recent = try await parser.parse(
            path: rolloutURL.path,
            detailCutoff: date("2026-07-09T01:00:00.000Z")
        )
        #expect(recent.turns[0].reasoningSamples.isEmpty)
        #expect(recent.turns[1].reasoningSamples.count == 1)

        let expanded = try await parser.parse(
            path: rolloutURL.path,
            detailCutoff: date("2026-07-08T23:00:00.000Z")
        )
        #expect(expanded.turns.map { $0.reasoningSamples.count } == [1, 1])
    }

    @Test
    func streamsLinesAcrossReadChunkBoundaries() async throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }
        let largeMessage = String(repeating: "x", count: 300_000)
        let contents = """
        {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"chunked"}}
        {"type":"response_item","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"message","content":[{"type":"output_text","text":"\(largeMessage)"}]}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"task_complete"}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let parsed = try await RolloutParser().parse(path: rolloutURL.path)

        #expect(parsed.latestTurn?.turnId == "chunked")
        #expect(parsed.latestTurn?.status == .completed)
        #expect(parsed.latestTurn?.lastAgentMessage?.count == largeMessage.count)
    }

    @Test
    func incrementallyParsesValidatedFileAppends() async throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }
        let initial = """
        {"type":"turn_context","timestamp":"2026-07-09T00:00:00.000Z","payload":{"turn_id":"appended"}}
        {"type":"event_msg","timestamp":"2026-07-09T00:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"reasoning_output_tokens":100}}}}
        """ + "\n"
        try initial.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let parser = RolloutParser()
        let first = try await parser.parse(path: rolloutURL.path)
        #expect(first.latestTurn?.reasoningSamples.map(\.reasoningOutputTokens) == [100])

        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            """
            {"type":"event_msg","timestamp":"2026-07-09T00:00:02.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"reasoning_output_tokens":40}}}}
            {"type":"event_msg","timestamp":"2026-07-09T00:00:03.000Z","payload":{"type":"task_complete"}}

            """.utf8
        ))
        try handle.close()

        let second = try await parser.parse(path: rolloutURL.path)

        #expect(second.latestTurn?.status == .completed)
        #expect(second.latestTurn?.usage.reasoningOutputTokens == 140)
        #expect(second.latestTurn?.reasoningSamples.map(\.reasoningOutputTokens) == [100, 40])
        #expect(await parser.fullFileParseCount == 1)
        #expect(await parser.incrementalFileParseCount == 1)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
