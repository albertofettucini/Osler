import Foundation

// MARK: - Server configuration

/// One MCP server the user configured: a local command Osler launches and
/// speaks JSON-RPC with over stdio. Nothing else — no HTTP, no OAuth (v1.1
/// scope is deliberately hard-limited).
public struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The launch command as typed, e.g. "npx -y @modelcontextprotocol/server-filesystem /tmp".
    /// Split on whitespace and resolved through /usr/bin/env.
    public var command: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, command: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Server",
            command: try container.decodeIfPresent(String.self, forKey: .command) ?? "",
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    private enum CodingKeys: String, CodingKey { case id, name, command, enabled }
}

// MARK: - Tool-calling vocabulary

/// A tool as shown to the model.
public struct LLMTool: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The model asking for one tool invocation.
public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Raw JSON of the arguments, exactly as the model produced them.
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// One entry of a tool-loop conversation, provider-neutral. Each provider
/// translates these to its own wire format.
public enum LLMMessage: Equatable, Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResult(callID: String, content: String, isError: Bool)
}

/// What one non-streamed model turn produced.
public struct LLMTurnResult: Sendable {
    public let text: String
    public let toolCalls: [ToolCall]

    public init(text: String, toolCalls: [ToolCall]) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

/// Executes tools for the engine. `MCPToolbox` is the real one; tests use
/// mocks, which is why the engine depends on this protocol only.
public protocol ToolExecutor: Sendable {
    func tools(for serverIDs: [String]) async -> [LLMTool]
    /// Never throws: failures come back as (message, isError: true) so the
    /// model can read the error and try something else.
    ///
    /// `allowedServerIDs` is the calling agent's own list. A model that
    /// hallucinates a tool name belonging to another agent's server must be
    /// refused, not quietly served — otherwise the per-node toggles are
    /// decoration rather than a boundary.
    func call(name: String, argumentsJSON: String,
              allowedServerIDs: [String]) async -> (content: String, isError: Bool)
}
