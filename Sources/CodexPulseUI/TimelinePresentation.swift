import Core
import CoreGraphics
import Foundation

enum TimelineWindow: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes:
            return 15 * 60
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        }
    }

    var shortLabel: String {
        switch self {
        case .fifteenMinutes:
            return "15m"
        case .thirtyMinutes:
            return "30m"
        case .oneHour:
            return "1h"
        }
    }
}

struct TimelinePoint: Identifiable, Equatable {
    let id: String
    let session: CompletedSession
    let timestamp: Date

    var threadID: String { session.threadId }
    var turnTotalReasoningTokens: Int {
        let sampledTotal = session.reasoningSamples.reduce(0) {
            $0 + $1.reasoningOutputTokens
        }
        return sampledTotal > 0
            ? sampledTotal
            : max(session.usage.reasoningOutputTokens, session.timelineReasoningTokens)
    }
    var isRunning: Bool { session.monitorState == .running }
    var callTraceSeriesID: String { "call-trace:\(id)" }

    var reasoningSamples: [TimelineSamplePoint] {
        let samples = session.reasoningSamples.isEmpty
            ? [TurnReasoningSample(observedAt: timestamp, tokenUsage: session.tokenUsage)]
            : session.reasoningSamples
        return samples.enumerated().map { index, sample in
            TimelineSamplePoint(
                id: "\(id):\(index):\(sample.id)",
                timestamp: sample.observedAt,
                reasoningTokens: sample.reasoningOutputTokens
            )
        }
    }

    var displayedReasoningSamples: [TimelineSamplePoint] {
        TimelineSampleDownsampler.reduce(reasoningSamples, limit: 36)
    }
}

struct TimelineSamplePoint: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let reasoningTokens: Int

    var plotReasoningTokens: Double { TimelineLogScale.plotValue(reasoningTokens) }
}

enum TimelineLogScale {
    static let floor = 1.0

    static func plotValue(_ tokens: Int) -> Double {
        max(floor, Double(tokens))
    }

    static func domain(for tokenValues: [Int]) -> ClosedRange<Double> {
        let maximum = tokenValues.map(plotValue).max() ?? floor
        guard maximum > floor else {
            return floor...10
        }

        let exponent = ceil(log10(maximum))
        return floor...max(10, pow(10, exponent))
    }
}

struct TimelineDualLogScale: Equatable {
    let turnDomain: ClosedRange<Double>
    let callDomain: ClosedRange<Double>

    init(turnValues: [Int], callValues: [Int]) {
        turnDomain = TimelineLogScale.domain(for: turnValues)
        callDomain = TimelineLogScale.domain(for: callValues)
    }

    var turnTickPositions: [Double] {
        Self.tickPositions(for: turnDomain)
    }

    var callTickPositions: [Double] {
        Self.tickPositions(for: callDomain)
    }

    func turnPosition(for tokens: Int) -> Double {
        Self.position(for: tokens, domain: turnDomain)
    }

    func callPosition(for tokens: Int) -> Double {
        Self.position(for: tokens, domain: callDomain)
    }

    func turnLabel(at position: Double) -> Int {
        Self.tokenValue(at: position, domain: turnDomain)
    }

    func callLabel(at position: Double) -> Int {
        Self.tokenValue(at: position, domain: callDomain)
    }

    private static func position(for tokens: Int, domain: ClosedRange<Double>) -> Double {
        let value = TimelineLogScale.plotValue(tokens)
        let lower = log10(domain.lowerBound)
        let upper = log10(domain.upperBound)
        guard upper > lower else {
            return 0
        }
        return min(max((log10(value) - lower) / (upper - lower), 0), 1)
    }

    private static func tokenValue(at position: Double, domain: ClosedRange<Double>) -> Int {
        let lower = log10(domain.lowerBound)
        let upper = log10(domain.upperBound)
        let exponent = lower + min(max(position, 0), 1) * (upper - lower)
        return Int(pow(10, exponent).rounded())
    }

    private static func tickPositions(for domain: ClosedRange<Double>) -> [Double] {
        let lowerExponent = Int(log10(domain.lowerBound).rounded())
        let upperExponent = Int(log10(domain.upperBound).rounded())
        let span = max(1, upperExponent - lowerExponent)
        return (lowerExponent...upperExponent).map {
            Double($0 - lowerExponent) / Double(span)
        }
    }
}

