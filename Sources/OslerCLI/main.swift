import Foundation
import OslerEngine

// osler-cli — Phase 1 test harness for the Osler flow engine.
// Builds sample graphs in code and runs them against a real API key from the
// environment, streaming every node's output live.

// MARK: - Options

struct CLIOptions {
    var demo = "linear"
    var model: String?
    var printJSON = false
}

func printUsage() {
    print("""
    osler-cli — headless test harness for the Osler flow engine

    USAGE: osler-cli [--demo linear|condition|cycle|tools] [--model <model-id>] [--json]

    DEMOS:
      linear     Input → Agent → Output (default)
      condition  Input → LLM yes/no Condition → one of two Agent branches → Output
      cycle      A deliberately cyclic graph — proves cycle detection (no API key needed)
      tools      Agent calls a real MCP stdio server (spawned mock) via the tool loop

    OPTIONS:
      --model    Override the model id (default: per provider)
      --json     Print the demo graph as JSON before running (Codable round-trip)

    ENVIRONMENT:
      ANTHROPIC_API_KEY   Anthropic key (preferred when set)
      OPENAI_API_KEY      OpenAI key
      (no key needed for Ollama — a local server on :11434 is the fallback)
    """)
}

func parseOptions() -> CLIOptions {
    var options = CLIOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--demo" where !arguments.isEmpty:
            options.demo = arguments.removeFirst()
        case "--model" where !arguments.isEmpty:
            options.model = arguments.removeFirst()
        case "--json":
            options.printJSON = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown or incomplete option: \(argument)\n\n".utf8))
            printUsage()
            exit(2)
        }
    }
    return options
}

// MARK: - Provider setup

func makeRegistry() -> (ProviderRegistry, ProviderID) {
    let environment = ProcessInfo.processInfo.environment
    var registry = ProviderRegistry()
    var preferred: ProviderID?
    if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty {
        registry.register(AnthropicProvider(apiKey: key), for: .anthropic)
        preferred = preferred ?? .anthropic
    }
    if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
        registry.register(OpenAIProvider(apiKey: key), for: .openai)
        preferred = preferred ?? .openai
    }
    // Ollama is local and keyless — always registered, the keyless fallback.
    registry.register(OllamaProvider(), for: .ollama)
    return (registry, preferred ?? .ollama)
}

// MARK: - Sample graphs

func linearDemo(provider: ProviderID, model: String) -> FlowGraph {
    let input = Node(
        name: "Input",
        position: Point(x: 0, y: 0),
        config: .input(text: """
        Osler is a native macOS app for visually designing AI agent workflows \
        on a node canvas. Bring your own API key, wire nodes together, hit Run.
        """)
    )
    var copywriter = AgentConfig(provider: provider, model: model)
    copywriter.systemPrompt = """
    You are a sharp product copywriter. Rewrite the input as one punchy tagline \
    of at most 12 words. Reply with the tagline only.
    """
    let agent = Node(name: "Copywriter", position: Point(x: 260, y: 0), config: .agent(copywriter))
    let output = Node(name: "Output", position: Point(x: 520, y: 0), config: .output)
    return FlowGraph(name: "Linear Demo", nodes: [input, agent, output], edges: [
        Edge(from: input.id, to: agent.id),
        Edge(from: agent.id, to: output.id),
    ])
}

