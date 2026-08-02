import XCTest
@testable import OslerEngine

final class ValidatorTests: XCTestCase {

    private func expectError(
        _ graph: FlowGraph,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (GraphValidationError) -> Bool
    ) {
        do {
            try GraphValidator.validate(graph)
            XCTFail("Expected a validation error", file: file, line: line)
        } catch let error as GraphValidationError {
            XCTAssertTrue(matches(error), "Unexpected validation error: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    func testEmptyGraphIsInvalid() {
        expectError(FlowGraph()) { $0 == .emptyGraph }
    }

    func testValidLinearGraphPasses() throws {
        let input = Node(config: .input(text: "x"))
        let agent = Node(config: .agent(AgentConfig()))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])
        XCTAssertNoThrow(try GraphValidator.validate(graph))
        let order = try GraphValidator.topologicalOrder(graph)
        XCTAssertEqual(order.map(\.id), [input.id, agent.id, output.id])
    }

    func testDanglingEdge() {
        let node = Node(config: .input(text: "x"))
        let edge = Edge(from: node.id, to: UUID())
        let graph = FlowGraph(nodes: [node], edges: [edge])
        expectError(graph) {
            if case .danglingEdge(let edgeID) = $0 { return edgeID == edge.id }
            return false
        }
    }

    func testSelfLoop() {
        let agent = Node(config: .agent(AgentConfig()))
        let graph = FlowGraph(nodes: [agent], edges: [Edge(from: agent.id, to: agent.id)])
        expectError(graph) {
            if case .selfLoop(let nodeID) = $0 { return nodeID == agent.id }
            return false
        }
    }

    func testDuplicateNodeID() {
        let id = UUID()
        let first = Node(id: id, config: .input(text: "a"))
        let second = Node(id: id, config: .output)
        expectError(FlowGraph(nodes: [first, second])) {
            if case .duplicateNodeID(let nodeID) = $0 { return nodeID == id }
            return false
        }
    }

