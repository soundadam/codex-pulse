import Core
import Foundation
import Testing

struct TurnDetailCacheTests {
    @Test
    func persistsDetailsAndReloadsThemAfterMemoryEviction() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let cache = TurnDetailCache(
            directoryURL: directoryURL,
            memoryCapacity: 1
        )
        let first = sample(at: "2026-07-10T10:00:00.000Z", reasoning: 123)
        let second = sample(at: "2026-07-10T10:01:00.000Z", reasoning: 456)

        try await cache.store(reasoningSamples: [first], for: "thread-a:turn-1")
        try await cache.store(reasoningSamples: [second], for: "thread-b:turn-2")

        let reloaded = await cache.loadReasoningSamples(for: "thread-a:turn-1")
        #expect(reloaded.map(\.reasoningOutputTokens) == [123])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).count == 2)
    }

    private func sample(at text: String, reasoning: Int) -> TurnReasoningSample {
        TurnReasoningSample(
            observedAt: date(text),
            tokenUsage: TurnTokenUsageSnapshot(
                last: TurnUsage(reasoningOutputTokens: reasoning),
                total: TurnUsage(reasoningOutputTokens: reasoning)
            )
        )
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }
}
