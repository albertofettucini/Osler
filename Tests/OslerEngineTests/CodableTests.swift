import XCTest
@testable import OslerEngine

final class CodableTests: XCTestCase {

    func testFullGraphRoundTrip() throws {
        var agentConfig = AgentConfig(provider: .openai, model: "gpt-4o", systemPrompt: "Be nice.", temperature: 0.7, maxTokens: 512)
        agentConfig.systemPrompt = "Be nice."
        let input = Node(name: "Start", position: Point(x: 10, y: 20), config: .input(text: "hello\nworld"))
        let agent = Node(name: "Writer", position: Point(x: 200, y: 20), config: .agent(agentConfig))
        let keywordCondition = Node(name: "Filter", config: .condition(.containsKeyword("ship")))
        let llmCondition = Node(name: "Judge", config: .condition(.llmYesNo(question: "Good?", provider: .anthropic, model: "claude-opus-4-8")))
        let output = Node(name: "End", config: .output)

        let graph = FlowGraph(name: "Round Trip", nodes: [input, agent, keywordCondition, llmCondition, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: keywordCondition.id),
            Edge(from: keywordCondition.id, fromPort: .yes, to: llmCondition.id),
            Edge(from: llmCondition.id, fromPort: .no, to: output.id),
        ])

        let data = try graph.jsonData()
        let decoded = try FlowGraph(jsonData: data)
        XCTAssertEqual(decoded, graph)
    }

    func testConditionRuleRoundTrips() throws {
        let rules: [ConditionRule] = [
            .containsKeyword("hello"),
            .llmYesNo(question: "Is it English?", provider: .openai, model: "gpt-4o"),
        ]
        for rule in rules {
            let data = try JSONEncoder().encode(rule)
            let decoded = try JSONDecoder().decode(ConditionRule.self, from: data)
            XCTAssertEqual(decoded, rule)
        }
    }

    /// Old/minimal JSON (missing optional fields) must decode with defaults —
    /// adding fields later must never delete users' saved flows.
    func testBackwardsCompatibleDecodingUsesDefaults() throws {
        let inputID = "11111111-1111-1111-1111-111111111111"
        let agentID = "22222222-2222-2222-2222-222222222222"
        let outputID = "33333333-3333-3333-3333-333333333333"
        let json = """
        {
          "nodes": [
            {"id": "\(inputID)", "type": "input", "input": {"text": "hi"}},
            {"id": "\(agentID)", "type": "agent"},
            {"id": "\(outputID)", "type": "output"}
          ],
          "edges": [
            {"id": "44444444-4444-4444-4444-444444444444", "from": "\(inputID)", "to": "\(agentID)"},
            {"id": "55555555-5555-5555-5555-555555555555", "from": "\(agentID)", "to": "\(outputID)"}
          ]
        }
        """
        let graph = try FlowGraph(jsonData: Data(json.utf8))

        XCTAssertEqual(graph.schemaVersion, 1)
        XCTAssertEqual(graph.name, "Untitled Flow")
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.edges.count, 2)

        let agent = graph.nodes[1]
        XCTAssertEqual(agent.name, "Agent")
        XCTAssertEqual(agent.position, Point(x: 0, y: 0))
        guard case .agent(let config) = agent.config else { return XCTFail("Expected agent config") }
        XCTAssertEqual(config.provider, .anthropic)
        XCTAssertEqual(config.model, AgentConfig.defaultAnthropicModel)
        XCTAssertNil(config.temperature)

        XCTAssertEqual(graph.edges[0].fromPort, .output)

        // The minimal graph is also runnable as-is.
        XCTAssertNoThrow(try GraphValidator.validate(graph))
    }

    func testEncodedJSONHasExpectedFields() throws {
        // Assert on structure via JSONSerialization, not exact pretty-print
        // whitespace, so Foundation formatting tweaks don't break the test.
        let input = Node(name: "Input", config: .input(text: "hi"))
        let graph = FlowGraph(name: "Shape", nodes: [input], edges: [])
        let object = try JSONSerialization.jsonObject(with: graph.jsonData()) as? [String: Any]

        XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object?["name"] as? String, "Shape")
        let node = (object?["nodes"] as? [[String: Any]])?.first
        XCTAssertEqual(node?["type"] as? String, "input")
        XCTAssertEqual((node?["input"] as? [String: Any])?["text"] as? String, "hi")
    }
}
