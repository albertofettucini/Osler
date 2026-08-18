import Foundation

public enum GraphValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyGraph
    case duplicateNodeID(UUID)
    case duplicateEdgeID(UUID)
    case duplicateEdge(edgeID: UUID)
    case danglingEdge(edgeID: UUID)
    case selfLoop(nodeID: UUID)
    case invalidPort(edgeID: UUID, reason: String)
    case inputNodeHasIncomingEdge(nodeID: UUID)
    case outputNodeHasOutgoingEdge(nodeID: UUID)
    case emptyConditionKeyword(nodeID: UUID)
    case emptyLLMCondition(nodeID: UUID, reason: String)
    case unsupportedNode(nodeName: String, rawType: String)
    case cycle(nodeNames: [String])
    case unknownReference(nodeName: String, reference: String)
    case referenceNotUpstream(nodeName: String, reference: String)
    case ambiguousReference(nodeName: String, reference: String, count: Int)

    public var description: String {
        switch self {
        case .emptyGraph:
            return "The flow has no nodes."
        case .duplicateNodeID(let id):
            return "Two nodes share the same id (\(id.uuidString))."
        case .duplicateEdgeID(let id):
            return "Two edges share the same id (\(id.uuidString))."
        case .duplicateEdge(let edgeID):
            return "The same connection exists twice (edge \(edgeID.uuidString))."
        case .danglingEdge(let edgeID):
            return "Edge \(edgeID.uuidString) points at a node that doesn't exist."
        case .selfLoop(let nodeID):
            return "Node \(nodeID.uuidString) is connected to itself."
        case .invalidPort(_, let reason):
            return reason
        case .inputNodeHasIncomingEdge(let nodeID):
            return "Input node \(nodeID.uuidString) can't receive connections."
        case .outputNodeHasOutgoingEdge(let nodeID):
            return "Output node \(nodeID.uuidString) can't have outgoing connections."
        case .emptyConditionKeyword(let nodeID):
            return "Condition node \(nodeID.uuidString) has an empty keyword."
        case .emptyLLMCondition(_, let reason):
            return reason
        case .unsupportedNode(let nodeName, let rawType):
            return "This flow uses a node type this version doesn't support: \"\(nodeName)\" (\(rawType)). Update the app to run it. It will be preserved when you save."
        case .cycle(let nodeNames):
            return "The flow contains a cycle involving \(nodeNames.joined(separator: ", ")) (and any nodes downstream of them). Flows must run in one direction."
        case .unknownReference(let nodeName, let reference):
            return "\"\(nodeName)\" refers to {{\(reference)}}, but no node has that name."
        case .referenceNotUpstream(let nodeName, let reference):
            return "\"\(nodeName)\" refers to {{\(reference)}}, which isn't upstream of it — that value wouldn't be ready in time."
        case .ambiguousReference(let nodeName, let reference, let count):
            return "\"\(nodeName)\" refers to {{\(reference)}}, but \(count) nodes share that name — rename one so the reference can only mean one thing."
        }
    }
}

public enum GraphValidator {
    /// Validates structure and detects cycles. The engine calls this before
    /// executing; it throws the first issue found. For editing UIs that want to
    /// surface every problem at once, use `issues(in:)`.
    public static func validate(_ graph: FlowGraph) throws {
        if let first = issues(in: graph).first {
            throw first
        }
    }

