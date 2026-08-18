import XCTest
@testable import OslerEngine

// MARK: - MCPClient against a scripted stdio server

final class MCPClientTests: XCTestCase {
    /// A /bin/sh MCP "server" that answers the client's first three requests
    /// in order (initialize → tools/list → tools/call), which matches the
    /// client's sequential id numbering.
    private func makeMockServer() throws -> String {
        let script = """
        #!/bin/sh
        read line; printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock","version":"0"}}}\\n'
        read line
        read line; printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echoes text","inputSchema":{"type":"object"}}]}}\\n'
        read line; printf '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hello-from-tool"}],"isError":false}}\\n'
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osler-mock-mcp-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testInitializeListAndCall() async throws {
        let path = try makeMockServer()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = try MCPClient(command: path)
        try await client.initialize()

        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "echo")
        XCTAssertEqual(tools.first?.description, "Echoes text")

        let result = try await client.callTool(name: "echo", argumentsJSON: #"{"text":"hi"}"#)
        XCTAssertEqual(result.content, "hello-from-tool")
        XCTAssertFalse(result.isError)

        await client.shutdown()
    }

    func testEmptyCommandThrows() {
        XCTAssertThrowsError(try MCPClient(command: "   "))
    }

    func testServerExitSurfacesAsClosed() async throws {
        let client = try MCPClient(command: "/usr/bin/true") // exits immediately
        do {
            try await client.initialize()
            XCTFail("expected an error")
        } catch {
            // serverClosed (or a broken pipe surfaced as an error) — anything
            // but a hang is correct here.
        }
        await client.shutdown()
    }
}

// MARK: - Engine tool loop with scripted turns

/// Provider that plays back scripted turns and records what it was asked.
private final class MockTurnProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [LLMTurnResult]
    private(set) var transcripts: [[LLMMessage]] = []
    private(set) var toolsSeen: [[LLMTool]] = []

    init(turns: [LLMTurnResult]) {
        self.turns = turns
    }

    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMProviderError.stream("streamText not expected")) }
    }

    func completeTurn(_ request: LLMRequest, tools: [LLMTool],
                      transcript: [LLMMessage]) async throws -> LLMTurnResult {
        lock.lock()
        defer { lock.unlock() }
        transcripts.append(transcript)
        toolsSeen.append(tools)
        guard !turns.isEmpty else { return LLMTurnResult(text: "", toolCalls: []) }
        return turns.removeFirst()
    }
}

/// Executor that answers every call with a canned string.
private struct MockExecutor: ToolExecutor {
    let toolList: [LLMTool]
    let answer: @Sendable (String) -> (content: String, isError: Bool)

    func tools(for serverIDs: [String]) async -> [LLMTool] { toolList }
    func call(name: String, argumentsJSON: String,
              allowedServerIDs: [String]) async -> (content: String, isError: Bool) {
        answer(name)
    }
}

final class ToolLoopTests: XCTestCase {
    private let echoTool = LLMTool(
        name: "echo", description: "Echoes",
        inputSchema: .object(["type": .string("object")])
    )

    private func makeGraph() -> (FlowGraph, agentID: UUID, outputID: UUID) {
        var graph = FlowGraph(name: "tools")
        let input = Node(position: Point(x: 0, y: 0), config: .input(text: "start"))
        let agent = Node(position: Point(x: 1, y: 0), config: .agent(AgentConfig(toolServerIDs: ["srv"])))
        let output = Node(position: Point(x: 2, y: 0), config: .output)
        graph.nodes = [input, agent, output]
        graph.edges = [
            Edge(from: input.id, fromPort: .output, to: agent.id),
            Edge(from: agent.id, fromPort: .output, to: output.id),
        ]
        return (graph, agent.id, output.id)
    }

    private func collectOutputs(_ engine: FlowEngine, _ graph: FlowGraph) async throws -> [UUID: String] {
        var outputs: [UUID: String] = [:]
        for try await event in engine.run(graph) {
            if case .nodeFinished(let id, let text) = event { outputs[id] = text }
        }
        return outputs
    }

    func testToolRoundTrip() async throws {
        let (graph, agentID, outputID) = makeGraph()
        let provider = MockTurnProvider(turns: [
            LLMTurnResult(text: "", toolCalls: [ToolCall(id: "c1", name: "echo", argumentsJSON: #"{"x":1}"#)]),
            LLMTurnResult(text: "done after tool", toolCalls: []),
        ])
        var registry = ProviderRegistry()
        registry.register(provider, for: .anthropic)
        let executor = MockExecutor(toolList: [echoTool]) { _ in ("tool says hi", false) }

        let outputs = try await collectOutputs(FlowEngine(providers: registry, toolbox: executor), graph)

        XCTAssertEqual(outputs[agentID], "done after tool")
        XCTAssertEqual(outputs[outputID], "done after tool")

        // Round 2's transcript must contain the assistant tool call AND the
        // tool result, in order.
        XCTAssertEqual(provider.transcripts.count, 2)
        let second = provider.transcripts[1]
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second[0], .user("start"))
        XCTAssertEqual(second[1], .assistant(text: "", toolCalls: [ToolCall(id: "c1", name: "echo", argumentsJSON: #"{"x":1}"#)]))
        XCTAssertEqual(second[2], .toolResult(callID: "c1", content: "tool says hi", isError: false))
        XCTAssertEqual(provider.toolsSeen.first?.map(\.name), ["echo"])
    }

    func testToolErrorIsFedBack() async throws {
        let (graph, agentID, _) = makeGraph()
        let provider = MockTurnProvider(turns: [
            LLMTurnResult(text: "", toolCalls: [ToolCall(id: "c1", name: "echo", argumentsJSON: "{}")]),
            LLMTurnResult(text: "recovered", toolCalls: []),
        ])
        var registry = ProviderRegistry()
        registry.register(provider, for: .anthropic)
        let executor = MockExecutor(toolList: [echoTool]) { _ in ("boom", true) }

        let outputs = try await collectOutputs(FlowEngine(providers: registry, toolbox: executor), graph)

        XCTAssertEqual(outputs[agentID], "recovered")
        XCTAssertEqual(provider.transcripts[1][2], .toolResult(callID: "c1", content: "boom", isError: true))
    }

    func testLoopLimitFailsNode() async throws {
        let (graph, agentID, _) = makeGraph()
        // Always asks for another tool — must hit the rounds cap, not hang.
        let endless = (0..<20).map { _ in
            LLMTurnResult(text: "", toolCalls: [ToolCall(id: "x", name: "echo", argumentsJSON: "{}")])
        }
        let provider = MockTurnProvider(turns: endless)
        var registry = ProviderRegistry()
        registry.register(provider, for: .anthropic)
        let executor = MockExecutor(toolList: [echoTool]) { _ in ("ok", false) }

        var failedMessage: String?
        for try await event in FlowEngine(providers: registry, toolbox: executor).run(graph) {
            if case .nodeFailed(let id, let message) = event, id == agentID {
                failedMessage = message
            }
        }
        XCTAssertNotNil(failedMessage)
        XCTAssertTrue(failedMessage?.contains("rounds") == true)
    }

    func testNoToolboxFallsBackToStreaming() async throws {
        // toolServerIDs set but engine has no toolbox → plain streaming path.
        let (graph, agentID, _) = makeGraph()
        var registry = ProviderRegistry()
        registry.register(StaticProvider(text: "plain"), for: .anthropic)

        let outputs = try await collectOutputs(FlowEngine(providers: registry), graph)
        XCTAssertEqual(outputs[agentID], "plain")
    }
}

/// Minimal streaming provider for the fallback test.
private struct StaticProvider: LLMProvider {
    let text: String
    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        let value = text
        return AsyncThrowingStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
}

// MARK: - AgentConfig forward-compat for toolServerIDs

final class ToolServerCodableTests: XCTestCase {
    func testToolServerIDsRoundTrip() throws {
        let config = AgentConfig(toolServerIDs: ["a", "b"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: data)
        XCTAssertEqual(decoded.toolServerIDs, ["a", "b"])
    }

    func testMissingKeyDefaultsToEmpty() throws {
        let json = #"{"provider":"anthropic","model":"m"}"#
        let decoded = try JSONDecoder().decode(AgentConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.toolServerIDs, [])
    }

    func testAnthropicMessageEncodingAlternatesRoles() {
        // Two consecutive tool results must merge into ONE user message.
        let transcript: [LLMMessage] = [
            .user("hi"),
            .assistant(text: "", toolCalls: [
                ToolCall(id: "1", name: "a", argumentsJSON: "{}"),
                ToolCall(id: "2", name: "b", argumentsJSON: "{}"),
            ]),
            .toolResult(callID: "1", content: "r1", isError: false),
            .toolResult(callID: "2", content: "r2", isError: false),
        ]
        let messages = AnthropicProvider.encodeMessages(transcript)
        XCTAssertEqual(messages.count, 3) // user, assistant, merged tool-result user
        if case .object(let last) = messages[2],
           case .string(let role)? = last["role"],
           case .array(let blocks)? = last["content"] {
            XCTAssertEqual(role, "user")
            XCTAssertEqual(blocks.count, 2)
        } else {
            XCTFail("unexpected message shape")
        }
    }
}

// MARK: - Oversized tool results

final class ToolResultClampTests: XCTestCase {
    func testShortResultIsUntouched() {
        XCTAssertEqual(FlowEngine.clamp("small", to: 100), "small")
    }

    func testLineOrientedOutputIsCutOnARecordBoundary() {
        // 40 lines of "record N" — the cut must land between records, never
        // mid-line, so the model never sees half a record.
        let text = (1...40).map { "record \($0)" }.joined(separator: "\n")
        let clamped = FlowEngine.clamp(text, to: 200)
        let body = clamped.components(separatedBy: "\n\n[Truncated by Osler")[0]
        XCTAssertTrue(body.hasSuffix(body.split(separator: "\n").last.map(String.init) ?? ""))
        for line in body.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("record "), "partial record: \(line)")
        }
        XCTAssertTrue(clamped.contains("Truncated by Osler"))
    }

    func testSingleLongLineStillGetsMostOfItsBudget() {
        // No newline to cut on: keep the head rather than collapsing to nothing.
        let text = String(repeating: "x", count: 5_000)
        let clamped = FlowEngine.clamp(text, to: 1_000)
        let body = clamped.components(separatedBy: "\n\n[Truncated by Osler")[0]
        XCTAssertEqual(body.count, 1_000)
    }

    func testTruncationIsAnnouncedWithTheDroppedCount() {
        let text = String(repeating: "y", count: 300)
        let clamped = FlowEngine.clamp(text, to: 100)
        XCTAssertTrue(clamped.contains("200 more characters"), clamped)
    }
}

// MARK: - Transport hardening (the P0s from the audit)

final class MCPTransportTests: XCTestCase {
    /// Writes a script and returns its path.
    private func server(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osler-t-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private let handshake = """
    read line; printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}\\n'
    read line
    """

    /// A server that answers the handshake and then goes silent must not wedge
    /// the caller forever — the deadline has to tear the transport down.
    func testSilentServerTimesOutInsteadOfHanging() async throws {
        let path = try server(handshake + "\nsleep 60")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = try MCPClient(command: path,
                                   timeouts: .init(handshake: 5, call: 0.6))
        try await client.initialize()

        let started = Date()
        do {
            _ = try await client.callTool(name: "whatever", argumentsJSON: "{}")
            XCTFail("expected the deadline to fire")
        } catch {
            let waited = Date().timeIntervalSince(started)
            XCTAssertLessThan(waited, 5, "the call hung for \(waited)s — the timeout is inert")
        }
        await client.shutdown()
    }

    /// Writing to a server that has already exited used to raise SIGPIPE and
    /// kill the whole process. If that regresses, this test crashes the runner
    /// rather than failing — which is exactly the signal we want.
    func testWritingToADeadServerThrowsInsteadOfKillingTheProcess() async throws {
        let path = try server(handshake + "\nexit 0")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = try MCPClient(command: path,
                                   timeouts: .init(handshake: 5, call: 2))
        try await client.initialize()
        try? await Task.sleep(nanoseconds: 300_000_000) // let it exit

        do {
            _ = try await client.callTool(name: "gone", argumentsJSON: "{}")
            XCTFail("expected an error from the dead transport")
        } catch {
            // Any thrown error is fine; the point is that we're still alive.
        }
        await client.shutdown()
    }

    /// Two overlapping calls must not interleave their reads. Before the fix
    /// each caller could receive a payload spliced from both replies.
    func testConcurrentCallsAreSerializedAndDoNotSplice() async throws {
        // Echoes the request id back inside the tool result, so a spliced or
        // misrouted reply is detectable.
        let path = try server(handshake + """

        while read line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"reply-%s"}],"isError":false}}\\n' "$id" "$id"
        done
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let client = try MCPClient(command: path,
                                   timeouts: .init(handshake: 5, call: 10))
        try await client.initialize()

        async let a = client.callTool(name: "a", argumentsJSON: "{}")
        async let b = client.callTool(name: "b", argumentsJSON: "{}")
        let results = try await [a.content, b.content]

        // Each reply is whole, well-formed, and distinct.
        for text in results {
            XCTAssertTrue(text.hasPrefix("reply-"), "spliced or empty payload: \(text)")
        }
        XCTAssertEqual(Set(results).count, 2, "both calls got the same reply: \(results)")
        await client.shutdown()
    }
}