struct ThreadTimelineSeries: Identifiable, Equatable {
    let threadID: String
    let projectName: String
    let threadTitle: String
    let colorIndex: Int
    let points: [TimelinePoint]

    var id: String { threadID }

    var shortLabel: String {
        let normalizedTitle = threadTitle
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalizedTitle.count > 24
            ? String(normalizedTitle.prefix(23)) + "…"
            : normalizedTitle
        return projectName == title ? projectName : "\(projectName) / \(title)"
    }

    var latestTimestamp: Date {
        points.last?.timestamp ?? .distantPast
    }
}

struct ReasoningSampleSummary: Equatable {
    let count: Int
    let minimum: Int
    let maximum: Int
    let median: Int
    let duration: TimeInterval

    init(samples: [TimelineSamplePoint]) {
        let values = samples.map(\.reasoningTokens).sorted()
        count = values.count
        minimum = values.first ?? 0
        maximum = values.last ?? 0
        median = values.isEmpty ? 0 : values[values.count / 2]
        if let first = samples.first?.timestamp, let last = samples.last?.timestamp {
            duration = max(0, last.timeIntervalSince(first))
        } else {
            duration = 0
        }
    }
}

enum TimelineSampleDownsampler {
    static func reduce(_ samples: [TimelineSamplePoint], limit: Int) -> [TimelineSamplePoint] {
        let sorted = samples.sorted(by: sampleDateAscending)
        guard limit > 2, sorted.count > limit else {
            return sorted
        }

        let interior = Array(sorted.dropFirst().dropLast())
        let pairBudget = max(1, (limit - 2) / 2)
        let bucketSize = Double(interior.count) / Double(pairBudget)
        var selected: [TimelineSamplePoint] = [sorted[0]]

        for bucket in 0..<pairBudget {
            let lower = Int((Double(bucket) * bucketSize).rounded(.down))
            let upper = min(
                interior.count,
                Int((Double(bucket + 1) * bucketSize).rounded(.up))
            )
            guard lower < upper else {
                continue
            }

            let slice = interior[lower..<upper]
            guard let minimum = slice.min(by: sampleValueAscending),
                  let maximum = slice.max(by: sampleValueAscending) else {
                continue
            }
            if minimum.id == maximum.id {
                selected.append(minimum)
            } else if sampleDateAscending(minimum, maximum) {
                selected.append(contentsOf: [minimum, maximum])
            } else {
                selected.append(contentsOf: [maximum, minimum])
            }
        }

        selected.append(sorted[sorted.count - 1])
        return Array(
            selected
                .reduce(into: [String: TimelineSamplePoint]()) { result, sample in
                    result[sample.id] = sample
                }
                .values
                .sorted(by: sampleDateAscending)
                .prefix(limit)
        )
    }

    private static func sampleDateAscending(_ left: TimelineSamplePoint, _ right: TimelineSamplePoint) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp < right.timestamp
        }
        return left.id < right.id
    }

    private static func sampleValueAscending(_ left: TimelineSamplePoint, _ right: TimelineSamplePoint) -> Bool {
        if left.reasoningTokens != right.reasoningTokens {
            return left.reasoningTokens < right.reasoningTokens
        }
        return sampleDateAscending(left, right)
    }
}

