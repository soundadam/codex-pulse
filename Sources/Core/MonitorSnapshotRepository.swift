import Foundation

public struct MonitorSnapshotRefresh: Sendable, Equatable {
    public let snapshot: MonitorSnapshot
    public let discoveredThreads: [CodexThreadRef]
    public let skippedRolloutCount: Int

    public init(
        snapshot: MonitorSnapshot,
        discoveredThreads: [CodexThreadRef],
        skippedRolloutCount: Int
    ) {
        self.snapshot = snapshot
        self.discoveredThreads = discoveredThreads
        self.skippedRolloutCount = skippedRolloutCount
    }
}

/// Owns one complete refresh transaction so the UI model does not coordinate
/// discovery, filesystem checks, parsing, and snapshot assembly itself.
public actor MonitorSnapshotRepository {
    private let discoveryService: any ThreadDiscoveryService
    private let rolloutParser: RolloutParser
    private let turnDetailCache: TurnDetailCache
    private let fileManager: FileManager

    public init(
        discoveryService: any ThreadDiscoveryService,
        rolloutParser: RolloutParser = RolloutParser(),
        turnDetailCache: TurnDetailCache = TurnDetailCache()
    ) {
        self.discoveryService = discoveryService
        self.rolloutParser = rolloutParser
        self.turnDetailCache = turnDetailCache
        self.fileManager = .default
    }

    public func refresh(
        threadLimit: Int,
        cwdFilters: [String],
        suspiciousModulo: Int,
        generatedAt: Date = Date(),
        detailCutoff: Date = .distantPast
    ) async throws -> MonitorSnapshotRefresh {
        let threads = try await discoveryService.listThreads(
            limit: threadLimit,
            cwdFilters: cwdFilters
        )

        var parsedRollouts: [String: ParsedRollout] = [:]
        var skippedRolloutCount = 0
        let threadIDsByRolloutPath = Dictionary(
            grouping: threads.compactMap { thread -> (String, String)? in
                guard let path = thread.rolloutPath else {
                    return nil
                }
                return (path, thread.id)
            },
            by: { $0.0 }
        )
        .mapValues { entries in entries.map(\.1) }

        for path in Set(threads.compactMap(\.rolloutPath)).sorted() {
            guard fileManager.fileExists(atPath: path) else {
                continue
            }

            do {
                let parsed = try await rolloutParser.parse(
                    path: path,
                    detailCutoff: detailCutoff
                )
                for turn in parsed.turns {
                    guard let turnID = turn.turnId,
                          (turn.completedAt ?? turn.startedAt ?? .distantPast) >= detailCutoff,
                          turn.reasoningSamples.isEmpty == false else {
                        continue
                    }
                    for threadID in threadIDsByRolloutPath[path] ?? [] {
                        try? await turnDetailCache.store(
                            reasoningSamples: turn.reasoningSamples,
                            for: "\(threadID):\(turnID)"
                        )
                    }
                }

                // Detailed samples are persisted before this assignment so no
                // refresh transaction retains all rollout histories at once.
                parsedRollouts[path] = parsed.withoutReasoningSamples()
            } catch {
                skippedRolloutCount += 1
            }
        }

        let snapshot = SnapshotAssembler.build(
            threads: threads,
            parsedRollouts: parsedRollouts,
            suspiciousModulo: suspiciousModulo,
            generatedAt: generatedAt,
            includeLegacyCollections: false
        )

        return MonitorSnapshotRefresh(
            snapshot: snapshot,
            discoveredThreads: threads,
            skippedRolloutCount: skippedRolloutCount
        )
    }
}
