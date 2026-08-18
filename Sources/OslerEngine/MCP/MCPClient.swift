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

    /// One request at a time. The transport is a single byte stream, so two
    /// overlapping requests would interleave their reads and hand each caller
    /// a payload spliced from both replies — wrong data, no error.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Set once the transport is gone (timeout, crash, shutdown). Every later
    /// request fails fast instead of touching a broken pipe.
    private var isDead = false

    private func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Deadlines, in seconds. Overridable so tests can prove one actually
    /// fires without waiting two minutes.
    public struct Timeouts: Sendable {
        public var handshake: Double
        public var call: Double
        public init(handshake: Double = 20, call: Double = 120) {
            self.handshake = handshake
            self.call = call
        }
    }

    private let timeouts: Timeouts

    public init(command: String, timeouts: Timeouts = Timeouts()) throws {
        self.timeouts = timeouts
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

        // Without this, writing to a server that has already exited raises
        // SIGPIPE and kills Osler outright — no crash report, no save prompt,
        // the user's unsaved canvas simply gone. With it, the write throws
        // EPIPE and travels the normal error path.
        let nosigpipe: Int32 = 1
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor,
                  F_SETNOSIGPIPE, nosigpipe)

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
        ]), timeout: timeouts.handshake)
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
        let result = try await request("tools/list", params: .object([:]), timeout: timeouts.handshake)
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
        ]), timeout: timeouts.call)

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

    /// Sends one request and waits for its reply.
    ///
    /// The deadline works by tearing the transport down rather than by
    /// cancelling a child task: the read is blocked inside AsyncBytes, which
    /// does not observe cancellation, so the only thing that releases it is
    /// the pipe reaching EOF. Terminating the server does exactly that. The
    /// same applies when the user presses Stop.
    private func request(_ method: String, params: JSONValue, timeout: Double) async throws -> JSONValue {
        guard !isDead else { throw MCPError.serverClosed }
        await acquire()
        defer { release() }
        guard !isDead else { throw MCPError.serverClosed }

        let id = nextID
        nextID += 1
        do {
            try write(message: .object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string(method),
                "params": params,
            ]))
        } catch {
            isDead = true
            throw MCPError.serverClosed
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await self.readResponse(id: id) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self.markDeadAndClose()
                    throw MCPError.timeout(method: method)
                }
                do {
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    // A read that ends because we just killed the server is a
                    // timeout, not a mysterious disconnection.
                    if error is CancellationError { throw error }
                    if isDead, !(error is MCPError) {
                        throw MCPError.timeout(method: method)
                    }
                    throw error
                }
            }
        } onCancel: {
            Task { await self.markDeadAndClose() }
        }
    }

    /// Ends the session and unblocks anything waiting on the stream.
    private func markDeadAndClose() {
        isDead = true
        shutdown()
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
        isDead = true
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
