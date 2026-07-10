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
    private let fileManager: FileManager

    public init(
        discoveryService: any ThreadDiscoveryService,
        rolloutParser: RolloutParser = RolloutParser()
    ) {
        self.discoveryService = discoveryService
        self.rolloutParser = rolloutParser
        self.fileManager = .default
    }

    public func refresh(
        threadLimit: Int,
        cwdFilters: [String],
        suspiciousModulo: Int,
        generatedAt: Date = Date()
    ) async throws -> MonitorSnapshotRefresh {
        let threads = try await discoveryService.listThreads(
            limit: threadLimit,
            cwdFilters: cwdFilters
        )

        var parsedRollouts: [String: ParsedRollout] = [:]
        var skippedRolloutCount = 0

        for path in Set(threads.compactMap(\.rolloutPath)).sorted() {
            guard fileManager.fileExists(atPath: path) else {
                continue
            }

            do {
                parsedRollouts[path] = try await rolloutParser.parse(path: path)
            } catch {
                skippedRolloutCount += 1
            }
        }

        return MonitorSnapshotRefresh(
            snapshot: SnapshotAssembler.build(
                threads: threads,
                parsedRollouts: parsedRollouts,
                suspiciousModulo: suspiciousModulo,
                generatedAt: generatedAt
            ),
            discoveredThreads: threads,
            skippedRolloutCount: skippedRolloutCount
        )
    }
}