    func testDuplicateConnection() {
        let input = Node(config: .input(text: "a"))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, output], edges: [
            Edge(from: input.id, to: output.id),
            Edge(from: input.id, to: output.id),
        ])
        expectError(graph) {
            if case .duplicateEdge = $0 { return true }
            return false
        }
    }

    func testConditionMustUseYesNoPorts() {
        let input = Node(config: .input(text: "a"))
        let condition = Node(config: .condition(.containsKeyword("k")))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, condition, output], edges: [
            Edge(from: input.id, to: condition.id),
            Edge(from: condition.id, fromPort: .output, to: output.id),
        ])
        expectError(graph) {
            if case .invalidPort = $0 { return true }
            return false
        }
    }

    func testNonConditionCannotUseYesPort() {
        let input = Node(config: .input(text: "a"))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, output], edges: [
            Edge(from: input.id, fromPort: .yes, to: output.id),
        ])
        expectError(graph) {
            if case .invalidPort = $0 { return true }
            return false
        }
    }

    func testInputNodeCannotReceiveConnections() {
        let agent = Node(config: .agent(AgentConfig()))
        let input = Node(config: .input(text: "a"))
        let graph = FlowGraph(nodes: [agent, input], edges: [
            Edge(from: agent.id, to: input.id),
        ])
        expectError(graph) {
            if case .inputNodeHasIncomingEdge(let nodeID) = $0 { return nodeID == input.id }
            return false
        }
    }

    func testOutputNodeCannotHaveOutgoingConnections() {
        let output = Node(config: .output)
        let agent = Node(config: .agent(AgentConfig()))
        let graph = FlowGraph(nodes: [output, agent], edges: [
            Edge(from: output.id, to: agent.id),
        ])
        expectError(graph) {
            if case .outputNodeHasOutgoingEdge(let nodeID) = $0 { return nodeID == output.id }
            return false
        }
    }

    func testEmptyConditionKeyword() {
        let input = Node(config: .input(text: "a"))
        let condition = Node(config: .condition(.containsKeyword("   ")))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, condition, output], edges: [
            Edge(from: input.id, to: condition.id),
            Edge(from: condition.id, fromPort: .yes, to: output.id),
        ])
        expectError(graph) {
            if case .emptyConditionKeyword = $0 { return true }
            return false
        }
    }

    func testEmptyLLMConditionQuestionAndModelAreRejected() {
        let input = Node(config: .input(text: "a"))
        let emptyQuestion = Node(config: .condition(.llmYesNo(question: "  ", provider: .anthropic, model: "m")))
        let out1 = Node(config: .output)
        let graph1 = FlowGraph(nodes: [input, emptyQuestion, out1], edges: [
            Edge(from: input.id, to: emptyQuestion.id),
            Edge(from: emptyQuestion.id, fromPort: .yes, to: out1.id),
        ])
        expectError(graph1) {
            if case .emptyLLMCondition(_, let reason) = $0 { return reason.contains("question") }
            return false
        }

        let input2 = Node(config: .input(text: "a"))
        let emptyModel = Node(config: .condition(.llmYesNo(question: "ok?", provider: .anthropic, model: "")))
        let out2 = Node(config: .output)
        let graph2 = FlowGraph(nodes: [input2, emptyModel, out2], edges: [
            Edge(from: input2.id, to: emptyModel.id),
            Edge(from: emptyModel.id, fromPort: .yes, to: out2.id),
        ])
        expectError(graph2) {
            if case .emptyLLMCondition(_, let reason) = $0 { return reason.contains("model") }
            return false
        }
    }

    func testIssuesReturnsAllProblemsAtOnce() {
        // A graph with several independent problems — a validation-while-editing
        // canvas wants every issue, not just the first.
        let input = Node(config: .input(text: "a"))
        let emptyKeyword = Node(name: "K", config: .condition(.containsKeyword("")))
        let emptyLLM = Node(name: "L", config: .condition(.llmYesNo(question: "", provider: .anthropic, model: "")))
        let out = Node(config: .output)
        let graph = FlowGraph(nodes: [input, emptyKeyword, emptyLLM, out], edges: [
            Edge(from: input.id, to: emptyKeyword.id),
            Edge(from: emptyKeyword.id, fromPort: .yes, to: emptyLLM.id),
            Edge(from: emptyLLM.id, fromPort: .yes, to: out.id),
        ])
        let issues = GraphValidator.issues(in: graph)
        // empty keyword + empty question + empty model = at least 3 distinct issues.
        XCTAssertGreaterThanOrEqual(issues.count, 3)
        XCTAssertTrue(issues.contains { if case .emptyConditionKeyword = $0 { return true }; return false })
        XCTAssertEqual(issues.filter { if case .emptyLLMCondition = $0 { return true }; return false }.count, 2)
    }

    func testIssuesIsEmptyForAValidGraph() {
        let input = Node(config: .input(text: "x"))
        let agent = Node(config: .agent(AgentConfig()))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])
        XCTAssertTrue(GraphValidator.issues(in: graph).isEmpty)
    }

    func testCycleNamesTheNodesInvolved() {
        let entry = Node(name: "Entry", config: .input(text: "x"))
        let left = Node(name: "Left", config: .agent(AgentConfig()))
        let right = Node(name: "Right", config: .agent(AgentConfig()))
        let graph = FlowGraph(nodes: [entry, left, right], edges: [
            Edge(from: entry.id, to: left.id),
            Edge(from: left.id, to: right.id),
            Edge(from: right.id, to: left.id),
        ])
        expectError(graph) {
            if case .cycle(let names) = $0 { return names.sorted() == ["Left", "Right"] }
            return false
        }
    }

    func testDiamondTopologicalOrderRespectsDependencies() throws {
        let input = Node(name: "In", config: .input(text: "x"))
        let left = Node(name: "L", config: .agent(AgentConfig()))
        let right = Node(name: "R", config: .agent(AgentConfig()))
        let join = Node(name: "Join", config: .output)
        let graph = FlowGraph(nodes: [input, left, right, join], edges: [
            Edge(from: input.id, to: left.id),
            Edge(from: input.id, to: right.id),
            Edge(from: left.id, to: join.id),
            Edge(from: right.id, to: join.id),
        ])
        let order = try GraphValidator.topologicalOrder(graph).map(\.id)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        XCTAssertLessThan(position[input.id]!, position[left.id]!)
        XCTAssertLessThan(position[input.id]!, position[right.id]!)
        XCTAssertLessThan(position[left.id]!, position[join.id]!)
        XCTAssertLessThan(position[right.id]!, position[join.id]!)
    }
}
