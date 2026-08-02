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
    func call(name: String, argumentsJSON: String) async -> (content: String, isError: Bool) {
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
