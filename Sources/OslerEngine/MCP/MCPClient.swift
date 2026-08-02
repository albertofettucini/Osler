import Foundation

public enum MCPError: Error, Sendable, CustomStringConvertible {
    case emptyCommand
    case launchFailed(String)
    case serverClosed
    case timeout(method: String)
    case rpc(String)

    public var description: String {
        switch self {
        case .emptyCommand: return "The MCP server command is empty."
        case .launchFailed(let detail): return "Couldn't launch the MCP server: \(detail)"
        case .serverClosed: return "The MCP server closed the connection."
        case .timeout(let method): return "The MCP server didn't answer \(method) in time."
        case .rpc(let message): return "MCP error: \(message)"
        }
    }
}

/// A minimal MCP client: launches one stdio server and speaks JSON-RPC 2.0
/// with it, newline-delimited. Requests are strictly sequential (the actor
/// serializes them), which is all the engine's tool loop needs.
///
/// Lines are split on raw 0x0A bytes — NOT AsyncLineSequence, which also
/// splits on U+2028/U+2029/NEL and would corrupt JSON payloads containing
/// them (the same lesson as the SSE transport).
public actor MCPClient {
    public struct ToolInfo: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private var byteIterator: FileHandle.AsyncBytes.AsyncIterator
    private var nextID = 1

    public init(command: String) throws {
        let parts = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !parts.isEmpty else { throw MCPError.emptyCommand }

        let process = Process()
        // /usr/bin/env resolves the executable through PATH…
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = parts
        // …but GUI apps inherit a bare PATH, so add the places node/uv/brew
        // actually live.
        var environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin"]
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":" + extras.joined(separator: ":")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.byteIterator = stdoutPipe.fileHandleForReading.bytes.makeAsyncIterator()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    // MARK: Lifecycle

    public func initialize(clientName: String = "Osler") async throws {
        _ = try await request("initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string("1.1"),
            ]),
        ]), timeout: 20)
        try write(message: .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized"),
        ]))
    }

    public func shutdown() {
        if process.isRunning { process.terminate() }
        try? stdinHandle.close()
    }

    // MARK: Tools

    public func listTools() async throws -> [ToolInfo] {
        let result = try await request("tools/list", params: .object([:]), timeout: 20)
        guard case .object(let object) = result, case .array(let tools)? = object["tools"] else {
            return []
        }
        return tools.compactMap { entry in
            guard case .object(let tool) = entry, case .string(let name)? = tool["name"] else {
                return nil
            }
            var description = ""
            if case .string(let text)? = tool["description"] { description = text }
            let schema = tool["inputSchema"] ?? .object(["type": .string("object")])
            return ToolInfo(name: name, description: description, inputSchema: schema)
        }
    }

    /// Runs one tool. isError mirrors the server's flag — the text still
    /// goes back to the model either way, so it can react.
    public func callTool(name: String, argumentsJSON: String) async throws -> (content: String, isError: Bool) {
        let arguments: JSONValue
        if let data = argumentsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            arguments = decoded
        } else {
            arguments = .object([:])
        }
        let result = try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]), timeout: 120)

        guard case .object(let object) = result else { return ("", false) }
        var isError = false
        if case .bool(let flag)? = object["isError"] { isError = flag }
        var texts: [String] = []
        if case .array(let content)? = object["content"] {
            for block in content {
                if case .object(let item) = block, case .string(let text)? = item["text"] {
                    texts.append(text)
                }
            }
        }
        return (texts.joined(separator: "\n"), isError)
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, params: JSONValue, timeout: Double) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        try write(message: .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]))
        return try await withTimeout(seconds: timeout, method: method) {
            try await self.readResponse(id: id)
        }
    }

    private func write(message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    /// Reads messages until the response with `id` arrives. Notifications are
    /// skipped; server→client requests get a polite "not supported" error so
    /// the server never blocks on us.
    private func readResponse(id: Int) async throws -> JSONValue {
        while let line = try await readLine() {
            guard !line.isEmpty,
                  let message = try? JSONDecoder().decode(JSONValue.self, from: line),
                  case .object(let object) = message else { continue }

            if case .string? = object["method"] {
                if let requestID = object["id"] {
                    try? write(message: .object([
                        "jsonrpc": .string("2.0"),
                        "id": requestID,
                        "error": .object([
                            "code": .number(-32601),
                            "message": .string("Osler does not support server-initiated requests."),
                        ]),
                    ]))
                }
                continue // notification or answered request — not our response
            }

            guard case .number(let responseID)? = object["id"], Int(responseID) == id else { continue }

            if case .object(let error)? = object["error"] {
                var message = "unknown error"
                if case .string(let text)? = error["message"] { message = text }
                throw MCPError.rpc(message)
            }
            return object["result"] ?? .null
        }
        throw MCPError.serverClosed
    }

    private func readLine() async throws -> Data? {
        // Swift forbids calling a mutating async iterator on an actor-stored
        // property directly; work on a local copy and write it back.
        var iterator = byteIterator
        defer { byteIterator = iterator }
        var line = Data()
        while let byte = try await iterator.next() {
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return line.isEmpty ? nil : line
    }
}

/// Races an operation against a deadline.
private func withTimeout<T: Sendable>(
    seconds: Double,
    method: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPError.timeout(method: method)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
