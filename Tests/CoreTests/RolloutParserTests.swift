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
}
