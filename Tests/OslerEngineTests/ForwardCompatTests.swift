import XCTest
@testable import OslerEngine

/// A newer app version will add node types, providers, and condition rules.
/// These tests pin the contract that an older build opening such a file must
/// preserve it losslessly rather than lose the user's whole flow.
final class ForwardCompatTests: XCTestCase {

    private let inputID = "11111111-1111-1111-1111-111111111111"
    private let futureID = "22222222-2222-2222-2222-222222222222"
    private let outputID = "33333333-3333-3333-3333-333333333333"

    private func fileWithFutureNode() -> String {
        """
        {
          "schemaVersion": 2,
          "name": "From The Future",
          "nodes": [
            {"id": "\(inputID)", "type": "input", "position": {"x": 0, "y": 0}, "input": {"text": "hi"}},
            {"id": "\(futureID)", "type": "toolCall", "position": {"x": 5, "y": 9},
             "name": "Call Weather API", "tool": {"endpoint": "https://x", "retries": 3, "flags": [true, null, "a"]}},
            {"id": "\(outputID)", "type": "output", "position": {"x": 10, "y": 0}}
          ],
          "edges": [
            {"id": "44444444-4444-4444-4444-444444444444", "from": "\(inputID)", "to": "\(futureID)"},
            {"id": "55555555-5555-5555-5555-555555555555", "from": "\(futureID)", "to": "\(outputID)"}
          ]
        }
        """
    }

    func testUnknownNodeTypeDoesNotBrickTheFile() throws {
        let graph = try FlowGraph(jsonData: Data(fileWithFutureNode().utf8))
        // The whole flow decodes — all three nodes present, edges intact.
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(graph.name, "From The Future")

        let future = graph.nodes.first { $0.id.uuidString.lowercased() == futureID }
        XCTAssertEqual(future?.kind, .unknown)
        XCTAssertEqual(future?.name, "Call Weather API")
        XCTAssertEqual(future?.position, Point(x: 5, y: 9))
        if case .unknown(let rawType, _)? = future?.config {
            XCTAssertEqual(rawType, "toolCall")
        } else {
            XCTFail("Expected an .unknown node config")
        }

        XCTAssertTrue(graph.hasUnsupportedNodes)
        XCTAssertTrue(graph.isFromNewerSchema)
    }

    func testUnknownNodeRoundTripsLosslessly() throws {
        let original = try FlowGraph(jsonData: Data(fileWithFutureNode().utf8))
        let reencoded = try original.jsonData()
        let reloaded = try FlowGraph(jsonData: reencoded)

        // Saving from the older app and reopening preserves everything,
        // including the future node's foreign payload.
        XCTAssertEqual(reloaded, original)

        // And the foreign payload survives byte-for-byte in shape.
        let json = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        let nodes = json?["nodes"] as? [[String: Any]]
        let futureNode = nodes?.first { ($0["id"] as? String)?.lowercased() == futureID }
        XCTAssertEqual(futureNode?["type"] as? String, "toolCall")
        let tool = futureNode?["tool"] as? [String: Any]
        XCTAssertEqual(tool?["endpoint"] as? String, "https://x")
        XCTAssertEqual(tool?["retries"] as? Int, 3)
    }

    func testUnknownNodeFailsValidationWithAClearMessage() throws {
        let graph = try FlowGraph(jsonData: Data(fileWithFutureNode().utf8))
        let issues = GraphValidator.issues(in: graph)
        guard let unsupported = issues.first(where: {
            if case .unsupportedNode = $0 { return true }; return false
        }) else {
            return XCTFail("Expected an .unsupportedNode issue")
        }
        // Names the node and its raw type, and says data is preserved.
        XCTAssertTrue(unsupported.description.contains("Call Weather API"))
        XCTAssertTrue(unsupported.description.contains("toolCall"))
        XCTAssertTrue(unsupported.description.lowercased().contains("preserved"))

        XCTAssertThrowsError(try GraphValidator.validate(graph))
    }

    func testUnknownProviderPreservesTheAgentNode() throws {
        // An agent node referencing a provider this build doesn't know must not
        // brick the file — it's preserved as an unknown node.
        let json = """
        {
          "nodes": [
            {"id": "\(inputID)", "type": "input", "input": {"text": "hi"}},
            {"id": "\(futureID)", "type": "agent",
             "agent": {"provider": "gemini", "model": "gemini-3", "systemPrompt": "x", "maxTokens": 1024}}
          ],
          "edges": []
        }
        """
        let graph = try FlowGraph(jsonData: Data(json.utf8))
        XCTAssertEqual(graph.nodes.count, 2)
        let agentNode = graph.nodes.first { $0.id.uuidString.lowercased() == futureID }
        XCTAssertEqual(agentNode?.kind, .unknown)
        // Round-trips the unknown provider.
        let reloaded = try FlowGraph(jsonData: try graph.jsonData())
        XCTAssertEqual(reloaded, graph)
    }

    // MARK: Fields this build doesn't know

