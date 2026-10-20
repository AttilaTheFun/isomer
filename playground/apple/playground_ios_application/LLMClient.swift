// Streaming chat clients behind one protocol: OpenRouter (OpenAI-style
// chat completions + tool calls, SSE) and the Anthropic Messages API.
// Messages are kept in a provider-neutral form and serialized per provider.

import Foundation

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// JSON object text of the arguments.
    var arguments: String
}

/// One transcript entry.
struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, tool }
    var id: String = UUID().uuidString
    var role: Role
    var text: String = ""
    var toolCalls: [ToolCall] = []
    /// For `.tool` messages: which call this answers.
    var toolCallID: String?
    var toolName: String?
    var createdAt: Date = Date()
    /// Attached images (project-relative paths under images/): the user's
    /// mocks and photos, or a `screenshot` tool's capture.
    var images: [String]? = nil

    var imagePaths: [String] { images ?? [] }
}

/// A tool the model may call (JSON-schema parameters).
struct ToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]
}

enum StreamEvent {
    case text(String)
    case toolCall(ToolCall)
    case finished(stopReason: String)
}

/// Per-request options beyond the model id.
struct ChatOptions {
    /// "low" / "medium" / "high", or "" for the model's default.
    var reasoningEffort: String = ""
    /// Loads an attached image's JPEG bytes by its message-relative path.
    var resolveImage: ((String) -> Data?)? = nil
}

extension ChatOptions {
    /// Base64 JPEG payloads for a message's attachments (unreadable ones skipped).
    func imageData(for message: ChatMessage) -> [String] {
        message.imagePaths.compactMap { resolveImage?($0)?.base64EncodedString() }
    }
}

protocol ChatModel {
    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec], model: String, options: ChatOptions) -> AsyncThrowingStream<StreamEvent, Error>
}

enum ChatError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        if case .http(let code, let body) = self { return "HTTP \(code): \(body.prefix(400))" }
        return nil
    }
}

