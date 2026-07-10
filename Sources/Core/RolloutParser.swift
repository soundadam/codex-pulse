import Foundation

public actor RolloutParser {
    private struct CacheEntry {
        let modifiedAt: Date
        let fileSize: UInt64
        let fileIdentifier: UInt64?
        let detailCutoff: Date
        let parsed: ParsedRollout
        let latestReasoningSamples: [TurnReasoningSample]
        let fileTail: Data
        let canAppendIncrementally: Bool
    }

    private struct MutableTurn {
        let turnId: String?
        let startedAt: Date?
        let model: String?
        let reasoningEffort: String?
        var completedAt: Date?
        var status: TurnStatus
        var usage: TurnUsage
        var lastTokenUsage: TurnUsage
        var totalTokenUsage: TurnUsage?
        var reasoningSamples: [TurnReasoningSample]
        var lastAgentMessage: String?

        func freeze() -> LatestTurn {
            LatestTurn(
                turnId: turnId,
                status: status,
                startedAt: startedAt,
                completedAt: completedAt,
                model: model,
                reasoningEffort: reasoningEffort,
                usage: usage,
                lastAgentMessage: lastAgentMessage,
                tokenUsage: TurnTokenUsageSnapshot(
                    last: lastTokenUsage,
                    total: totalTokenUsage ?? usage
                ),
                reasoningSamples: reasoningSamples
            )
        }
    }

    private var cache: [String: CacheEntry] = [:]
    private var cacheRecency: [String] = []
    private let fileManager: FileManager
    private let cacheCapacity: Int
    private(set) var fullFileParseCount = 0
    private(set) var incrementalFileParseCount = 0

    public init(
        fileManager: FileManager = .default,
        cacheCapacity: Int = 256
    ) {
        self.fileManager = fileManager
        self.cacheCapacity = max(1, cacheCapacity)
    }

    public func parse(
        path: String,
        detailCutoff: Date = .distantPast
    ) throws -> ParsedRollout {
        let fileURL = URL(fileURLWithPath: path)
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let fileSize = attributes[.size] as? UInt64 ?? 0
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        if let entry = cache[path],
           entry.modifiedAt == modifiedAt,
           entry.fileSize == fileSize,
           detailCutoff >= entry.detailCutoff {
            touchCacheEntry(path)
            return entry.parsed
        }

        let parsed: ParsedRollout
        if let entry = cache[path],
           fileSize > entry.fileSize,
           fileIdentifier == entry.fileIdentifier,
           detailCutoff >= entry.detailCutoff,
           entry.canAppendIncrementally,
           try fileTailMatches(entry, fileURL: fileURL) {
            incrementalFileParseCount += 1
            parsed = try parseRolloutFile(
                fileURL,
                startingAt: entry.fileSize,
                cachedEntry: entry
            )
        } else {
            fullFileParseCount += 1
            parsed = try parseRolloutFile(fileURL)
        }

        let retainedParsed = parsed.retainingReasoningSamples(since: detailCutoff)
        let fileTail = try readFileTail(fileURL, fileSize: fileSize)
        cache[path] = CacheEntry(
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            fileIdentifier: fileIdentifier,
            detailCutoff: detailCutoff,
            parsed: parsed.withoutReasoningSamples(),
            latestReasoningSamples: retainedParsed.latestTurn?.reasoningSamples ?? [],
            fileTail: fileTail,
            canAppendIncrementally: fileTail.last == 0x0A
        )
        touchCacheEntry(path)
        evictCacheEntriesIfNeeded()
        return retainedParsed
    }

    func parseRolloutText(_ text: String) -> ParsedRollout {
        var turns: [LatestTurn] = []
        var currentTurn: MutableTurn?

        for line in text.split(whereSeparator: \.isNewline) {
            if let data = line.data(using: .utf8) {
                consumeLine(data, turns: &turns, currentTurn: &currentTurn)
            }
        }

        finishCurrentTurn(
            turns: &turns,
            currentTurn: &currentTurn,
            fallbackStatus: nil,
            timestamp: nil
        )
        return ParsedRollout(turns: turns, latestTurn: turns.last)
    }

    private func parseRolloutFile(
        _ fileURL: URL,
        startingAt offset: UInt64 = 0,
        cachedEntry: CacheEntry? = nil
    ) throws -> ParsedRollout {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: offset)
        }

        let chunkSize = 256 * 1_024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var turns = cachedEntry?.parsed.turns ?? []
        var currentTurn: MutableTurn?
        if let cachedEntry, let latestTurn = turns.popLast() {
            currentTurn = mutableTurn(
                from: latestTurn,
                reasoningSamples: cachedEntry.latestReasoningSamples
            )
        }

        while let chunk = try handle.read(upToCount: chunkSize), chunk.isEmpty == false {
            buffer.append(chunk)
            var lineStart = buffer.startIndex

            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                if newline > lineStart {
                    let line = Data(buffer[lineStart..<newline])
                    autoreleasepool {
                        consumeLine(line, turns: &turns, currentTurn: &currentTurn)
                    }
                }
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if buffer.isEmpty == false {
            autoreleasepool {
                consumeLine(buffer, turns: &turns, currentTurn: &currentTurn)
            }
        }

        finishCurrentTurn(
            turns: &turns,
            currentTurn: &currentTurn,
            fallbackStatus: nil,
            timestamp: nil
        )
        return ParsedRollout(turns: turns, latestTurn: turns.last)
    }

    private func mutableTurn(
        from turn: LatestTurn,
        reasoningSamples: [TurnReasoningSample]
    ) -> MutableTurn {
        MutableTurn(
            turnId: turn.turnId,
            startedAt: turn.startedAt,
            model: turn.model,
            reasoningEffort: turn.reasoningEffort,
            completedAt: turn.completedAt,
            status: turn.status,
            usage: turn.usage,
            lastTokenUsage: turn.tokenUsage.last,
            totalTokenUsage: turn.tokenUsage.total,
            reasoningSamples: reasoningSamples,
            lastAgentMessage: turn.lastAgentMessage
        )
    }

    private func fileTailMatches(
        _ entry: CacheEntry,
        fileURL: URL
    ) throws -> Bool {
        guard entry.fileTail.isEmpty == false else {
            return entry.fileSize == 0
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let start = entry.fileSize - UInt64(entry.fileTail.count)
        try handle.seek(toOffset: start)
        return try handle.read(upToCount: entry.fileTail.count) == entry.fileTail
    }

    private func readFileTail(
        _ fileURL: URL,
        fileSize: UInt64
    ) throws -> Data {
        guard fileSize > 0 else {
            return Data()
        }
        let count = Int(min(fileSize, 4_096))
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: fileSize - UInt64(count))
        return try handle.read(upToCount: count) ?? Data()
    }

    private func touchCacheEntry(_ path: String) {
        cacheRecency.removeAll(where: { $0 == path })
        cacheRecency.append(path)
    }

    private func evictCacheEntriesIfNeeded() {
        while cacheRecency.count > cacheCapacity {
            let path = cacheRecency.removeFirst()
            cache.removeValue(forKey: path)
        }
    }

    private func consumeLine(
        _ data: Data,
        turns: inout [LatestTurn],
        currentTurn: inout MutableTurn?
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        let timestamp = CoreDateParser.parse(object["timestamp"] as? String)

        switch type {
        case "turn_context":
            finishCurrentTurn(
                turns: &turns,
                currentTurn: &currentTurn,
                fallbackStatus: .unknown,
                timestamp: timestamp
            )
            let payload = object["payload"] as? [String: Any] ?? [:]
            currentTurn = MutableTurn(
                turnId: payload["turn_id"] as? String ?? payload["turnId"] as? String,
                startedAt: timestamp,
                model: payload["model"] as? String,
                reasoningEffort: payload["effort"] as? String,
                completedAt: nil,
                status: .running,
                usage: .zero,
                lastTokenUsage: .zero,
                totalTokenUsage: nil,
                reasoningSamples: [],
                lastAgentMessage: nil
            )

        case "event_msg":
            guard currentTurn != nil else {
                return
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String ?? ""
            switch payloadType {
            case "token_count":
                if let info = payload["info"] as? [String: Any],
                   var turn = currentTurn {
                    let lastUsage = normalizeOptionalUsage(info["last_token_usage"])
                    if let lastUsage {
                        turn.usage.add(lastUsage)
                        turn.lastTokenUsage = lastUsage
                        if info["total_token_usage"] == nil {
                            turn.totalTokenUsage = turn.usage
                        }
                    }
                    if let totalUsage = normalizeOptionalUsage(info["total_token_usage"]) {
                        turn.totalTokenUsage = totalUsage
                    }
                    if let lastUsage, let timestamp {
                        turn.reasoningSamples.append(
                            TurnReasoningSample(
                                observedAt: timestamp,
                                tokenUsage: TurnTokenUsageSnapshot(
                                    last: lastUsage,
                                    total: turn.totalTokenUsage ?? turn.usage
                                )
                            )
                        )
                    }
                    currentTurn = turn
                }
            case "agent_message":
                if let message = payload["message"] as? String,
                   message.isEmpty == false {
                    currentTurn?.lastAgentMessage = message
                }
            case "task_complete":
                currentTurn?.status = .completed
                currentTurn?.completedAt = timestamp
            case "turn_aborted":
                currentTurn?.status = .aborted
                currentTurn?.completedAt = timestamp
            case "thread_rolled_back":
                currentTurn?.status = .rolledBack
                currentTurn?.completedAt = timestamp
            default:
                break
            }

        case "response_item":
            guard currentTurn != nil else {
                return
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            guard payload["type"] as? String == "message",
                  let content = payload["content"] as? [[String: Any]] else {
                return
            }
            let outputText = content
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if outputText.isEmpty == false {
                currentTurn?.lastAgentMessage = outputText
            }

        default:
            break
        }
    }

    private func finishCurrentTurn(
        turns: inout [LatestTurn],
        currentTurn: inout MutableTurn?,
        fallbackStatus: TurnStatus?,
        timestamp: Date?
    ) {
        guard var mutableTurn = currentTurn else {
            return
        }
        if mutableTurn.status == .running, let fallbackStatus {
            mutableTurn.status = fallbackStatus
        }
        if mutableTurn.completedAt == nil, let timestamp {
            mutableTurn.completedAt = timestamp
        }
        turns.append(mutableTurn.freeze())
        currentTurn = nil
    }

    private func normalizeOptionalUsage(_ rawValue: Any?) -> TurnUsage? {
        guard let raw = rawValue as? [String: Any] else {
            return nil
        }
        return TurnUsage(
            inputTokens: raw.intValue(for: "input_tokens", fallback: "inputTokens"),
            cachedInputTokens: raw.intValue(for: "cached_input_tokens", fallback: "cachedInputTokens"),
            outputTokens: raw.intValue(for: "output_tokens", fallback: "outputTokens"),
            reasoningOutputTokens: raw.intValue(for: "reasoning_output_tokens", fallback: "reasoningOutputTokens"),
            totalTokens: raw.intValue(for: "total_tokens", fallback: "totalTokens")
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func intValue(for key: String, fallback: String) -> Int {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[fallback] as? Int {
            return value
        }
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        if let number = self[fallback] as? NSNumber {
            return number.intValue
        }
        return 0
    }
}
