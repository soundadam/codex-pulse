import Foundation

public actor RolloutParser {
    private struct CacheEntry {
        let modifiedAt: Date
        let fileSize: UInt64
        let parsed: ParsedRollout
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
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func parse(path: String) throws -> ParsedRollout {
        let fileURL = URL(fileURLWithPath: path)
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let fileSize = attributes[.size] as? UInt64 ?? 0

        if let entry = cache[path],
           entry.modifiedAt == modifiedAt,
           entry.fileSize == fileSize {
            return entry.parsed
        }

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let parsed = parseRolloutText(text)
        cache[path] = CacheEntry(modifiedAt: modifiedAt, fileSize: fileSize, parsed: parsed)
        return parsed
    }

    func parseRolloutText(_ text: String) -> ParsedRollout {
        var turns: [LatestTurn] = []
        var currentTurn: MutableTurn?

        func finishCurrentTurn(fallbackStatus: TurnStatus?, timestamp: Date?) {
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

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            let timestamp = CoreDateParser.parse(object["timestamp"] as? String)

            switch type {
            case "turn_context":
                finishCurrentTurn(fallbackStatus: .unknown, timestamp: timestamp)
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
                    continue
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
                    continue
                }
                let payload = object["payload"] as? [String: Any] ?? [:]
                guard payload["type"] as? String == "message",
                      let content = payload["content"] as? [[String: Any]] else {
                    continue
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

        finishCurrentTurn(fallbackStatus: nil, timestamp: nil)
        return ParsedRollout(turns: turns, latestTurn: turns.last)
    }

    private func normalizeUsage(_ rawValue: Any?) -> TurnUsage {
        normalizeOptionalUsage(rawValue) ?? .zero
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
