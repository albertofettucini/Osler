import Foundation

// MARK: - Geometry

/// A canvas position. Deliberately not CGPoint so the engine stays free of
/// CoreGraphics/AppKit and can be extracted as a cross-platform package later.
public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

// MARK: - Providers

public enum ProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case anthropic
    case openai
    /// Local models through an Ollama server — no API key, nothing leaves
    /// the machine.
    case ollama

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    /// True when the provider needs a BYOK API key (Ollama is local).
    public var requiresKey: Bool { self != .ollama }
}

// MARK: - Node configuration

public enum NodeKind: String, Codable, Hashable, Sendable {
    case input
    case agent
    case condition
    case output
    /// A node whose `type` this build doesn't recognize — decoded from a flow
    /// saved by a newer app version. Preserved verbatim so it survives an
    /// open/save round-trip; the engine refuses to run a flow containing one.
    case unknown
}

public struct AgentConfig: Hashable, Sendable {
    public static let defaultAnthropicModel = "claude-opus-4-8"
    public static let defaultOpenAIModel = "gpt-4o"
    public static let defaultOllamaModel = "llama3.2"

    public static func defaultModel(for provider: ProviderID) -> String {
        switch provider {
        case .anthropic: return defaultAnthropicModel
        case .openai: return defaultOpenAIModel
        case .ollama: return defaultOllamaModel
        }
    }

    public var provider: ProviderID
    public var model: String
    public var systemPrompt: String
    /// Sampling temperature. `nil` uses the provider default. Note: recent
    /// Anthropic models (Opus 4.7+, Sonnet 5) reject an explicit temperature —
    /// leave this nil unless the chosen model supports it.
    public var temperature: Double?
    public var maxTokens: Int
    /// MCP servers whose tools this agent may call (by MCPServerConfig.id).
    public var toolServerIDs: [String]
    /// Fields of the saved `agent` object this build doesn't know (written by
    /// a newer version), kept so saving here doesn't strip them.
    public var extras: [String: JSONValue]

    public init(
        provider: ProviderID = .anthropic,
        model: String = AgentConfig.defaultAnthropicModel,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxTokens: Int = 2048,
        toolServerIDs: [String] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolServerIDs = toolServerIDs
        self.extras = extras
    }
}

extension AgentConfig: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case provider, model, systemPrompt, temperature, maxTokens, toolServerIDs
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))

    // decodeIfPresent everywhere so adding fields later never breaks old
    // saved flows (missing key ⇒ default, not a decode error).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .anthropic,
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? AgentConfig.defaultAnthropicModel,
            systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            maxTokens: try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048,
            toolServerIDs: try container.decodeIfPresent([String].self, forKey: .toolServerIDs) ?? [],
            extras: try decoder.unknownFields(excluding: Self.knownKeys)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(toolServerIDs, forKey: .toolServerIDs)
        try encoder.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

public enum ConditionRule: Hashable, Sendable {
    /// Case-insensitive substring check on the incoming text.
    case containsKeyword(String)
    /// Asks an LLM the given question about the incoming text; the model must
    /// answer YES or NO.
    case llmYesNo(question: String, provider: ProviderID, model: String)
}

extension ConditionRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, keyword, question, provider, model
    }

    /// The keys this rule writes. Anything else in a saved condition object
    /// is preserved by the owning Node (`conditionExtras`), so this enum's
    /// cases stay as they are.
    var encodedKeys: Set<String> {
        let keys: [CodingKeys]
        switch self {
        case .containsKeyword: keys = [.kind, .keyword]
        case .llmYesNo: keys = [.kind, .question, .provider, .model]
        }
        return Set(keys.map(\.stringValue))
    }

    private enum Kind: String, Codable {
        case containsKeyword, llmYesNo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .containsKeyword:
            self = .containsKeyword(try container.decodeIfPresent(String.self, forKey: .keyword) ?? "")
        case .llmYesNo:
            self = .llmYesNo(
                question: try container.decodeIfPresent(String.self, forKey: .question) ?? "",
                provider: try container.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .anthropic,
                model: try container.decodeIfPresent(String.self, forKey: .model) ?? AgentConfig.defaultAnthropicModel
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .containsKeyword(let keyword):
            try container.encode(Kind.containsKeyword, forKey: .kind)
            try container.encode(keyword, forKey: .keyword)
        case .llmYesNo(let question, let provider, let model):
            try container.encode(Kind.llmYesNo, forKey: .kind)
            try container.encode(question, forKey: .question)
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
        }
    }
}