/// Splits an SSE byte stream into `data:` payloads.
private func sseLines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                for try await line in bytes.lines {
                    if line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if !payload.isEmpty { continuation.yield(payload) }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

// MARK: - OpenRouter (OpenAI chat completions)

struct OpenRouterClient: ChatModel {
    let key: String

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec], model: String, options: ChatOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        func parts(_ text: String, _ images: [String]) -> Any {
            guard !images.isEmpty else { return text }
            var out: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
            for image in images {
                out.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]])
            }
            return out
        }
        for message in messages {
            switch message.role {
            case .user:
                wire.append(["role": "user", "content": parts(message.text, options.imageData(for: message))])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    entry["tool_calls"] = message.toolCalls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                    }
                }
                wire.append(entry)
            case .tool:
                guard let callID = message.toolCallID else {
                    wire.append(["role": "user", "content": "[Note from the Playground (\(message.toolName ?? "app"))] " + message.text])
                    continue
                }
                wire.append(["role": "tool", "tool_call_id": callID, "content": message.text])
                // Chat-completions tool results are text-only: a screenshot
                // rides in a user turn right after its tool result.
                let images = options.imageData(for: message)
                if !images.isEmpty {
                    wire.append(["role": "user", "content": parts("Image from the \(message.toolName ?? "tool") tool result above.", images)])
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "messages": wire,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]]
            }
        }
        if !options.reasoningEffort.isEmpty { body["reasoning"] = ["effort": options.reasoningEffort] }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/AttilaTheFun/isomer", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Isomer Playground", forHTTPHeaderField: "X-Title")
        request.httpBody = jsonData(body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status >= 300 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw ChatError.http(status, text)
                    }
                    // Tool-call deltas arrive by index; assemble them.
                    var calls: [Int: ToolCall] = [:]
                    var stop = "stop"
                    for try await payload in sseLines(bytes) {
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                              let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                        if let delta = choice["delta"] as? [String: Any] {
                            if let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let index = call["index"] as? Int ?? 0
                                var current = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                                if let id = call["id"] as? String { current.id = id }
                                if let function = call["function"] as? [String: Any] {
                                    if let name = function["name"] as? String { current.name += name }
                                    if let args = function["arguments"] as? String { current.arguments += args }
                                }
                                calls[index] = current
                            }
                        }
                        if let reason = choice["finish_reason"] as? String { stop = reason }
                    }
                    for index in calls.keys.sorted() {
                        var call = calls[index]!
                        if call.id.isEmpty { call.id = "call_\(index)_\(UUID().uuidString.prefix(6))" }
                        if call.arguments.isEmpty { call.arguments = "{}" }
                        continuation.yield(.toolCall(call))
                    }
                    continuation.yield(.finished(stopReason: stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Anthropic Messages API

struct AnthropicClient: ChatModel {
    let key: String

    func stream(system: String, messages: [ChatMessage], tools: [ToolSpec], model: String, options: ChatOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        // Consecutive tool results fold into one user turn.
        var wire: [[String: Any]] = []
        func imageBlocks(_ images: [String]) -> [[String: Any]] {
            images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]] }
        }
        for message in messages {
            switch message.role {
            case .user:
                let images = options.imageData(for: message)
                if images.isEmpty {
                    wire.append(["role": "user", "content": message.text])
                } else {
                    var blocks: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
                    blocks += imageBlocks(images)
                    wire.append(["role": "user", "content": blocks])
                }
            case .assistant:
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [String: Any]()
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                wire.append(["role": "assistant", "content": blocks])
            case .tool:
                guard let callID = message.toolCallID else {
                    wire.append(["role": "user", "content": "[Note from the Playground (\(message.toolName ?? "app"))] " + message.text])
                    continue
                }
                let images = options.imageData(for: message)
                let resultContent: Any = images.isEmpty
                    ? message.text
                    : [["type": "text", "text": message.text]] + imageBlocks(images)
                let block: [String: Any] = ["type": "tool_result", "tool_use_id": callID, "content": resultContent]
                if var last = wire.last, last["role"] as? String == "user", var content = last["content"] as? [[String: Any]] {
                    content.append(block)
                    last["content"] = content
                    wire[wire.count - 1] = last
                } else {
                    wire.append(["role": "user", "content": [block]])
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": system,
            "messages": wire,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        }
        if !options.reasoningEffort.isEmpty {
            let budget = ["low": 2048, "medium": 8192, "high": 32768, "xhigh": 65536, "max": 131072][options.reasoningEffort] ?? 8192
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            body["max_tokens"] = budget + 8192
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData(body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status >= 300 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw ChatError.http(status, text)
                    }
                    var blocks: [Int: ToolCall] = [:]
                    var stop = "end_turn"
                    for try await payload in sseLines(bytes) {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "content_block_start":
                            if let index = json["index"] as? Int,
                               let block = json["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use" {
                                blocks[index] = ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: "")
                            }
                        case "content_block_delta":
                            guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any] else { continue }
                            if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            } else if delta["type"] as? String == "input_json_delta", let part = delta["partial_json"] as? String {
                                blocks[index]?.arguments += part
                            }
                        case "content_block_stop":
                            if let index = json["index"] as? Int, var call = blocks.removeValue(forKey: index) {
                                if call.arguments.isEmpty { call.arguments = "{}" }
                                continuation.yield(.toolCall(call))
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stop = reason }
                        case "error":
                            throw ChatError.http(500, payload)
                        default: break
                        }
                    }
                    continuation.yield(.finished(stopReason: stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Model catalog (OpenRouter)

struct ModelInfo: Identifiable, Hashable {
    var id: String
    var name: String
    /// USD per million prompt tokens (for the "cheap vs pricey" hint).
    var promptPrice: Double?
    /// The provider slug (the id's prefix on OpenRouter: "anthropic").
    var provider: String = ""
    var contextLength: Int? = nil
    var supportsTools = true
    var supportsImages = false
    /// Unix seconds the model was listed (OpenRouter `created`).
    var created: Double? = nil
    /// Reasoning efforts the model accepts (OpenRouter `reasoning.supported_efforts`).
    var supportedEfforts: [String] = []
    /// Best coding-arena Elo from OpenRouter's design-arena benchmarks
    /// (the "fullstack" agents category when present).
    var codingArena: Double? = nil

    var isFree: Bool { promptPrice == 0 }

    /// "200k" / "1M" for the context window.
    var contextLabel: String? {
        guard let contextLength else { return nil }
        if contextLength >= 1_000_000 { return String(format: "%.0fM", Double(contextLength) / 1_000_000) }
        return "\(contextLength / 1000)k"
    }

    var priceLabel: String? {
        guard let promptPrice else { return nil }
        if promptPrice == 0 { return "free" }
        return promptPrice < 1 ? String(format: "$%.2f/M", promptPrice) : String(format: "$%.1f/M", promptPrice)
    }
}

enum ModelCatalog {
    static let anthropicDirect: [ModelInfo] = [
        ModelInfo(id: "claude-fable-5-1", name: "Claude Fable 5.1", promptPrice: nil),
        ModelInfo(id: "claude-opus-5", name: "Claude Opus 5", promptPrice: nil),
        ModelInfo(id: "claude-sonnet-5", name: "Claude Sonnet 5", promptPrice: nil),
        ModelInfo(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", promptPrice: nil),
    ]

    /// GET https://openrouter.ai/api/v1/models — every model, with the
    /// capabilities the picker filters on (tools, image input, context,
    /// price, listing date).
    static func openRouterModels(key: String) async -> [ModelInfo] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let models = parseOpenRouter(data)
        if !models.isEmpty { try? data.write(to: cacheURL) }
        return models
    }

    /// The last fetched catalog (shown at once while a refresh runs).
    static func cachedOpenRouterModels() -> [ModelInfo] {
        (try? Data(contentsOf: cacheURL)).map(parseOpenRouter) ?? []
    }

    private static var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("openrouter_models.json")
    }

    private static func parseOpenRouter(_ data: Data) -> [ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        var models: [ModelInfo] = []
        for entry in list {
            guard let id = entry["id"] as? String else { continue }
            let supported = (entry["supported_parameters"] as? [String]) ?? []
            let pricing = entry["pricing"] as? [String: Any]
            let prompt = (pricing?["prompt"] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            let architecture = entry["architecture"] as? [String: Any]
            let inputs = (architecture?["input_modalities"] as? [String]) ?? []
            let created = (entry["created"] as? NSNumber)?.doubleValue
            let context = (entry["context_length"] as? NSNumber)?.intValue
            let reasoning = entry["reasoning"] as? [String: Any]
            let efforts = (reasoning?["supported_efforts"] as? [String]) ?? []
            var arena: Double?
            if let benchmarks = entry["benchmarks"] as? [String: Any],
               let design = benchmarks["design_arena"] as? [[String: Any]] {
                let agents = design.filter { ($0["arena"] as? String) == "agents" }
                let fullstack = agents.first { ($0["category"] as? String) == "fullstack" }
                arena = ((fullstack ?? agents.max { elo($0) < elo($1) })).map(elo)
            }
            models.append(ModelInfo(
                id: id, name: entry["name"] as? String ?? id, promptPrice: prompt,
                provider: id.split(separator: "/").first.map(String.init) ?? "",
                contextLength: context,
                supportsTools: supported.contains("tools"),
                supportsImages: inputs.contains("image"),
                created: created,
                supportedEfforts: efforts,
                codingArena: arena))
        }
        return models
    }

    private static func elo(_ entry: [String: Any]) -> Double {
        (entry["elo"] as? NSNumber)?.doubleValue ?? 0
    }

    /// OpenRouter's most-used models for programming (its rankings' coding
    /// category — the closest thing to a popularity signal the API exposes),
    /// in rank order. Cached like the catalog.
    static func openRouterPopularForCoding(key: String) async -> [String] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?category=programming")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        let ids = parseOpenRouter(data).map(\.id)
        if !ids.isEmpty { try? data.write(to: popularCacheURL) }
        return ids
    }

    static func cachedPopularForCoding() -> [String] {
        (try? Data(contentsOf: popularCacheURL)).map(parseOpenRouter)?.map(\.id) ?? []
    }

    private static var popularCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("openrouter_models_programming.json")
    }
}