func conditionDemo(provider: ProviderID, model: String) -> FlowGraph {
    let input = Node(
        name: "Input",
        position: Point(x: 0, y: 0),
        config: .input(text: "The quick brown fox jumps over the lazy dog.")
    )
    let router = Node(
        name: "Language Router",
        position: Point(x: 260, y: 0),
        config: .condition(.llmYesNo(
            question: "Is the text written in English?",
            provider: provider,
            model: model
        ))
    )
    var toTurkish = AgentConfig(provider: provider, model: model)
    toTurkish.systemPrompt = "Translate the user's text to Turkish. Reply with the translation only."
    var toEnglish = AgentConfig(provider: provider, model: model)
    toEnglish.systemPrompt = "Translate the user's text to English. Reply with the translation only."
    let yesAgent = Node(name: "Translate to Turkish", position: Point(x: 520, y: -90), config: .agent(toTurkish))
    let noAgent = Node(name: "Translate to English", position: Point(x: 520, y: 90), config: .agent(toEnglish))
    let output = Node(name: "Output", position: Point(x: 780, y: 0), config: .output)
    return FlowGraph(name: "Condition Demo", nodes: [input, router, yesAgent, noAgent, output], edges: [
        Edge(from: input.id, to: router.id),
        Edge(from: router.id, fromPort: .yes, to: yesAgent.id),
        Edge(from: router.id, fromPort: .no, to: noAgent.id),
        Edge(from: yesAgent.id, to: output.id),
        Edge(from: noAgent.id, to: output.id),
    ])
}

func toolsDemo(provider: ProviderID, model: String, serverID: String) -> FlowGraph {
    let input = Node(
        name: "Input",
        position: Point(x: 0, y: 0),
        config: .input(text: "Fetch today's secret phrase and report it.")
    )
    var config = AgentConfig(provider: provider, model: model)
    config.systemPrompt = """
    You have a tool named get_secret that returns a secret phrase. Call the \
    tool, then reply with exactly: The secret is <phrase>
    """
    config.toolServerIDs = [serverID]
    let agent = Node(name: "Tool Agent", position: Point(x: 260, y: 0), config: .agent(config))
    let output = Node(name: "Output", position: Point(x: 520, y: 0), config: .output)
    return FlowGraph(name: "MCP Tools Demo", nodes: [input, agent, output], edges: [
        Edge(from: input.id, to: agent.id),
        Edge(from: agent.id, to: output.id),
    ])
}