public enum NodeConfig: Hashable, Sendable {
    case input(text: String)
    case agent(AgentConfig)
    case condition(ConditionRule)
    case output
    /// An unrecognized node preserved from a newer file. `payload` is the node's
    /// original JSON object, re-emitted verbatim on encode.
    case unknown(rawType: String, payload: JSONValue)

    public var kind: NodeKind {
        switch self {
        case .input: return .input
        case .agent: return .agent
        case .condition: return .condition
        case .output: return .output
        case .unknown: return .unknown
        }
    }
}

// MARK: - Node

public struct Node: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var position: Point
    public var config: NodeConfig
    /// Fields of the saved node object this build doesn't know (written by a
    /// newer version). Kept so an open/save round-trip here doesn't strip
    /// them. The nested `input` and `condition` objects keep theirs in
    /// `inputExtras` / `conditionExtras`; the agent object in
    /// `AgentConfig.extras`.
    public var extras: [String: JSONValue] = [:]
    public var inputExtras: [String: JSONValue] = [:]
    public var conditionExtras: [String: JSONValue] = [:]

    public var kind: NodeKind { config.kind }

    public init(id: UUID = UUID(), name: String? = nil, position: Point = Point(), config: NodeConfig) {
        self.id = id
        self.name = name ?? Node.defaultName(for: config.kind)
        self.position = position
        self.config = config
    }

    public static func defaultName(for kind: NodeKind) -> String {
        switch kind {
        case .input: return "Input"
        case .agent: return "Agent"
        case .condition: return "Condition"
        case .output: return "Output"
        case .unknown: return "Unsupported"
        }
    }

    /// Rebuilds a node from a raw JSON object, falling back to a preserved
    /// `.unknown` node if this build can't decode it (newer node type, newer
    /// enum value, or a payload shape it doesn't understand). This is what keeps
    /// an older app from destroying a whole flow file over one unrecognized node.
    init(preservingUnknownFrom jsonValue: JSONValue) {
        if let data = try? JSONEncoder().encode(jsonValue),
           let node = try? JSONDecoder().decode(Node.self, from: data) {
            self = node
            return
        }
        let rawType = jsonValue.string("type") ?? "unknown"
        let id = jsonValue.string("id").flatMap(UUID.init(uuidString:)) ?? UUID()
        let name = jsonValue.string("name") ?? "Unsupported (\(rawType))"
        var position = Point()
        if case .object(let dict) = jsonValue, case .object(let pos)? = dict["position"] {
            if case .number(let x)? = pos["x"] { position.x = x }
            if case .number(let y)? = pos["y"] { position.y = y }
        }
        self.init(id: id, name: name, position: position, config: .unknown(rawType: rawType, payload: jsonValue))
    }
}

extension Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, position, type, input, agent, condition
    }

    private struct InputPayload: Codable {
        var text: String
    }

    /// The keys a node of this kind writes; anything else is an extra.
    private static func encodedKeys(for kind: NodeKind) -> Set<String> {
        var keys: [CodingKeys] = [.id, .name, .position, .type]
        switch kind {
        case .input: keys.append(.input)
        case .agent: keys.append(.agent)
        case .condition: keys.append(.condition)
        case .output, .unknown: break
        }
        return Set(keys.map(\.stringValue))
    }

    private static let inputKeys: Set<String> = ["text"]

    /// A condition object: the rule's own keys plus what this build doesn't
    /// know, written into one JSON object.
    private struct ConditionPayload: Encodable {
        let rule: ConditionRule
        let extras: [String: JSONValue]

        func encode(to encoder: Encoder) throws {
            try rule.encode(to: encoder)
            try encoder.encodeUnknownFields(extras, excluding: rule.encodedKeys)
        }
    }

    // Strict: throws on an unrecognized type or an undecodable payload. The
    // forward-compatible path lives in Node.init(preservingUnknownFrom:), which
    // catches those throws and preserves the node instead of failing the file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeString = try container.decode(String.self, forKey: .type)
        guard let kind = NodeKind(rawValue: typeString), kind != .unknown else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unsupported node type \"\(typeString)\"."
            )
        }
        let config: NodeConfig
        var inputExtras: [String: JSONValue] = [:]
        var conditionExtras: [String: JSONValue] = [:]
        switch kind {
        case .input:
            let payload = try container.decodeIfPresent(InputPayload.self, forKey: .input)
            config = .input(text: payload?.text ?? "")
            if let raw = try container.decodeIfPresent([String: JSONValue].self, forKey: .input) {
                inputExtras = raw.filter { !Self.inputKeys.contains($0.key) }
            }
        case .agent:
            config = .agent(try container.decodeIfPresent(AgentConfig.self, forKey: .agent) ?? AgentConfig())
        case .condition:
            let rule = try container.decode(ConditionRule.self, forKey: .condition)
            config = .condition(rule)
            let raw = try container.decode([String: JSONValue].self, forKey: .condition)
            conditionExtras = raw.filter { !rule.encodedKeys.contains($0.key) }
        case .output:
            config = .output
        case .unknown:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unsupported node type \"\(typeString)\"."
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            position: try container.decodeIfPresent(Point.self, forKey: .position) ?? Point(),
            config: config
        )
        self.extras = try decoder.unknownFields(excluding: Self.encodedKeys(for: kind))
        self.inputExtras = inputExtras
        self.conditionExtras = conditionExtras
    }

    public func encode(to encoder: Encoder) throws {
        // Unknown nodes round-trip their original object verbatim.
        if case .unknown(_, let payload) = config {
            var single = encoder.singleValueContainer()
            try single.encode(payload)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(position, forKey: .position)
        try container.encode(kind, forKey: .type)
        switch config {
        case .input(let text):
            var input = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .input)
            try input.encode(text, forKey: AnyCodingKey("text"))
            for (key, value) in inputExtras where !Self.inputKeys.contains(key) {
                try input.encode(value, forKey: AnyCodingKey(key))
            }
        case .agent(let agentConfig):
            try container.encode(agentConfig, forKey: .agent)
        case .condition(let rule):
            try container.encode(ConditionPayload(rule: rule, extras: conditionExtras), forKey: .condition)
        case .output:
            break
        case .unknown:
            break // handled by the early return above
        }
        try encoder.encodeUnknownFields(extras, excluding: Self.encodedKeys(for: kind))
    }
}

