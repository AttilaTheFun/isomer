// The agent's two research tools: `web_search` (a search through the
// signed-in provider — OpenRouter's web plugin or Anthropic's server-side
// search tool — so it rides the user's one key and is billed with the
// model) and `fetch_url` (a plain GET from the device, converted to text).
// Search finds the page; fetch reads it, e.g. a public API's real JSON
// before the agent writes the decoding code.

import Foundation

enum WebTools {
    /// Search results as one tool-result string: a summary paragraph, then
    /// the pages found (title, URL, snippet) for `fetch_url` to follow.
    static func search(query: String, provider: ModelProvider, key: String) async -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "error: empty query" }
        do {
            switch provider {
            case .openRouter: return try await openRouterSearch(query: query, key: key)
            case .anthropic: return try await anthropicSearch(query: query, key: key)
            }
        } catch {
            return "error: search failed: \(error.localizedDescription)"
        }
    }

    // OpenRouter's `web` plugin (Exa by default) attaches url_citation
    // annotations to the answer; a small, fast model does the reading.
    private static func openRouterSearch(query: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/AttilaTheFun/isomer", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Isomer Playground", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": "openai/gpt-4o-mini",
            "plugins": [["id": "web", "engine": "exa", "max_results": 5]],  // ~$0.007 per call, billed with the model
            "messages": [
                ["role": "system", "content": "You are a search engine backing a coding agent. Using the web results, answer the query in a short factual paragraph. Quote exact URLs, endpoint paths and JSON field names when the query is about an API. Do not speculate beyond the results."],
                ["role": "user", "content": query],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else { throw ChatError.http(status, String(decoding: data.prefix(400), as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw ChatError.http(status, "unexpected response")
        }
        var out = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [String] = []
        for annotation in message["annotations"] as? [[String: Any]] ?? [] {
            guard let citation = annotation["url_citation"] as? [String: Any], let url = citation["url"] as? String else { continue }
            let title = citation["title"] as? String ?? url
            var line = "- \(title) — \(url)"
            if let snippet = citation["content"] as? String, !snippet.isEmpty {
                line += "\n  " + collapseWhitespace(snippet).prefix(300)
            }
            results.append(line)
        }
        if !results.isEmpty { out += "\n\nResults (fetch_url reads a page):\n" + results.joined(separator: "\n") }
        return out.isEmpty ? "(no results)" : out
    }

    // Anthropic's server-side web search tool: the model searches during the
    // request; results come back as web_search_tool_result blocks.
    private static func anthropicSearch(query: String, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1024,
            "system": "You are a search engine backing a coding agent. Search the web for the query, then answer in a short factual paragraph. Quote exact URLs, endpoint paths and JSON field names when the query is about an API. Do not speculate beyond the results.",
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 2]],
            "messages": [["role": "user", "content": query]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else { throw ChatError.http(status, String(decoding: data.prefix(400), as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ChatError.http(status, "unexpected response")
        }
        var text = ""
        var results: [String] = []
        var seen = Set<String>()
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "web_search_tool_result":
                for result in block["content"] as? [[String: Any]] ?? [] {
                    guard let url = result["url"] as? String, seen.insert(url).inserted else { continue }
                    results.append("- \(result["title"] as? String ?? url) — \(url)")
                }
            default: break
            }
        }
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !results.isEmpty { out += "\n\nResults (fetch_url reads a page):\n" + results.joined(separator: "\n") }
        return out.isEmpty ? "(no results)" : out
    }

    /// GETs a public http(s) URL and returns its body as text: HTML is
    /// reduced to its visible text, JSON and plain text pass through. Capped
    /// so a page cannot flood the transcript; private hosts are refused so
    /// the tool cannot probe the phone's network.
    static func fetch(urlString: String, maxBytes: Int = 400_000, maxCharacters: Int = 30_000) async -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return "error: fetch_url takes an absolute http(s) URL"
        }
        if isPrivateHost(host) { return "error: \(host) is not a public host" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone) IsomerPlayground/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, application/json, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let truncatedBytes = data.count > maxBytes
            let bytes = truncatedBytes ? data.prefix(maxBytes) : data
            guard !isBinary(type: type, bytes: bytes) else {
                return "HTTP \(status), \(type.isEmpty ? "binary" : type), \(data.count) bytes — not text; use the URL directly (e.g. AsyncImage)."
            }
            var text = String(decoding: bytes, as: UTF8.self)
            if type.contains("html") || (type.isEmpty && text.range(of: "<html", options: .caseInsensitive) != nil) {
                text = htmlToText(text)
            }
            var out = "HTTP \(status)"
            if !type.isEmpty { out += ", " + type.split(separator: ";").first.map(String.init)! }
            out += " (\(data.count) bytes)\n\n"
            if text.count > maxCharacters || truncatedBytes {
                out += String(text.prefix(maxCharacters)) + "\n\n[truncated]"
            } else {
                out += text
            }
            return out
        } catch {
            return "error: fetch failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") { return true }
        // IPv4 literals: loopback, link-local, RFC 1918, CGNAT, unspecified.
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (0, _), (169, 254): return true
            case (172, 16...31), (192, 168), (100, 64...127): return true
            default: return false
            }
        }
        // IPv6 literals: loopback, unique-local, link-local, v4-mapped private.
        if host.contains(":") {
            if host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") { return true }
            if let mapped = host.split(separator: ":").last, mapped.contains(".") { return isPrivateHost(String(mapped)) }
        }
        return false
    }

    private static func isBinary(type: String, bytes: Data) -> Bool {
        if type.hasPrefix("image/") || type.hasPrefix("audio/") || type.hasPrefix("video/") || type.hasPrefix("font/")
            || type.contains("octet-stream") || type.contains("/pdf") || type.contains("/zip") || type.contains("wasm") { return true }
        // No usable content type: sniff for NUL bytes in the head.
        return type.isEmpty && bytes.prefix(512).contains(0)
    }

    /// Visible text of an HTML document: scripts/styles dropped, block tags
    /// become line breaks, entities decoded, whitespace collapsed.
    static func htmlToText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr|/h[1-6]|/section|/article|/header|/footer|/pre|/blockquote|/table)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#x27;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©"]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        text = text.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
        // Collapse runs of spaces within lines and blank lines between them.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseWhitespace(String($0)) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && out.last?.isEmpty == true) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).joined(separator: " ")
    }
}
