import XCTest
@testable import OslerEngine

final class FlowReferenceParsingTests: XCTestCase {
    func testFindsNamesInOrder() {
        let names = FlowReference.names(in: "Original: {{Text}}\nRewrite of {{ Draft }} please")
        XCTAssertEqual(names, ["Text", "Draft"])
    }

    func testIgnoresEmptyAndUnclosedReferences() {
        XCTAssertEqual(FlowReference.names(in: "{{}} and {{ }} and {{unclosed"), [])
    }

    func testResolvesCaseInsensitivelyAndKeepsSurroundingText() {
        let resolved = FlowReference.resolve(
            "A: {{draft}} | B: {{ CRITIQUE }}!",
            with: ["draft": "one", "critique": "two"]
        )
        XCTAssertEqual(resolved, "A: one | B: two!")
    }

    func testUnknownNameResolvesToEmpty() {
        // A skipped upstream node genuinely produced nothing.
        XCTAssertEqual(FlowReference.resolve("[{{ghost}}]", with: [:]), "[]")
    }

    func testTextWithoutReferencesIsUntouched() {
        let text = "No braces here { or } even single ones."
        XCTAssertEqual(FlowReference.resolve(text, with: ["a": "b"]), text)
    }
}

final class FlowReferenceValidationTests: XCTestCase {
    /// input → agent, where the agent's prompt references something.
    private func makeGraph(prompt: String, extraNodeNamed name: String? = nil) -> FlowGraph {
        let input = Node(name: "Text", position: Point(x: 0, y: 0), config: .input(text: "hi"))
        var config = AgentConfig()
        config.systemPrompt = prompt
        let agent = Node(name: "Writer", position: Point(x: 1, y: 0), config: .agent(config))
        var nodes = [input, agent]
        if let name {
            nodes.append(Node(name: name, position: Point(x: 0, y: 9), config: .input(text: "aside")))
        }
        return FlowGraph(name: "refs", nodes: nodes,
                         edges: [Edge(from: input.id, to: agent.id)])
    }

    func testUpstreamReferenceIsValid() {
        let issues = GraphValidator.issues(in: makeGraph(prompt: "Use {{Text}}."))
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testUnknownReferenceIsRejected() {
        let issues = GraphValidator.issues(in: makeGraph(prompt: "Use {{Nope}}."))
        XCTAssertEqual(issues, [.unknownReference(nodeName: "Writer", reference: "Nope")])
    }

    func testNonUpstreamReferenceIsRejected() {
        // "Aside" exists but nothing connects it to Writer — its value would
        // race the reader.
        let issues = GraphValidator.issues(in: makeGraph(prompt: "Use {{Aside}}.", extraNodeNamed: "Aside"))
        XCTAssertEqual(issues, [.referenceNotUpstream(nodeName: "Writer", reference: "Aside")])
    }
}

final class FlowReferenceExecutionTests: XCTestCase {
    /// Echoes the resolved system prompt so the test can read it back.
    private struct EchoPromptProvider: LLMProvider {
        func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
            let text = request.systemPrompt ?? ""
            return AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    func testReferenceIsSubstitutedAtRunTime() async throws {
        let input = Node(name: "Text", position: Point(x: 0, y: 0), config: .input(text: "THE SOURCE"))
        var config = AgentConfig()
        config.systemPrompt = "Echo this: {{Text}}"
        let agent = Node(name: "Writer", position: Point(x: 1, y: 0), config: .agent(config))
        let graph = FlowGraph(name: "refs", nodes: [input, agent],
                              edges: [Edge(from: input.id, to: agent.id)])

        var registry = ProviderRegistry()
        registry.register(EchoPromptProvider(), for: .anthropic)

        var outputs: [UUID: String] = [:]
        for try await event in FlowEngine(providers: registry).run(graph) {
            if case .nodeFinished(let id, let text) = event { outputs[id] = text }
        }
        XCTAssertEqual(outputs[agent.id], "Echo this: THE SOURCE")
    }
}
