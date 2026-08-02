import Foundation

/// Owns the MCP sessions for one run: launches the enabled servers, indexes
/// their tools, routes calls, and shuts everything down afterwards.
public actor MCPToolbox: ToolExecutor {
    public struct StartFailure: Sendable {
        public let serverName: String
        public let message: String
    }

    private var clients: [String: MCPClient] = [:]
    private var toolsByServer: [String: [LLMTool]] = [:]
    /// tool name → owning server. First server to claim a name wins; later
    /// duplicates are dropped (kept simple on purpose).
    private var toolOwners: [String: String] = [:]
    public private(set) var failures: [StartFailure] = []

    public init() {}

    public func start(servers: [MCPServerConfig]) async {
        for server in servers where server.enabled {
            do {
                let client = try MCPClient(command: server.command)
                try await client.initialize()
                let infos = try await client.listTools()
                clients[server.id] = client
                var tools: [LLMTool] = []
                for info in infos where toolOwners[info.name] == nil {
                    toolOwners[info.name] = server.id
                    tools.append(LLMTool(name: info.name,
                                         description: info.description,
                                         inputSchema: info.inputSchema))
                }
                toolsByServer[server.id] = tools
            } catch {
                failures.append(StartFailure(
                    serverName: server.name,
                    message: String(describing: error)
                ))
            }
        }
    }

    public func tools(for serverIDs: [String]) async -> [LLMTool] {
        serverIDs.flatMap { toolsByServer[$0] ?? [] }
    }

    public func call(name: String, argumentsJSON: String) async -> (content: String, isError: Bool) {
        guard let serverID = toolOwners[name], let client = clients[serverID] else {
            return ("The tool \"\(name)\" is not available.", true)
        }
        do {
            return try await client.callTool(name: name, argumentsJSON: argumentsJSON)
        } catch {
            return (String(describing: error), true)
        }
    }

    public func shutdown() async {
        for client in clients.values {
            await client.shutdown()
        }
        clients = [:]
        toolsByServer = [:]
        toolOwners = [:]
    }
}
