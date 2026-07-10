import Core
import Foundation
import Testing

@Suite(.serialized)
struct AppServerClientTests {
    @Test
    func listsThreads() async throws {
        try await withStubServer(scenario: "success") { configuration in
            try await withClient(configuration: configuration) { client in
                let threads = try await client.listThreads(limit: 20, cwdFilters: [])
                #expect(threads.count == 1)
                #expect(threads.first?.id == "thread-1")
                #expect(threads.first?.cwd == "/tmp/project-a")
                #expect(threads.first?.updatedAt != nil)
            }
        }
    }

    @Test
    func paginatesAcrossThreadList() async throws {
        try await withStubServer(scenario: "paginate") { configuration in
            try await withClient(configuration: configuration) { client in
                let threads = try await client.listThreads(limit: 2, cwdFilters: [])
                #expect(threads.map(\.id) == ["thread-1", "thread-2"])
            }
        }
    }

    @Test
    func timesOutRequests() async throws {
        try await withStubServer(scenario: "timeout") { configuration in
            try await withClient(
                configuration: configuration,
                requestTimeout: .milliseconds(80),
                baseBackoff: .milliseconds(10),
                maxBackoff: .milliseconds(50)
            ) { client in
                await #expect(throws: AppServerClientError.requestTimedOut(method: "thread/list")) {
                    _ = try await client.listThreads(limit: 1, cwdFilters: [])
                }
            }
        }
    }

    @Test
    func reconnectsAfterProcessDisconnect() async throws {
        try await withStubServer(scenario: "disconnect_once") { configuration in
            try await withClient(configuration: configuration) { client in
                await #expect(throws: Error.self) {
                    _ = try await client.listThreads(limit: 1, cwdFilters: [])
                }

                try await Task.sleep(for: .milliseconds(40))
                let threads = try await client.listThreads(limit: 1, cwdFilters: [])
                #expect(threads.first?.id == "thread-1")
            }
        }
    }

    @Test
    func handlesEmptyThreadList() async throws {
        try await withStubServer(scenario: "empty") { configuration in
            try await withClient(configuration: configuration) { client in
                let threads = try await client.listThreads(limit: 20, cwdFilters: [])
                #expect(threads.isEmpty)
            }
        }
    }

    @Test
    func streamsTokenUsageUpdatesAfterResumeSubscription() async throws {
        try await withStubServer(scenario: "resume_stream") { configuration in
            try await withClient(configuration: configuration) { client in
                let sink = EventSink()
                await client.setEventHandler { event in
                    await sink.append(event)
                }

                await client.syncSubscriptions(threadIDs: ["thread-1"])
                try await Task.sleep(for: .milliseconds(80))

                let events = await sink.snapshot()
                #expect(events.count == 1)

                guard case let .tokenUsageUpdated(update) = events[0] else {
                    Issue.record("missing token usage update")
                    return
                }

                #expect(update.threadId == "thread-1")
                #expect(update.turnId == "turn-1")
                #expect(update.tokenUsage.last.reasoningOutputTokens == 177)
                #expect(update.tokenUsage.total.reasoningOutputTokens == 936)
            }
        }
    }

    private func withClient(
        configuration: AppServerLaunchConfiguration,
        requestTimeout: Duration = .milliseconds(300),
        baseBackoff: Duration = .milliseconds(10),
        maxBackoff: Duration = .milliseconds(50),
        _ body: (AppServerClient) async throws -> Void
    ) async throws {
        let client = AppServerClient(
            launchConfiguration: configuration,
            requestTimeout: requestTimeout,
            baseBackoff: baseBackoff,
            maxBackoff: maxBackoff
        )

        do {
            try await body(client)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func withStubServer(
        scenario: String,
        _ body: (AppServerLaunchConfiguration) async throws -> Void
    ) async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let stateFileURL = directoryURL.appendingPathComponent("state.txt")
        let scriptURL = directoryURL.appendingPathComponent("stub_server.py")
        try stubScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let configuration = AppServerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", scriptURL.path],
            environment: ProcessInfo.processInfo.environment.merging([
                "PYTHONUNBUFFERED": "1",
                "STUB_SCENARIO": scenario,
                "STUB_STATE_FILE": stateFileURL.path,
            ]) { _, new in new }
        )

        try await body(configuration)
    }

    private var stubScript: String {
        #"""
        import json
        import os
        import pathlib
        import sys
        import time

        scenario = os.environ["STUB_SCENARIO"]
        state_file = pathlib.Path(os.environ["STUB_STATE_FILE"])
        run_count = 0
        if state_file.exists():
            run_count = int(state_file.read_text() or "0")
        run_count += 1
        state_file.write_text(str(run_count))

        def send(message_id, result=None, error=None):
            payload = {"id": message_id}
            if error is not None:
                payload["error"] = {"code": -32000, "message": error}
            else:
                payload["result"] = result
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()

        def notify(method, params):
            sys.stdout.write(json.dumps({"method": method, "params": params}) + "\n")
            sys.stdout.flush()

        for raw_line in sys.stdin:
            if not raw_line.strip():
                continue
            message = json.loads(raw_line)
            if "id" not in message:
                continue

            method = message["method"]
            if method == "initialize":
                send(message["id"], {"serverInfo": {"name": "stub"}})
                notify("remoteControl/status/changed", {"status": "disabled"})
                if scenario == "disconnect_after_initialize" and run_count == 1:
                    sys.exit(0)
                continue

            if method == "thread/resume":
                send(message["id"], {})
                if scenario == "resume_stream":
                    notify("thread/tokenUsage/updated", {
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "tokenUsage": {
                            "total": {
                                "totalTokens": 1200,
                                "inputTokens": 900,
                                "cachedInputTokens": 400,
                                "outputTokens": 300,
                                "reasoningOutputTokens": 936
                            },
                            "last": {
                                "totalTokens": 240,
                                "inputTokens": 180,
                                "cachedInputTokens": 120,
                                "outputTokens": 60,
                                "reasoningOutputTokens": 177
                            },
                            "modelContextWindow": 258400
                        }
                    })
                continue

            if method == "thread/unsubscribe":
                send(message["id"], {"status": "unsubscribed"})
                continue

            if method != "thread/list":
                send(message["id"], {"data": [], "nextCursor": None})
                continue

            params = message.get("params") or {}
            if scenario == "timeout":
                time.sleep(60)
                continue

            if scenario == "disconnect_once" and run_count == 1:
                sys.exit(0)

            if scenario == "paginate":
                if params.get("cursor") == "page-2":
                    send(message["id"], {
                        "data": [{
                            "id": "thread-2",
                            "name": "Two",
                            "preview": "second",
                            "source": "cli",
                            "cwd": "/tmp/project-b",
                            "path": "/tmp/b.jsonl",
                            "updatedAt": 1783555202
                        }],
                        "nextCursor": None
                    })
                else:
                    send(message["id"], {
                        "data": [{
                            "id": "thread-1",
                            "name": "One",
                            "preview": "first",
                            "source": "cli",
                            "cwd": "/tmp/project-a",
                            "path": "/tmp/a.jsonl",
                            "updatedAt": 1783555201
                        }],
                        "nextCursor": "page-2"
                    })
                continue

            if scenario == "empty":
                send(message["id"], {"data": [], "nextCursor": None})
                continue

            send(message["id"], {
                "data": [{
                    "id": "thread-1",
                    "name": "One",
                    "preview": "first",
                    "source": "cli",
                    "cwd": "/tmp/project-a",
                    "path": "/tmp/a.jsonl",
                    "updatedAt": 1783555201
                }],
                "nextCursor": None
            })
        """#
    }
}

actor EventSink {
    private var events: [AppServerEvent] = []

    func append(_ event: AppServerEvent) {
        events.append(event)
    }

    func snapshot() -> [AppServerEvent] {
        events
    }
}