/// Writes a tiny /bin/sh MCP server: answers initialize and tools/list, then
/// serves every tools/call with the same secret (matching request ids via sed).
func writeMockToolServer() throws -> String {
    let script = """
    #!/bin/sh
    read line; printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"demo","version":"0"}}}\\n'
    read line
    read line; printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_secret","description":"Returns the secret phrase","inputSchema":{"type":"object","properties":{}}}]}}\\n'
    while read line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"mavi-kirpi-42"}],"isError":false}}\\n' "$id"
    done
    """
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("osler-demo-mcp-\(UUID().uuidString).sh").path
    try (script + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

func cycleDemo() -> FlowGraph {
    let agentA = Node(name: "Agent A", config: .agent(AgentConfig()))
    let agentB = Node(name: "Agent B", config: .agent(AgentConfig()))
    return FlowGraph(name: "Cycle Demo", nodes: [agentA, agentB], edges: [
        Edge(from: agentA.id, to: agentB.id),
        Edge(from: agentB.id, to: agentA.id),
    ])
}

// MARK: - Run loop

func run(_ graph: FlowGraph, using engine: FlowEngine) async -> Int32 {
    var names: [UUID: String] = [:]
    var kinds: [UUID: NodeKind] = [:]
    for node in graph.nodes {
        names[node.id] = node.name
        kinds[node.id] = node.kind
    }
    func name(_ id: UUID) -> String { names[id] ?? id.uuidString }

    var exitCode: Int32 = 0
    do {
        for try await event in engine.run(graph) {
            switch event {
            case .flowStarted:
                print("Running \"\(graph.name)\"…")
            case .nodeStarted(let id):
                print("\n▶ \(name(id))")
            case .nodeDelta(_, let text):
                FileHandle.standardOutput.write(Data(text.utf8))
            case .conditionRouted(let id, let tookYes):
                print("\n↳ \(name(id)) → \(tookYes ? "YES" : "NO") branch")
            case .nodeFinished(let id, let output):
                if kinds[id] == .input || kinds[id] == .output {
                    print("  \(output.replacingOccurrences(of: "\n", with: "\n  "))")
                }
                print("✓ \(name(id)) finished")
            case .nodeSkipped(let id):
                print("\n⏭ \(name(id)) skipped")
            case .nodeFailed(let id, let message):
                print("\n✗ \(name(id)) failed: \(message)")
            case .flowFinished(let summary):
                print("\n── Summary ──")
                for node in graph.nodes {
                    if let output = summary.outputs[node.id] {
                        let flattened = output.replacingOccurrences(of: "\n", with: " ")
                        let preview = flattened.count > 80 ? String(flattened.prefix(77)) + "…" : flattened
                        print("  ✓ \(node.name): \(preview)")
                    } else if let failure = summary.failures[node.id] {
                        print("  ✗ \(node.name): \(failure)")
                    } else if summary.skipped.contains(node.id) {
                        print("  ⏭ \(node.name): skipped")
                    }
                }
                if !summary.failures.isEmpty {
                    exitCode = 1
                }
            }
        }
    } catch {
        print("\nFlow did not run: \(error)")
        return 1
    }
    return exitCode
}

func printJSONIfRequested(_ graph: FlowGraph, options: CLIOptions) {
    guard options.printJSON else { return }
    do {
        let data = try graph.jsonData()
        print(String(decoding: data, as: UTF8.self))
        // Prove "flows saved as local JSON" end-to-end: write to a real file,
        // read it back, and confirm the reloaded graph is identical.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osler-demo-\(graph.nodes.count)nodes.oslerflow")
        try graph.write(to: url)
        let reloaded = try FlowGraph(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard reloaded == graph else {
            print("✗ File round-trip mismatch — saved and reloaded graphs differ.")
            exit(1)
        }
        print("(Saved to \(url.lastPathComponent), reloaded, and verified identical)\n")
    } catch {
        print("JSON save/load failed: \(error)")
        exit(1)
    }
}

// MARK: - Main

let options = parseOptions()

if options.demo == "cycle" {
    let graph = cycleDemo()
    printJSONIfRequested(graph, options: options)
    do {
        for try await _ in FlowEngine().run(graph) {}
        print("✗ Expected a cycle error, but the flow ran.")
        exit(1)
    } catch {
        print("✓ Cycle detected before execution, as expected:\n  \(error)")
        exit(0)
    }
}

let (registry, providerID) = makeRegistry()

let model = options.model ?? AgentConfig.defaultModel(for: providerID)
print("Provider: \(providerID.displayName) · Model: \(model)\n")

if options.demo == "tools" {
    let scriptPath = try writeMockToolServer()

    let server = MCPServerConfig(id: "demo-tools", name: "Demo Tools", command: scriptPath)
    let toolbox = MCPToolbox()
    await toolbox.start(servers: [server])
    let failures = await toolbox.failures
    guard failures.isEmpty else {
        for failure in failures { print("✗ \(failure.serverName): \(failure.message)") }
        exit(1)
    }
    print("MCP server up — tools: get_secret\n")

    let graph = toolsDemo(provider: providerID, model: model, serverID: "demo-tools")
    printJSONIfRequested(graph, options: options)
    let engine = FlowEngine(providers: registry, toolbox: toolbox)
    let code = await run(graph, using: engine)
    await toolbox.shutdown()
    try? FileManager.default.removeItem(atPath: scriptPath)
    exit(code)
}

let graph: FlowGraph
switch options.demo {
case "linear":
    graph = linearDemo(provider: providerID, model: model)
case "condition":
    graph = conditionDemo(provider: providerID, model: model)
default:
    FileHandle.standardError.write(Data("Unknown demo: \(options.demo)\n\n".utf8))
    printUsage()
    exit(2)
}

printJSONIfRequested(graph, options: options)
let engine = FlowEngine(providers: registry)
exit(await run(graph, using: engine))
