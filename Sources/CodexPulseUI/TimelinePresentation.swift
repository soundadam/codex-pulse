import Core
import CoreGraphics
import Foundation

enum TimelineWindow: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case threeHours
    case sixHours
    case twelveHours
    case oneDay

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .oneHour:
            return 60 * 60
        case .threeHours:
            return 3 * 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twelveHours:
            return 12 * 60 * 60
        case .oneDay:
            return 24 * 60 * 60
        }
    }

    var shortLabel: String {
        switch self {
        case .oneHour:
            return "1h"
        case .threeHours:
            return "3h"
        case .sixHours:
            return "6h"
        case .twelveHours:
            return "12h"
        case .oneDay:
            return "24h"
        }
    }

    var fetchMultiplier: Int {
        switch self {
        case .oneHour:
            return 1
        case .threeHours:
            return 2
        case .sixHours:
            return 3
        case .twelveHours:
            return 4
        case .oneDay:
            return 6
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
    var turnTotalTokens: Int {
        let total = session.tokenUsage.total
        let reconstructedTotal = total.inputTokens + total.outputTokens
        return max(total.totalTokens, reconstructedTotal, turnTotalReasoningTokens)
    }
    var isRunning: Bool { session.monitorState == .running }

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

}

struct TimelineSamplePoint: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let reasoningTokens: Int
    let isInvalid: Bool

    init(
        id: String,
        timestamp: Date,
        reasoningTokens: Int,
        isInvalid: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.reasoningTokens = reasoningTokens
        self.isInvalid = isInvalid
    }
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

enum TimelineLinearScale {
    static func domain(for tokenValues: [Int]) -> ClosedRange<Double> {
        let maximum = Double(tokenValues.map { max(0, $0) }.max() ?? 0)
        guard maximum > 10 else {
            return 0...10
        }
        let magnitude = pow(10, floor(log10(maximum)))
        let upperBound = ceil(maximum / magnitude) * magnitude
        return 0...upperBound
    }

    static func axisValues(for domain: ClosedRange<Double>) -> [Double] {
        [domain.lowerBound, domain.upperBound / 2, domain.upperBound]
    }
}

struct TimelineNodeSizeScale: Equatable {
    let tokenDomain: ClosedRange<Double>
    let diameterRange: ClosedRange<Double>

    init(
        tokenValues: [Int],
        diameterRange: ClosedRange<Double> = 8...22
    ) {
        let values = tokenValues.map { log1p(Double(max(0, $0))) }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        tokenDomain = minimum...maximum
        self.diameterRange = diameterRange
    }

    func diameter(for tokens: Int) -> Double {
        guard tokenDomain.upperBound > tokenDomain.lowerBound else {
            return diameterRange.lowerBound
        }
        let value = log1p(Double(max(0, tokens)))
        let normalized = min(
            max((value - tokenDomain.lowerBound) / (tokenDomain.upperBound - tokenDomain.lowerBound), 0),
            1
        )
        let minimumArea = diameterRange.lowerBound * diameterRange.lowerBound
        let maximumArea = diameterRange.upperBound * diameterRange.upperBound
        return sqrt(minimumArea + normalized * (maximumArea - minimumArea))
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

/// Immutable, already-derived chart input. SwiftUI can read this value as often
/// as it needs without repeating timeline filtering, de-duplication, sorting,
/// scale calculation, or lookup construction.
struct TimelinePresentation: Equatable {
    let series: [ThreadTimelineSeries]
    let points: [TimelinePoint]
    let pointsByID: [String: TimelinePoint]
    let seriesByThreadID: [String: ThreadTimelineSeries]
    let dateDomain: ClosedRange<Date>
    let reasoningDomain: ClosedRange<Double>
    let nodeSizeScale: TimelineNodeSizeScale
    let invalidTurnCount: Int
    let observedTurnCount: Int
    let unknownTurnCount: Int

    static func empty(window: TimelineWindow, referenceDate: Date) -> TimelinePresentation {
        let upperBound = TimelinePresentationBuilder.alignedUpperBound(for: referenceDate)
        return TimelinePresentation(
            series: [],
            points: [],
            pointsByID: [:],
            seriesByThreadID: [:],
            dateDomain: upperBound.addingTimeInterval(-window.duration)...upperBound,
            reasoningDomain: TimelineLogScale.floor...10,
            nodeSizeScale: TimelineNodeSizeScale(tokenValues: []),
            invalidTurnCount: 0,
            observedTurnCount: 0,
            unknownTurnCount: 0
        )
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
        return preserveInvalidSamples(
            in: sorted,
            preferredSamples: selected,
            limit: limit
        )
    }

    private static func preserveInvalidSamples(
        in sorted: [TimelineSamplePoint],
        preferredSamples: [TimelineSamplePoint],
        limit: Int
    ) -> [TimelineSamplePoint] {
        let endpoints = deduplicated([sorted[0], sorted[sorted.count - 1]])
        let endpointIDs = Set(endpoints.map(\.id))
        let invalidInterior = sorted.filter {
            $0.isInvalid && endpointIDs.contains($0.id) == false
        }

        if endpoints.count + invalidInterior.count >= limit {
            let retainedInvalid = evenlyDistributed(
                invalidInterior,
                count: max(0, limit - endpoints.count)
            )
            return (endpoints + retainedInvalid).sorted(by: sampleDateAscending)
        }

        let protected = endpoints + invalidInterior
        let protectedIDs = Set(protected.map(\.id))
        let optional = deduplicated(preferredSamples)
            .filter { protectedIDs.contains($0.id) == false }
        let retainedOptional = evenlyDistributed(
            optional,
            count: min(optional.count, limit - protected.count)
        )
        return (protected + retainedOptional).sorted(by: sampleDateAscending)
    }

    private static func evenlyDistributed(
        _ samples: [TimelineSamplePoint],
        count: Int
    ) -> [TimelineSamplePoint] {
        guard count > 0, samples.isEmpty == false else {
            return []
        }
        guard count < samples.count else {
            return samples
        }
        guard count > 1 else {
            return [samples[samples.count / 2]]
        }
        return (0..<count).map { index in
            let position = Double(index) * Double(samples.count - 1) / Double(count - 1)
            return samples[Int(position.rounded())]
        }
    }

    private static func deduplicated(
        _ samples: [TimelineSamplePoint]
    ) -> [TimelineSamplePoint] {
        Array(
            samples
                .reduce(into: [String: TimelineSamplePoint]()) { result, sample in
                    result[sample.id] = sample
                }
                .values
                .sorted(by: sampleDateAscending)
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
    /// The visible clock advances at minute granularity. New realtime points
    /// still rebuild immediately, while an unchanged chart does not shift and
    /// re-layout every three seconds merely because wall clock time advanced.
    static func alignedUpperBound(for date: Date) -> Date {
        let minute: TimeInterval = 60
        let timestamp = date.timeIntervalSinceReferenceDate
        return Date(
            timeIntervalSinceReferenceDate: ceil(timestamp / minute) * minute
        )
    }

    static func makePresentation(
        sessions: [CompletedSession],
        searchQuery: String,
        window: TimelineWindow,
        now: Date,
        pointLimit: Int = 240,
        paletteCount: Int = 8
    ) -> TimelinePresentation {
        let upperBound = alignedUpperBound(for: now)
        let series = build(
            sessions: sessions,
            searchQuery: searchQuery,
            window: window,
            now: upperBound,
            pointLimit: pointLimit,
            paletteCount: paletteCount
        )
        let points = series
            .flatMap(\.points)
            .sorted(by: pointDateAscending)

        return TimelinePresentation(
            series: series,
            points: points,
            pointsByID: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            seriesByThreadID: Dictionary(uniqueKeysWithValues: series.map { ($0.threadID, $0) }),
            dateDomain: upperBound.addingTimeInterval(-window.duration)...upperBound,
            reasoningDomain: TimelineLogScale.domain(
                for: points.map(\.turnTotalReasoningTokens)
            ),
            nodeSizeScale: TimelineNodeSizeScale(
                tokenValues: points.map(\.turnTotalTokens)
            ),
            invalidTurnCount: points.lazy.filter {
                $0.session.signalState == .invalid
            }.count,
            observedTurnCount: points.lazy.filter {
                $0.session.signalState == .valid
            }.count,
            unknownTurnCount: points.lazy.filter {
                $0.session.signalState == .unknown
            }.count
        )
    }

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
            let lineRuns = item.lineRuns.isEmpty
                ? [item.points.map(\.position)]
                : item.lineRuns
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