    private let agentID = "66666666-6666-6666-6666-666666666666"
    private let conditionID = "77777777-7777-7777-7777-777777777777"

    /// A flow as a newer build might write it: every object this build knows
    /// carries one field it doesn't. Every known key is spelled out the way
    /// this build writes it, so the whole tree can be compared after a save.
    private func fileWithFutureFields() -> String {
        """
        {
          "schemaVersion": 1,
          "name": "Newer Fields",
          "futureRoot": {"tags": ["a", "b"], "pinned": true},
          "nodes": [
            {"id": "\(inputID)", "type": "input", "name": "Topic", "position": {"x": 0, "y": 0},
             "input": {"text": "hi", "futureInput": "multiline"},
             "futureNode": 1},
            {"id": "\(agentID)", "type": "agent", "name": "Draft", "position": {"x": 300, "y": 0},
             "agent": {"provider": "anthropic", "model": "claude-opus-4-8", "systemPrompt": "Write.",
                       "maxTokens": 2048, "toolServerIDs": [], "futureAgent": {"effort": "low"}},
             "futureNode": null},
            {"id": "\(conditionID)", "type": "condition", "name": "Check", "position": {"x": 600, "y": 0},
             "condition": {"kind": "containsKeyword", "keyword": "ship", "futureCondition": 2.5}},
            {"id": "\(outputID)", "type": "output", "name": "Result", "position": {"x": 900, "y": 0},
             "futureNode": "kept"}
          ],
          "edges": [
            {"id": "44444444-4444-4444-4444-444444444444", "from": "\(inputID)", "fromPort": "output",
             "to": "\(agentID)", "futureEdge": "dashed"},
            {"id": "55555555-5555-5555-5555-555555555555", "from": "\(agentID)", "fromPort": "output",
             "to": "\(conditionID)"},
            {"id": "88888888-8888-8888-8888-888888888888", "from": "\(conditionID)", "fromPort": "yes",
             "to": "\(outputID)"}
          ]
        }
        """
    }