enum TimelinePresentationBuilder {
    static func build(
        sessions: [CompletedSession],
        searchQuery: String,
        window: TimelineWindow,
        now: Date,
        pointLimit: Int = 240,
        paletteCount: Int = 8
    ) -> [ThreadTimelineSeries] {
        let cutoff = now.addingTimeInterval(-window.duration)
        var sessionsByTurnKey: [String: CompletedSession] = [:]

        for session in sessions {
            guard let timestamp = timestamp(for: session),
                  timestamp >= cutoff,
                  timestamp <= now else {
                continue
            }

            let pointID = session.turnKey ?? session.key
            guard let existing = sessionsByTurnKey[pointID] else {
                sessionsByTurnKey[pointID] = session
                continue
            }

            if shouldReplace(existing: existing, with: session) {
                sessionsByTurnKey[pointID] = session
            }
        }

        let points = sessionsByTurnKey
            .compactMap { pointID, session -> TimelinePoint? in
                guard let timestamp = timestamp(for: session) else {
                    return nil
                }
                return TimelinePoint(id: pointID, session: session, timestamp: timestamp)
            }
            .sorted(by: pointDateAscending)

        let limitedPoints = Array(points.suffix(max(1, pointLimit)))
        let grouped = Dictionary(grouping: limitedPoints, by: \.threadID)
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return grouped
            .compactMap { threadID, threadPoints -> ThreadTimelineSeries? in
                let sortedPoints = threadPoints.sorted(by: pointDateAscending)
                guard let representative = sortedPoints.last?.session else {
                    return nil
                }

                if normalizedQuery.isEmpty == false,
                   sortedPoints.contains(where: { $0.session.matches(searchQuery: normalizedQuery) }) == false {
                    return nil
                }

                return ThreadTimelineSeries(
                    threadID: threadID,
                    projectName: representative.projectName,
                    threadTitle: representative.threadTitle,
                    colorIndex: stablePaletteIndex(threadID: threadID, paletteCount: paletteCount),
                    points: sortedPoints
                )
            }
            .sorted { left, right in
                if left.latestTimestamp != right.latestTimestamp {
                    return left.latestTimestamp > right.latestTimestamp
                }
                return left.threadID < right.threadID
            }
    }

    static func stablePaletteIndex(threadID: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else {
            return 0
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in threadID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }

    private static func shouldReplace(existing: CompletedSession, with candidate: CompletedSession) -> Bool {
        let existingIsLive = existing.key.hasPrefix("live:")
        let candidateIsLive = candidate.key.hasPrefix("live:")

        if existingIsLive != candidateIsLive {
            return existingIsLive && candidateIsLive == false
        }

        let existingDate = timestamp(for: existing) ?? .distantPast
        let candidateDate = timestamp(for: candidate) ?? .distantPast
        if existingDate != candidateDate {
            return candidateDate > existingDate
        }
        return candidate.key > existing.key
    }

    private static func timestamp(for session: CompletedSession) -> Date? {
        session.completedAt ?? session.startedAt
    }

    private static func pointDateAscending(_ left: TimelinePoint, _ right: TimelinePoint) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp < right.timestamp
        }
        return left.id < right.id
    }
}

struct TimelineRenderedPoint: Equatable {
    let pointID: String
    let position: CGPoint
}

struct TimelineRenderedSeries: Equatable {
    let threadID: String
    let points: [TimelineRenderedPoint]
    let lineRuns: [[CGPoint]]

    init(
        threadID: String,
        points: [TimelineRenderedPoint],
        lineRuns: [[CGPoint]] = []
    ) {
        self.threadID = threadID
        self.points = points
        self.lineRuns = lineRuns
    }
}

enum TimelineHitTarget: Equatable {
    case point(String)
    case thread(String)
}

enum TimelineHitTester {
    static func hitTest(
        location: CGPoint,
        series: [TimelineRenderedSeries],
        nodeRadius: CGFloat = 12,
        lineTolerance: CGFloat = 8
    ) -> TimelineHitTarget? {
        let nearestPoint = series
            .flatMap(\.points)
            .map { point in
                (point: point, distance: distance(location, point.position))
            }
            .filter { $0.distance <= nodeRadius }
            .min { $0.distance < $1.distance }

        if let nearestPoint {
            return .point(nearestPoint.point.pointID)
        }

        let nearestLine = series.compactMap { item -> (threadID: String, distance: CGFloat)? in
            let lineRuns = item.lineRuns + [item.points.map(\.position)]
            let segmentDistances = lineRuns.flatMap { run in
                zip(run, run.dropFirst()).map { left, right in
                    distanceFromPoint(location, toSegmentFrom: left, to: right)
                }
            }
            guard let minimumDistance = segmentDistances.min() else {
                return nil
            }
            return (item.threadID, minimumDistance)
        }
        .filter { $0.distance <= lineTolerance }
        .min { $0.distance < $1.distance }

        return nearestLine.map { .thread($0.threadID) }
    }

    private static func distance(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
        hypot(left.x - right.x, left.y - right.y)
    }

    private static func distanceFromPoint(
        _ point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return distance(point, start)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clamped = min(max(projection, 0), 1)
        let closest = CGPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
        return distance(point, closest)
    }
}