    /// Every issue in one pass, deterministically ordered — designed for
    /// validation-while-editing so a canvas can highlight all problems at once.
    /// Empty array means the graph is runnable.
    public static func issues(in graph: FlowGraph) -> [GraphValidationError] {
        guard !graph.nodes.isEmpty else { return [.emptyGraph] }

        var issues: [GraphValidationError] = []

        var nodesByID: [UUID: Node] = [:]
        for node in graph.nodes {
            if nodesByID.updateValue(node, forKey: node.id) != nil {
                issues.append(.duplicateNodeID(node.id))
            }
        }

        // Nodes we couldn't decode from a newer file — surfaced by name.
        for node in graph.nodes {
            if case .unknown(let rawType, _) = node.config {
                issues.append(.unsupportedNode(nodeName: node.name, rawType: rawType))
            }
        }

        var edgeIDs = Set<UUID>()
        var connections = Set<ConnectionKey>()
        var structurallySound = issues.isEmpty
        for edge in graph.edges {
            if !edgeIDs.insert(edge.id).inserted {
                issues.append(.duplicateEdgeID(edge.id))
                structurallySound = false
                continue
            }
            guard let source = nodesByID[edge.from], let target = nodesByID[edge.to] else {
                issues.append(.danglingEdge(edgeID: edge.id))
                structurallySound = false
                continue
            }
            if edge.from == edge.to {
                issues.append(.selfLoop(nodeID: edge.from))
                structurallySound = false
                continue
            }
            if !connections.insert(ConnectionKey(edge)).inserted {
                issues.append(.duplicateEdge(edgeID: edge.id))
            }
            if source.kind == .condition {
                if edge.fromPort != .yes && edge.fromPort != .no {
                    issues.append(.invalidPort(
                        edgeID: edge.id,
                        reason: "Connections leaving a Condition node must use its yes or no port."
                    ))
                }
            } else if edge.fromPort != .output {
                issues.append(.invalidPort(
                    edgeID: edge.id,
                    reason: "Only Condition nodes have yes/no ports."
                ))
            }
            if target.kind == .input {
                issues.append(.inputNodeHasIncomingEdge(nodeID: target.id))
            }
            if source.kind == .output {
                issues.append(.outputNodeHasOutgoingEdge(nodeID: source.id))
            }
        }

        for node in graph.nodes {
            guard case .condition(let rule) = node.config else { continue }
            switch rule {
            case .containsKeyword(let keyword):
                if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyConditionKeyword(nodeID: node.id))
                }
            case .llmYesNo(let question, _, let model):
                if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyLLMCondition(
                        nodeID: node.id,
                        reason: "Condition node \"\(node.name)\" has an empty question."
                    ))
                }
                if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyLLMCondition(
                        nodeID: node.id,
                        reason: "Condition node \"\(node.name)\" has no model selected."
                    ))
                }
            }
        }

        // {{Name}} references must name a real node that is UPSTREAM of the
        // referring one. Anything else would read a value that either doesn't
        // exist or races the reader — better refused than silently empty.
        if structurallySound {
            let ancestors = ancestorNames(in: graph)
            for node in graph.nodes {
                guard let text = FlowReference.referencingText(of: node) else { continue }
                for reference in FlowReference.names(in: text) {
                    let key = FlowReference.key(reference)
                    let matches = graph.nodes.filter { FlowReference.key($0.name) == key }
                    if matches.count > 1 {
                        issues.append(.ambiguousReference(nodeName: node.name,
                                                          reference: reference,
                                                          count: matches.count))
                        continue
                    }
                    guard !matches.isEmpty else {
                        issues.append(.unknownReference(nodeName: node.name, reference: reference))
                        continue
                    }
                    if ancestors[node.id]?.contains(key) != true {
                        issues.append(.referenceNotUpstream(nodeName: node.name, reference: reference))
                    }
                }
            }
        }

        // Cycle detection only when the edge set is well-formed enough to trust
        // (dangling/duplicate/self-loop edges would make the walk meaningless).
        if structurallySound {
            do {
                _ = try topologicalOrder(graph)
            } catch let error as GraphValidationError {
                issues.append(error)
            } catch {
                // topologicalOrder only throws GraphValidationError.
            }
        }

        return issues
    }

    /// For each node, the lowercased names of every node transitively upstream
    /// of it. Walks incoming edges breadth-first; a cyclic graph simply stops
    /// at already-visited nodes (the cycle itself is reported separately).
    public static func ancestorNames(in graph: FlowGraph) -> [UUID: Set<String>] {
        let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Dictionary(grouping: graph.edges, by: \.to)
        var result: [UUID: Set<String>] = [:]

        for node in graph.nodes {
            var names: Set<String> = []
            var visited: Set<UUID> = [node.id]
            var frontier = (incoming[node.id] ?? []).map(\.from)
            while let id = frontier.popLast() {
                guard visited.insert(id).inserted, let ancestor = nodesByID[id] else { continue }
                names.insert(FlowReference.key(ancestor.name))
                frontier.append(contentsOf: (incoming[id] ?? []).map(\.from))
            }
            result[node.id] = names
        }
        return result
    }

    /// Kahn's algorithm. Throws `.cycle` naming the nodes stuck in the loop.
    public static func topologicalOrder(_ graph: FlowGraph) throws -> [Node] {
        let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var indegree: [UUID: Int] = [:]
        for node in graph.nodes {
            indegree[node.id] = 0
        }
        var adjacency: [UUID: [UUID]] = [:]
        for edge in graph.edges {
            adjacency[edge.from, default: []].append(edge.to)
            indegree[edge.to, default: 0] += 1
        }

        var queue = graph.nodes.filter { indegree[$0.id] == 0 }.map(\.id)
        var order: [Node] = []
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            if let node = nodesByID[id] {
                order.append(node)
            }
            for next in adjacency[id] ?? [] {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    queue.append(next)
                }
            }
        }

        guard order.count == graph.nodes.count else {
            let stuck = graph.nodes
                .filter { (indegree[$0.id] ?? 0) > 0 }
                .map(\.name)
                .sorted()
            throw GraphValidationError.cycle(nodeNames: stuck)
        }
        return order
    }

    private struct ConnectionKey: Hashable {
        let from: UUID
        let port: SourcePort
        let to: UUID

        init(_ edge: Edge) {
            self.from = edge.from
            self.port = edge.fromPort
            self.to = edge.to
        }
    }
}
