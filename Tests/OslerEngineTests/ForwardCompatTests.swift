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

    func testCurrentSchemaVersionIsWrittenAndNotFlaggedAsNewer() throws {
        let graph = FlowGraph(name: "Now", nodes: [Node(config: .output)])
        XCTAssertEqual(graph.schemaVersion, FlowGraph.currentSchemaVersion)
        XCTAssertFalse(graph.isFromNewerSchema)
        let reloaded = try FlowGraph(jsonData: try graph.jsonData())
        XCTAssertFalse(reloaded.isFromNewerSchema)
    }
}