    private func tree(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func node(_ id: String, in graph: FlowGraph) -> Node? {
        graph.nodes.first { $0.id.uuidString.lowercased() == id }
    }

    func testUnknownFieldsAtEveryLevelRoundTrip() throws {
        let original = Data(fileWithFutureFields().utf8)
        let graph = try FlowGraph(jsonData: original)

        XCTAssertEqual(graph.extras["futureRoot"],
                       .object(["tags": .array([.string("a"), .string("b")]), "pinned": .bool(true)]))
        XCTAssertEqual(node(inputID, in: graph)?.extras["futureNode"], .number(1))
        XCTAssertEqual(node(inputID, in: graph)?.inputExtras["futureInput"], .string("multiline"))
        XCTAssertEqual(node(agentID, in: graph)?.extras["futureNode"], .null)
        if case .agent(let config)? = node(agentID, in: graph)?.config {
            XCTAssertEqual(config.extras["futureAgent"], .object(["effort": .string("low")]))
        } else {
            XCTFail("Expected an agent config")
        }
        XCTAssertEqual(node(conditionID, in: graph)?.conditionExtras["futureCondition"], .number(2.5))
        XCTAssertEqual(node(outputID, in: graph)?.extras["futureNode"], .string("kept"))
        XCTAssertEqual(graph.edges.first?.extras["futureEdge"], .string("dashed"))

        // Semantic equality, not bytes: numbers come back as Doubles and the
        // encoder sorts keys, but the JSON trees must be the same.
        XCTAssertEqual(try tree(graph.jsonData()), try tree(original))
    }

    func testUnknownFieldsSurviveAnEditAndASecondSave() throws {
        var graph = try FlowGraph(jsonData: Data(fileWithFutureFields().utf8))
        // What the canvas does: move a node, rename one, change an agent field.
        let inputIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.id.uuidString.lowercased() == inputID })
        graph.nodes[inputIndex].position = Point(x: 40, y: 80)
        graph.nodes[inputIndex].config = .input(text: "edited")
        let agentIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.id.uuidString.lowercased() == agentID })
        graph.nodes[agentIndex].name = "Draft v2"
        if case .agent(var config) = graph.nodes[agentIndex].config {
            config.maxTokens = 512
            graph.nodes[agentIndex].config = .agent(config)
        }

        let reloaded = try FlowGraph(jsonData: FlowGraph(jsonData: graph.jsonData()).jsonData())
        XCTAssertEqual(reloaded, graph)
        XCTAssertEqual(node(inputID, in: reloaded)?.inputExtras["futureInput"], .string("multiline"))
        XCTAssertEqual(node(inputID, in: reloaded)?.position, Point(x: 40, y: 80))
        if case .agent(let config)? = node(agentID, in: reloaded)?.config {
            XCTAssertEqual(config.maxTokens, 512)
            XCTAssertEqual(config.extras["futureAgent"], .object(["effort": .string("low")]))
        } else {
            XCTFail("Expected an agent config")
        }
        XCTAssertEqual(node(conditionID, in: reloaded)?.conditionExtras["futureCondition"], .number(2.5))
        XCTAssertEqual(reloaded.extras["futureRoot"],
                       .object(["tags": .array([.string("a"), .string("b")]), "pinned": .bool(true)]))
        XCTAssertEqual(reloaded.edges.first?.extras["futureEdge"], .string("dashed"))
    }

    func testKnownKeysAlwaysWinOverExtras() throws {
        // Extras can only shadow a key if code put it there; the value this
        // build owns must still be the one written.
        var config = AgentConfig(provider: .openai, model: "gpt-4o")
        config.extras = ["model": .string("not-this"), "futureAgent": .bool(true)]
        var agent = Node(name: "Draft", config: .agent(config))
        agent.extras = ["name": .string("not-this"), "futureNode": .bool(true)]
        var check = Node(name: "Check", config: .condition(.containsKeyword("ship")))
        check.conditionExtras = ["keyword": .string("not-this")]
        var graph = FlowGraph(name: "Mine", nodes: [agent, check])
        graph.extras = ["name": .string("not-this")]

        guard case .object(let root) = try tree(graph.jsonData()),
              case .array(let nodes)? = root["nodes"],
              case .object(let agentObject) = nodes[0],
              case .object(let agentConfig)? = agentObject["agent"],
              case .object(let checkObject) = nodes[1],
              case .object(let condition)? = checkObject["condition"] else {
            return XCTFail("Unexpected JSON shape")
        }
        XCTAssertEqual(root["name"], .string("Mine"))
        XCTAssertEqual(agentObject["name"], .string("Draft"))
        XCTAssertEqual(agentObject["futureNode"], .bool(true))
        XCTAssertEqual(agentConfig["model"], .string("gpt-4o"))
        XCTAssertEqual(agentConfig["futureAgent"], .bool(true))
        XCTAssertEqual(condition["keyword"], .string("ship"))
    }

    func testAKeyAnotherKindWouldOwnIsKeptAsAnExtra() throws {
        // An agent node has no "input" object today; if a newer build writes
        // one, it's preserved instead of being dropped as a "known" key.
        let json = """
        {"nodes": [{"id": "\(agentID)", "type": "agent", "input": {"text": "seed"}}], "edges": []}
        """
        let graph = try FlowGraph(jsonData: Data(json.utf8))
        XCTAssertEqual(graph.nodes.first?.kind, .agent)
        XCTAssertEqual(graph.nodes.first?.extras["input"], .object(["text": .string("seed")]))
        let reloaded = try FlowGraph(jsonData: graph.jsonData())
        XCTAssertEqual(reloaded, graph)
    }

    func testOldFilesDecodeWithNoExtrasAndSaveUnchanged() throws {
        // A 1.1 file, written by this build's encoder before extras existed.
        let json = """
        {
          "schemaVersion": 1,
          "name": "Old",
          "nodes": [
            {"id": "\(inputID)", "type": "input", "name": "Input", "position": {"x": 0, "y": 0},
             "input": {"text": "hi"}},
            {"id": "\(agentID)", "type": "agent", "name": "Agent", "position": {"x": 300, "y": 0},
             "agent": {"provider": "openai", "model": "gpt-4o", "systemPrompt": "", "temperature": 0.7,
                       "maxTokens": 2048, "toolServerIDs": ["s1"]}},
            {"id": "\(conditionID)", "type": "condition", "name": "Judge", "position": {"x": 600, "y": 0},
             "condition": {"kind": "llmYesNo", "question": "Good?", "provider": "anthropic",
                           "model": "claude-opus-4-8"}},
            {"id": "\(outputID)", "type": "output", "name": "Output", "position": {"x": 900, "y": 0}}
          ],
          "edges": [
            {"id": "44444444-4444-4444-4444-444444444444", "from": "\(inputID)", "fromPort": "output",
             "to": "\(agentID)"}
          ]
        }
        """
        let graph = try FlowGraph(jsonData: Data(json.utf8))
        XCTAssertTrue(graph.extras.isEmpty)
        XCTAssertTrue(graph.edges.allSatisfy { $0.extras.isEmpty })
        for node in graph.nodes {
            XCTAssertTrue(node.extras.isEmpty && node.inputExtras.isEmpty && node.conditionExtras.isEmpty)
            if case .agent(let config) = node.config {
                XCTAssertTrue(config.extras.isEmpty)
                XCTAssertEqual(config.temperature, 0.7)
                XCTAssertEqual(config.toolServerIDs, ["s1"])
            }
        }
        XCTAssertEqual(try tree(graph.jsonData()), try tree(Data(json.utf8)))
    }

    func testCurrentSchemaVersionIsWrittenAndNotFlaggedAsNewer() throws {
        let graph = FlowGraph(name: "Now", nodes: [Node(config: .output)])
        XCTAssertEqual(graph.schemaVersion, FlowGraph.currentSchemaVersion)
        XCTAssertFalse(graph.isFromNewerSchema)
        let reloaded = try FlowGraph(jsonData: try graph.jsonData())
        XCTAssertFalse(reloaded.isFromNewerSchema)
    }
}
