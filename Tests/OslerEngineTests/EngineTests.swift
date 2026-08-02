import XCTest
@testable import OslerEngine

final class EngineTests: XCTestCase {

    // MARK: Linear flow

    func testLinearFlowStreamsAndCompletes() async throws {
        let input = Node(name: "Input", config: .input(text: "hello"))
        let agent = Node(name: "Agent", config: .agent(AgentConfig()))
        let output = Node(name: "Output", config: .output)
        let graph = FlowGraph(name: "Linear", nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])

        let registry = makeRegistry { request in
            ["echo:", request.userText]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), graph)

        XCTAssertEqual(events.first, .flowStarted)
        guard let summary = finalSummary(of: events) else {
            return XCTFail("No flowFinished event")
        }
        XCTAssertEqual(summary.outputs[input.id], "hello")
        XCTAssertEqual(summary.outputs[agent.id], "echo:hello")
        XCTAssertEqual(summary.outputs[output.id], "echo:hello")
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertTrue(summary.skipped.isEmpty)

        // Streamed deltas reassemble into the final agent output.
        XCTAssertEqual(deltas(of: events, nodeID: agent.id), "echo:hello")

        // Dependency order: input finishes before the agent starts,
        // agent finishes before the output starts.
        let inputDone = events.firstIndex(of: .nodeFinished(id: input.id, output: "hello"))
        let agentStart = events.firstIndex(of: .nodeStarted(id: agent.id))
        let agentDone = events.firstIndex(of: .nodeFinished(id: agent.id, output: "echo:hello"))
        let outputStart = events.firstIndex(of: .nodeStarted(id: output.id))
        XCTAssertNotNil(inputDone)
        XCTAssertNotNil(agentStart)
        XCTAssertNotNil(agentDone)
        XCTAssertNotNil(outputStart)
        XCTAssertLessThan(inputDone!, agentStart!)
        XCTAssertLessThan(agentDone!, outputStart!)
    }

    func testAgentReceivesSystemPromptAndModel() async throws {
        var config = AgentConfig()
        config.systemPrompt = "Be terse."
        config.model = "claude-opus-4-8"
        config.maxTokens = 77
        let input = Node(config: .input(text: "hi"))
        let agent = Node(config: .agent(config))
        let graph = FlowGraph(nodes: [input, agent], edges: [Edge(from: input.id, to: agent.id)])

        let registry = makeRegistry { request in
            XCTAssertEqual(request.systemPrompt, "Be terse.")
            XCTAssertEqual(request.model, "claude-opus-4-8")
            XCTAssertEqual(request.maxTokens, 77)
            XCTAssertEqual(request.userText, "hi")
            return ["ok"]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), graph)
        XCTAssertEqual(finalSummary(of: events)?.outputs[agent.id], "ok")
    }

    // MARK: Cycle detection

    func testCycleFailsBeforeExecution() async {
        let agentA = Node(name: "A", config: .agent(AgentConfig()))
        let agentB = Node(name: "B", config: .agent(AgentConfig()))
        let graph = FlowGraph(nodes: [agentA, agentB], edges: [
            Edge(from: agentA.id, to: agentB.id),
            Edge(from: agentB.id, to: agentA.id),
        ])

        do {
            _ = try await collectEvents(FlowEngine(), graph)
            XCTFail("Expected a cycle error")
        } catch let error as FlowEngineError {
            guard case .validation(.cycle(let names)) = error else {
                return XCTFail("Expected .validation(.cycle), got \(error)")
            }
            XCTAssertEqual(names.sorted(), ["A", "B"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Condition routing

    private func makeConditionGraph(
        rule: ConditionRule,
        inputText: String
    ) -> (graph: FlowGraph, condition: Node, yesAgent: Node, noAgent: Node, yesOut: Node, noOut: Node) {
        let input = Node(config: .input(text: inputText))
        let condition = Node(name: "Router", config: .condition(rule))
        let yesAgent = Node(name: "YesAgent", config: .agent(AgentConfig()))
        let noAgent = Node(name: "NoAgent", config: .agent(AgentConfig()))
        let yesOut = Node(name: "YesOut", config: .output)
        let noOut = Node(name: "NoOut", config: .output)
        let graph = FlowGraph(nodes: [input, condition, yesAgent, noAgent, yesOut, noOut], edges: [
            Edge(from: input.id, to: condition.id),
            Edge(from: condition.id, fromPort: .yes, to: yesAgent.id),
            Edge(from: condition.id, fromPort: .no, to: noAgent.id),
            Edge(from: yesAgent.id, to: yesOut.id),
            Edge(from: noAgent.id, to: noOut.id),
        ])
        return (graph, condition, yesAgent, noAgent, yesOut, noOut)
    }

    func testKeywordConditionTakesYesBranch() async throws {
        let scenario = makeConditionGraph(
            rule: .containsKeyword("MACOS"),
            inputText: "I love building for macOS."
        )
        let registry = makeRegistry { request in ["handled: \(request.userText)"] }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        // Condition passes its input through the taken branch.
        XCTAssertEqual(summary.outputs[scenario.yesAgent.id], "handled: I love building for macOS.")
        XCTAssertEqual(summary.outputs[scenario.yesOut.id], "handled: I love building for macOS.")
        // The untaken branch is skipped, and the skip cascades.
        XCTAssertTrue(summary.skipped.contains(scenario.noAgent.id))
        XCTAssertTrue(summary.skipped.contains(scenario.noOut.id))
        XCTAssertTrue(summary.failures.isEmpty)
    }

    func testConditionRoutedEventAndSummaryDecisionAreSurfaced() async throws {
        let scenario = makeConditionGraph(
            rule: .containsKeyword("macos"),
            inputText: "Built for macOS."
        )
        let registry = makeRegistry { _ in ["ok"] }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)

        // A canvas can highlight the taken edge from this event.
        XCTAssertTrue(events.contains(.conditionRouted(id: scenario.condition.id, tookYes: true)))
        XCTAssertEqual(finalSummary(of: events)?.decisions[scenario.condition.id], true)

        // conditionRouted fires before the condition node finishes.
        let routed = events.firstIndex(of: .conditionRouted(id: scenario.condition.id, tookYes: true))
        let finished = events.firstIndex(of: .nodeFinished(id: scenario.condition.id, output: "Built for macOS."))
        XCTAssertNotNil(routed)
        XCTAssertNotNil(finished)
        XCTAssertLessThan(routed!, finished!)
    }

    func testLLMConditionEmitsNoDeltas() async throws {
        // The internal YES/NO routing tokens are machinery, not node output —
        // they must not leak as nodeDelta events.
        let scenario = makeConditionGraph(
            rule: .llmYesNo(question: "English?", provider: .anthropic, model: "m"),
            inputText: "text"
        )
        let registry = makeRegistry { request in
            request.userText.contains("English?") ? ["YES"] : ["agent"]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)
        XCTAssertEqual(deltas(of: events, nodeID: scenario.condition.id), "",
                       "Condition nodes must not emit their internal YES/NO as deltas")
        // The condition's output is the passthrough input, consistent with nodeFinished.
        XCTAssertEqual(finalSummary(of: events)?.outputs[scenario.condition.id], "text")
    }

    func testKeywordConditionTakesNoBranch() async throws {
        let scenario = makeConditionGraph(
            rule: .containsKeyword("windows"),
            inputText: "I love building for macOS."
        )
        let registry = makeRegistry { request in ["handled: \(request.userText)"] }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        XCTAssertNotNil(summary.outputs[scenario.noOut.id])
        XCTAssertTrue(summary.skipped.contains(scenario.yesAgent.id))
        XCTAssertTrue(summary.skipped.contains(scenario.yesOut.id))
    }

    func testLLMYesNoConditionParsesAnswer() async throws {
        let scenario = makeConditionGraph(
            rule: .llmYesNo(question: "Is this English?", provider: .anthropic, model: "m"),
            inputText: "Plainly English text."
        )
        let registry = makeRegistry { request in
            // The router call carries the question; agent calls just echo.
            if request.userText.contains("Is this English?") {
                return ["YES", "\n"]
            }
            return ["agent output"]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        XCTAssertEqual(summary.outputs[scenario.yesOut.id], "agent output")
        XCTAssertTrue(summary.skipped.contains(scenario.noAgent.id))
    }

    func testLLMYesNoConditionAmbiguousAnswerFailsNode() async throws {
        let scenario = makeConditionGraph(
            rule: .llmYesNo(question: "Is this English?", provider: .anthropic, model: "m"),
            inputText: "text"
        )
        let registry = makeRegistry { request in
            if request.userText.contains("Is this English?") {
                return ["It sure looks like it!"]
            }
            return ["agent output"]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), scenario.graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        // The condition node fails; both branches go dead.
        XCTAssertNotNil(summary.failures[scenario.condition.id])
        XCTAssertTrue(summary.skipped.contains(scenario.yesAgent.id))
        XCTAssertTrue(summary.skipped.contains(scenario.noAgent.id))
        XCTAssertTrue(summary.skipped.contains(scenario.yesOut.id))
        XCTAssertTrue(summary.skipped.contains(scenario.noOut.id))
    }

    // MARK: Joins

    func testDiamondJoinReceivesOnlyTakenBranch() async throws {
        let input = Node(config: .input(text: "contains-key"))
        let condition = Node(config: .condition(.containsKeyword("key")))
        let yesAgent = Node(name: "Yes", config: .agent(AgentConfig()))
        let noAgent = Node(name: "No", config: .agent(AgentConfig()))
        let join = Node(name: "Join", config: .output)
        let graph = FlowGraph(nodes: [input, condition, yesAgent, noAgent, join], edges: [
            Edge(from: input.id, to: condition.id),
            Edge(from: condition.id, fromPort: .yes, to: yesAgent.id),
            Edge(from: condition.id, fromPort: .no, to: noAgent.id),
            Edge(from: yesAgent.id, to: join.id),
            Edge(from: noAgent.id, to: join.id),
        ])

        let registry = makeRegistry { _ in ["branch result"] }
        let events = try await collectEvents(FlowEngine(providers: registry), graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        // The join still runs, fed only by the live branch — no dead-branch text.
        XCTAssertEqual(summary.outputs[join.id], "branch result")
        XCTAssertTrue(summary.skipped.contains(noAgent.id))
        XCTAssertFalse(summary.skipped.contains(join.id))
    }

    func testFanInJoinsInputsWithBlankLineInEdgeOrder() async throws {
        let first = Node(config: .input(text: "one"))
        let second = Node(config: .input(text: "two"))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [first, second, output], edges: [
            Edge(from: first.id, to: output.id),
            Edge(from: second.id, to: output.id),
        ])

        let events = try await collectEvents(FlowEngine(), graph)
        XCTAssertEqual(finalSummary(of: events)?.outputs[output.id], "one\n\ntwo")
    }

    // MARK: Failure propagation

    func testAgentFailureSkipsDownstreamButOtherBranchCompletes() async throws {
        let input = Node(config: .input(text: "go"))
        var boomConfig = AgentConfig()
        boomConfig.model = "boom"
        let failingAgent = Node(name: "Failing", config: .agent(boomConfig))
        let failingOut = Node(name: "FailingOut", config: .output)
        let healthyAgent = Node(name: "Healthy", config: .agent(AgentConfig()))
        let healthyOut = Node(name: "HealthyOut", config: .output)
        let graph = FlowGraph(nodes: [input, failingAgent, failingOut, healthyAgent, healthyOut], edges: [
            Edge(from: input.id, to: failingAgent.id),
            Edge(from: input.id, to: healthyAgent.id),
            Edge(from: failingAgent.id, to: failingOut.id),
            Edge(from: healthyAgent.id, to: healthyOut.id),
        ])

        let registry = makeRegistry { request in
            if request.model == "boom" {
                throw LLMProviderError.api(statusCode: 500, message: "kaput")
            }
            return ["fine"]
        }
        let events = try await collectEvents(FlowEngine(providers: registry), graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        XCTAssertEqual(summary.failures[failingAgent.id], LLMProviderError.api(statusCode: 500, message: "kaput").description)
        XCTAssertTrue(summary.skipped.contains(failingOut.id))
        XCTAssertEqual(summary.outputs[healthyOut.id], "fine")
    }

    func testMidStreamFailureEmitsPartialDeltasThenFails() async throws {
        let input = Node(config: .input(text: "go"))
        let agent = Node(config: .agent(AgentConfig()))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])

        var registry = ProviderRegistry()
        registry.register(MidStreamFailureProvider(partial: "par", message: "connection cut"), for: .anthropic)
        let events = try await collectEvents(FlowEngine(providers: registry), graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        XCTAssertEqual(deltas(of: events, nodeID: agent.id), "par")
        XCTAssertEqual(summary.failures[agent.id], LLMProviderError.stream("connection cut").description)
        XCTAssertTrue(summary.skipped.contains(output.id))
    }

    func testMissingProviderFailsNodeNotFlow() async throws {
        let input = Node(config: .input(text: "go"))
        var config = AgentConfig()
        config.provider = .openai // registry below only has anthropic
        let agent = Node(config: .agent(config))
        let graph = FlowGraph(nodes: [input, agent], edges: [Edge(from: input.id, to: agent.id)])

        let registry = makeRegistry { _ in ["never"] }
        let events = try await collectEvents(FlowEngine(providers: registry), graph)
        guard let summary = finalSummary(of: events) else { return XCTFail("No summary") }

        XCTAssertEqual(summary.failures[agent.id], LLMProviderError.notRegistered(.openai).description)
        XCTAssertEqual(summary.outputs[input.id], "go")
    }
}
