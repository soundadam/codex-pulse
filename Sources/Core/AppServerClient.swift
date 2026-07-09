import Foundation

public enum AppServerClientError: Error, LocalizedError, Equatable {
    case startBackoff(until: Date)
    case invalidResponse
    case requestTimedOut(method: String)
    case requestFailed(message: String)
    case processExited(code: Int32, stderr: String)
    case launchFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .startBackoff(until):
            return "app-server restart delayed until \(until.formatted(date: .omitted, time: .standard))"
        case .invalidResponse:
            return "app-server returned an invalid response"
        case let .requestTimedOut(method):
            return "app-server request timed out: \(method)"
        case let .requestFailed(message):
            return message
        case let .processExited(code, stderr):
            if stderr.isEmpty {
                return "app-server exited with code \(code)"
            }
            return "app-server exited with code \(code): \(stderr)"
        case let .launchFailed(message):
            return message
        }
    }
}

public struct AppServerLaunchConfiguration: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    public static func codexAppServer(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppServerLaunchConfiguration {
        AppServerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["codex", "app-server"],
            environment: buildLaunchEnvironment(from: processEnvironment)
        )
    }

    private static func buildLaunchEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        let existingPath = base["PATH"] ?? ""
        let staticPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var ordered: [String] = []
        var seen = Set<String>()
        for component in existingPath.split(separator: ":").map(String.init) + staticPaths {
            if seen.insert(component).inserted {
                ordered.append(component)
            }
        }
        environment["PATH"] = ordered.joined(separator: ":")
        return environment
    }
}

private struct JSONRPCInitializeParams: Encodable {
    struct ClientInfo: Encodable {
        let name: String
        let title: String
        let version: String
    }

    struct Capabilities: Encodable {
        let experimentalApi: Bool
    }

    let clientInfo = ClientInfo(
        name: "codex_rollout_inspector",
        title: "Codex Rollout Inspector",
        version: "0.1.0"
    )
    let capabilities = Capabilities(experimentalApi: true)
}

private struct JSONRPCRequest<Params: Encodable>: Encodable {
    let method: String
    let id: Int
    let params: Params
}

private struct JSONRPCNotification<Params: Encodable>: Encodable {
    let method: String
    let params: Params
}

private struct ThreadListParams: Encodable {
    let limit: Int
    let cursor: String?
    let cwd: [String]?
}

private struct ThreadListResult {
    let data: [ThreadListItem]
    let nextCursor: String?
}

private struct ThreadListItem {
    let id: String
    let name: String?
    let preview: String?
    let source: String?
    let cwd: String?
    let path: String?
    let updatedAt: Date?
}

