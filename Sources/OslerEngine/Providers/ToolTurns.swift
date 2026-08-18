import Foundation

// MARK: - Tool-calling turns (non-streamed) for the two hosted providers.
//
// Bodies are built as JSONValue rather than bespoke Codable structs: the
// shapes are deeply nested, appear exactly once each, and JSONValue keeps
// the wire format visible at the call site.

extension AnthropicProvider {
    public func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMProviderError.missingAPIKey(.anthropic) }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "messages": .array(Self.encodeMessages(transcript)),
        ]
        if let system = request.systemPrompt { body["system"] = .string(system) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                ])
            })
        }

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let result = try await ToolTurnHTTP.json(for: urlRequest)

        // content: [{type: text|tool_use, …}]
        var text = ""
        var calls: [ToolCall] = []
        if case .object(let object) = result, case .array(let content)? = object["content"] {
            for block in content {
                guard case .object(let item) = block, case .string(let type)? = item["type"] else { continue }
                switch type {
                case "text":
                    if case .string(let chunk)? = item["text"] { text += chunk }
                case "tool_use":
                    guard case .string(let id)? = item["id"],
                          case .string(let name)? = item["name"] else { continue }
                    let input = item["input"] ?? .object([:])
                    calls.append(ToolCall(id: id, name: name,
                                          argumentsJSON: ToolTurnHTTP.encodeJSON(input)))
                default:
                    break
                }
            }
        }
        return LLMTurnResult(text: text, toolCalls: calls)
    }

    /// Anthropic requires strictly alternating roles, so consecutive tool
    /// results collapse into ONE user message of tool_result blocks.
    static func encodeMessages(_ transcript: [LLMMessage]) -> [JSONValue] {
        var messages: [JSONValue] = []
        var pendingResults: [JSONValue] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            messages.append(.object(["role": .string("user"), "content": .array(pendingResults)]))
            pendingResults = []
        }

        for entry in transcript {
            switch entry {
            case .user(let text):
                flushResults()
                messages.append(.object([
                    "role": .string("user"),
                    "content": .array([.object([
                        "type": .string("text"),
                        // Empty content is a 400 from the API.
                        "text": .string(text.isEmpty ? "(no input was provided)" : text),
                    ])]),
                ]))
            case .assistant(let text, let toolCalls):
                flushResults()
                var blocks: [JSONValue] = []
                if !text.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string(text)]))
                }
                for call in toolCalls {
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": ToolTurnHTTP.decodeJSON(call.argumentsJSON),
                    ]))
                }
                if blocks.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string("")]))
                }
                messages.append(.object(["role": .string("assistant"), "content": .array(blocks)]))
            case .toolResult(let callID, let content, let isError):
                pendingResults.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(callID),
                    // A tool that returned nothing still has to say something,
                    // or the whole turn is rejected.
                    "content": .string(content.isEmpty ? "(the tool returned no output)" : content),
                    "is_error": .bool(isError),
                ]))
            }
        }
        flushResults()
        return messages
    }
}

extension OpenAIProvider {
    public func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMProviderError.missingAPIKey(.openai) }

        var messages: [JSONValue] = []
        if let system = request.systemPrompt {
            messages.append(.object(["role": .string("system"), "content": .string(system)]))
        }
        for entry in transcript {
            switch entry {
            case .user(let text):
                messages.append(.object(["role": .string("user"), "content": .string(text)]))
            case .assistant(let text, let toolCalls):
                var message: [String: JSONValue] = ["role": .string("assistant")]
                message["content"] = text.isEmpty ? .null : .string(text)
                if !toolCalls.isEmpty {
                    message["tool_calls"] = .array(toolCalls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.argumentsJSON),
                            ]),
                        ])
                    })
                }
                messages.append(.object(message))
            case .toolResult(let callID, let content, _):
                messages.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(callID),
                    "content": .string(content),
                ]))
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            (usesLegacyMaxTokens ? "max_tokens" : "max_completion_tokens"):
                .number(Double(request.maxTokens)),
        ]
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ]),
                ])
            })
        }

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let result = try await ToolTurnHTTP.json(for: urlRequest)

        var text = ""
        var calls: [ToolCall] = []
        if case .object(let object) = result,
           case .array(let choices)? = object["choices"],
           case .object(let choice)? = choices.first,
           case .object(let message)? = choice["message"] {
            if case .string(let content)? = message["content"] { text = content }
            if case .array(let toolCalls)? = message["tool_calls"] {
                for entry in toolCalls {
                    guard case .object(let call) = entry,
                          case .string(let id)? = call["id"],
                          case .object(let function)? = call["function"],
                          case .string(let name)? = function["name"] else { continue }
                    var arguments = "{}"
                    if case .string(let raw)? = function["arguments"] { arguments = raw }
                    calls.append(ToolCall(id: id, name: name, argumentsJSON: arguments))
                }
            }
        }
        return LLMTurnResult(text: text, toolCalls: calls)
    }
}

extension OllamaProvider {
    /// Forward explicitly — the protocol's default would silently drop tools.
    public func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult {
        do {
            return try await innerProvider.completeTurn(request, tools: tools, transcript: transcript)
        } catch {
            throw Self.friendly(error)
        }
    }
}

// MARK: - Shared plumbing

enum ToolTurnHTTP {
    /// POSTs and returns the decoded JSON body, mapping HTTP errors the same
    /// way the streaming paths do.
    static func json(for request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.api(statusCode: http.statusCode, message: String(message.prefix(600)))
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw LLMProviderError.invalidResponse("not JSON (\(data.count) bytes)")
        }
    }

    static func encodeJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeJSON(_ raw: String) -> JSONValue {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }
}