// MARK: - Edge

/// Which outlet of the source node an edge leaves from. Regular nodes have a
/// single `output` port; Condition nodes route through `yes` / `no`.
public enum SourcePort: String, Codable, Hashable, Sendable {
    case output
    case yes
    case no
}

public struct Edge: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var from: UUID
    public var fromPort: SourcePort
    public var to: UUID
    /// Fields of the saved edge this build doesn't know, kept on save.
    public var extras: [String: JSONValue] = [:]

    public init(id: UUID = UUID(), from: UUID, fromPort: SourcePort = .output, to: UUID) {
        self.id = id
        self.from = from
        self.fromPort = fromPort
        self.to = to
    }
}

extension Edge: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, from, fromPort, to
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            from: try container.decode(UUID.self, forKey: .from),
            fromPort: try container.decodeIfPresent(SourcePort.self, forKey: .fromPort) ?? .output,
            to: try container.decode(UUID.self, forKey: .to)
        )
        self.extras = try decoder.unknownFields(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(from, forKey: .from)
        try container.encode(fromPort, forKey: .fromPort)
        try container.encode(to, forKey: .to)
        try encoder.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

// MARK: - Graph

public struct FlowGraph: Hashable, Sendable {
    /// The schema version this build writes. Bump on a breaking format change.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var nodes: [Node]
    public var edges: [Edge]
    /// Top-level fields of the saved flow this build doesn't know, kept on save.
    public var extras: [String: JSONValue] = [:]

    public init(
        schemaVersion: Int = FlowGraph.currentSchemaVersion,
        name: String = "Untitled Flow",
        nodes: [Node] = [],
        edges: [Edge] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.nodes = nodes
        self.edges = edges
    }

    /// True when the file was written by a build with a newer schema version
    /// than this one understands. The app can warn before editing/saving.
    public var isFromNewerSchema: Bool {
        schemaVersion > FlowGraph.currentSchemaVersion
    }

    /// True when any node was preserved verbatim because this build doesn't
    /// recognize its type. Such a flow opens and saves losslessly but can't run.
    public var hasUnsupportedNodes: Bool {
        nodes.contains { $0.kind == .unknown }
    }
}

extension FlowGraph: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, name, nodes, edges
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode nodes as raw JSON first so one unrecognized node is preserved
        // rather than failing the decode of the entire flow file.
        let rawNodes = try container.decodeIfPresent([JSONValue].self, forKey: .nodes) ?? []
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Flow",
            nodes: rawNodes.map(Node.init(preservingUnknownFrom:)),
            edges: try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        )
        self.extras = try decoder.unknownFields(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(name, forKey: .name)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
        try encoder.encodeUnknownFields(extras, excluding: Self.knownKeys)
    }
}

// MARK: - Persistence helpers

public extension FlowGraph {
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(FlowGraph.self, from: jsonData)
    }

    func write(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }
}