public actor AppServerClient: ThreadDiscoveryService {
    private struct PendingRequest {
        let method: String
        let timeoutTask: Task<Void, Never>
        let continuation: CheckedContinuation<Data, Error>
    }

    private let launchConfiguration: AppServerLaunchConfiguration
    private let requestTimeout: Duration
    private let baseBackoff: Duration
    private let maxBackoff: Duration
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrLineBuffer = Data()
    private var stderrBuffer = ""
    private var isInitialized = false
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var currentBackoff: Duration
    private var nextStartAllowedAt = ContinuousClock().now

    public init(
        launchConfiguration: AppServerLaunchConfiguration = .codexAppServer(),
        requestTimeout: Duration = .seconds(30),
        baseBackoff: Duration = .seconds(1),
        maxBackoff: Duration = .seconds(30)
    ) {
        self.launchConfiguration = launchConfiguration
        self.requestTimeout = requestTimeout
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.currentBackoff = baseBackoff
        decoder.keyDecodingStrategy = .useDefaultKeys
    }

    deinit {
        stdinHandle?.closeFile()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        process?.terminate()
    }

    public func listThreads(limit: Int, cwdFilters: [String]) async throws -> [CodexThreadRef] {
        let requestedLimit = max(limit, 1)
        var threads: [CodexThreadRef] = []
        var cursor: String?

        while threads.count < requestedLimit {
            let pageLimit = min(max(requestedLimit - threads.count, 1), 100)
            let resultData = try await request(
                method: "thread/list",
                params: ThreadListParams(
                    limit: pageLimit,
                    cursor: cursor,
                    cwd: cwdFilters.isEmpty ? nil : cwdFilters
                )
            )
            let result = try parseThreadListResult(from: resultData)
            threads.append(contentsOf: result.data.map(makeThreadRef))
            guard let nextCursor = result.nextCursor, threads.count < requestedLimit else {
                break
            }
            cursor = nextCursor
        }

        return Array(threads.prefix(requestedLimit))
    }

    public func shutdown() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrLineBuffer.removeAll(keepingCapacity: false)

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CancellationError())
        }

        stdinHandle?.closeFile()
        stdinHandle?.closeFile()
        stdinHandle = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        isInitialized = false
    }

    private func makeThreadRef(from item: ThreadListItem) -> CodexThreadRef {
        CodexThreadRef(
            id: item.id,
            name: item.name,
            preview: item.preview ?? "",
            source: item.source,
            cwd: item.cwd,
            rolloutPath: item.path,
            updatedAt: item.updatedAt
        )
    }

    private func parseThreadListResult(from data: Data) throws -> ThreadListResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = object["data"] as? [[String: Any]] else {
            throw AppServerClientError.invalidResponse
        }

        let items = rawItems.compactMap(parseThreadListItem)
        let nextCursor = object["nextCursor"] as? String
        return ThreadListResult(data: items, nextCursor: nextCursor)
    }

    private func parseThreadListItem(_ raw: [String: Any]) -> ThreadListItem? {
        guard let id = raw["id"] as? String else {
            return nil
        }

        return ThreadListItem(
            id: id,
            name: raw["name"] as? String,
            preview: raw["preview"] as? String,
            source: raw["source"] as? String,
            cwd: raw["cwd"] as? String,
            path: raw["path"] as? String,
            updatedAt: parseFlexibleDate(raw["updatedAt"])
        )
    }

    private func parseFlexibleDate(_ raw: Any?) -> Date? {
        switch raw {
        case let text as String:
            return CoreDateParser.parse(text)
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        default:
            return nil
        }
    }

    private func request<Params: Encodable>(method: String, params: Params) async throws -> Data {
        try await ensureConnected()
        return try await sendRequestAwaitingResponse(method: method, params: params)
    }

    private func sendRequestAwaitingResponse<Params: Encodable>(
        method: String,
        params: Params
    ) async throws -> Data {
        let requestID = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                await self.timeoutRequest(id: requestID, method: method)
            }

            pendingRequests[requestID] = PendingRequest(
                method: method,
                timeoutTask: timeoutTask,
                continuation: continuation
            )

            do {
                try sendRequest(
                    JSONRPCRequest(
                        method: method,
                        id: requestID,
                        params: params
                    )
                )
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func ensureConnected() async throws {
        if let process, process.isRunning, isInitialized {
            return
        }

        let now = ContinuousClock.Instant.now
        if now < nextStartAllowedAt {
            let date = Date().addingTimeInterval((nextStartAllowedAt - now).timeInterval)
            throw AppServerClientError.startBackoff(until: date)
        }

        try await startProcess()
        do {
            _ = try await sendRequestAwaitingResponse(method: "initialize", params: JSONRPCInitializeParams())
            try sendNotification(JSONRPCNotification(method: "initialized", params: EmptyParams()))
            isInitialized = true
            currentBackoff = baseBackoff
            nextStartAllowedAt = now
        } catch {
            await handleFailure(error)
            throw error
        }
    }

    private func startProcess() async throws {
        if let process, process.isRunning {
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.arguments
        process.environment = launchConfiguration.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrBuffer = ""
        isInitialized = false

        do {
            try process.run()
        } catch {
            scheduleBackoff()
            throw AppServerClientError.launchFailed(message: error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                return
            }
            Task {
                await self.consumeStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                return
            }
            Task {
                await self.consumeStderr(data)
            }
        }

        process.terminationHandler = { [weak process] terminatedProcess in
            let code = terminatedProcess.terminationStatus
            Task {
                await self.processDidTerminate(code: code)
                _ = process
            }
        }
    }

    private func sendRequest<Params: Encodable>(_ request: JSONRPCRequest<Params>) throws {
        let data = try encoder.encode(request)
        try writeLine(data)
    }

    private func sendNotification<Params: Encodable>(_ notification: JSONRPCNotification<Params>) throws {
        let data = try encoder.encode(notification)
        try writeLine(data)
    }

    private func writeLine(_ data: Data) throws {
        guard let stdinHandle else {
            throw AppServerClientError.requestFailed(message: "app-server stdin is unavailable")
        }

        var buffer = data
        buffer.append(0x0A)
        try stdinHandle.write(contentsOf: buffer)
    }

    private func handleResponseLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard let id = (object["id"] as? NSNumber)?.intValue else {
            return
        }

        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }

        pending.timeoutTask.cancel()

        if let errorObject = object["error"] as? [String: Any] {
            let message = (errorObject["message"] as? String) ?? "JSON-RPC request failed"
            pending.continuation.resume(throwing: AppServerClientError.requestFailed(message: message))
            return
        }

        guard let result = object["result"],
              JSONSerialization.isValidJSONObject(result),
              let resultData = try? JSONSerialization.data(withJSONObject: result) else {
            pending.continuation.resume(throwing: AppServerClientError.invalidResponse)
            return
        }

        pending.continuation.resume(returning: resultData)
    }

    private func timeoutRequest(id: Int, method: String) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: AppServerClientError.requestTimedOut(method: method))
    }

    private func processDidTerminate(code: Int32) async {
        await handleFailure(
            AppServerClientError.processExited(
                code: code,
                stderr: stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    private func handleFailure(_ error: Error) async {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrLineBuffer.removeAll(keepingCapacity: false)
        stdinHandle = nil
        process = nil
        isInitialized = false

        let pending = pendingRequests
        pendingRequests.removeAll()

        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }

        scheduleBackoff()
    }

    private func appendStderr(_ line: String) async {
        if stderrBuffer.isEmpty == false {
            stderrBuffer.append("\n")
        }
        stderrBuffer.append(line)
        if stderrBuffer.count > 4_000 {
            stderrBuffer = String(stderrBuffer.suffix(4_000))
        }
    }

    private func scheduleBackoff() {
        nextStartAllowedAt = .now + currentBackoff
        currentBackoff = min(currentBackoff * 2, maxBackoff)
    }

    private func consumeStdout(_ data: Data) async {
        stdoutBuffer.append(data)

        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard lineData.isEmpty == false,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            await handleResponseLine(line)
        }
    }

    private func consumeStderr(_ data: Data) async {
        stderrLineBuffer.append(data)

        while let newlineIndex = stderrLineBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrLineBuffer.prefix(upTo: newlineIndex)
            stderrLineBuffer.removeSubrange(...newlineIndex)
            guard lineData.isEmpty == false,
                  let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            await appendStderr(line)
        }
    }
}

private struct EmptyParams: Encodable {}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
