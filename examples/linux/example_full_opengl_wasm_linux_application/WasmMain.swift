// Entry point for the Linux **wasm** example cell. Unlike the compiled cell
// (whose `@main` is the shared `ExampleApplication`), here the UI lives in an
// `example_full.wasm` reactor: this binary loads those bytes and hands them to
// `LinuxWasmApp`, which runs them under WAMR and draws the decoded tree through
// SwiftGPU. The reactor path is passed as the first argument (the
// `run_linux_wasm.sh` wrapper resolves it from the runfiles tree).
//
// Hot reload: if `ISO_HOT_RELOAD_SERVER=http://host:port` is set, the initial
// reactor bytes come from that server and the loop polls it for rebuilds, so
// one server drives this app (and a Windows wasm cell) side by side. Falls back
// to the packaged reactor if the server is unreachable at launch.

import IsomerWasmHost  // LinuxWasmApp, over the swift_ui_wasm module

#if canImport(Glibc)
import Glibc
#endif

@main
struct WasmCellMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: \(arguments.first ?? "wasm_cell") <example_full.wasm>")
            return
        }
        let packaged = readAllBytes(arguments[1])

        // Hot-reload shadow (dev only): serve the reactor from a running
        // //shared/hot_reload:hot_reload_server instead of the packaged file.
        if let server = environment("ISO_HOT_RELOAD_SERVER"),
           let client = HotReloadClient(url: server) {
            let initial = client.fetchWasm() ?? packaged
            guard let bytes = initial else {
                print("error: no reactor bytes (server unreachable and no packaged wasm)")
                return
            }
            print("[wasm-cell] hot-reload: serving from \(server) (build \(client.lastVersion))")
            LinuxWasmApp.run(wasmBytes: bytes, nextReload: { client.nextReload() })
            return
        }

        guard let bytes = packaged else {
            print("error: could not read wasm reactor at \(arguments[1])")
            return
        }
        LinuxWasmApp.run(wasmBytes: bytes)
    }
}

/// Reads a whole file into memory via C stdio (no Foundation).
private func readAllBytes(_ path: String) -> [UInt8]? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    guard fseek(file, 0, SEEK_END) == 0 else { return nil }
    let size = ftell(file)
    guard size > 0 else { return nil }
    rewind(file)
    var buffer = [UInt8](repeating: 0, count: Int(size))
    let read = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, Int(size), file) }
    return read == Int(size) ? buffer : nil
}

private func environment(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

// MARK: - Hot-reload client (polls the portable hot_reload_server)

/// Polls `GET /version` (a build counter) and re-fetches `GET /wasm` on a bump —
/// the desktop peer of Apple's `HotReloadServerSource`, over blocking BSD
/// sockets (no Foundation URLSession in this loader).
final class HotReloadClient {
    private let host: String
    private let port: UInt16
    private(set) var lastVersion: Int = .min

    /// Parses `http://host:port` (path ignored). Returns nil if malformed.
    init?(url: String) {
        var rest = url
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
        guard let h = parts.first, !h.isEmpty else { return nil }
        host = h
        port = parts.count > 1 ? (UInt16(parts[1]) ?? 8787) : 80
        // Seed the baseline so nextReload() only fires on a subsequent build.
        lastVersion = fetchVersion() ?? .min
    }

    /// Fresh bytes when the build counter has advanced since the last poll.
    func nextReload() -> [UInt8]? {
        guard let version = fetchVersion(), version != lastVersion else { return nil }
        lastVersion = version
        return fetchWasm()
    }

    func fetchVersion() -> Int? {
        guard let body = httpGet("/version") else { return nil }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: [" ", "\n", "\r", "\t"])
        return Int(text)
    }

    func fetchWasm() -> [UInt8]? {
        guard let body = httpGet("/wasm"), !body.isEmpty else { return nil }
        return body
    }

    /// Blocking HTTP/1.1 GET; returns the response body (server sends
    /// `Connection: close`, so the body runs to EOF). nil on any failure.
    private func httpGet(_ path: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        guard connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { ptr in send(sock, ptr, strlen(ptr), 0) }
        guard sent > 0 else { return nil }

        var response: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { recv(sock, $0.baseAddress, 65536, 0) }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<Int(n)])
        }

        // Split headers from body at the blank line.
        let separator: [UInt8] = [13, 10, 13, 10]  // \r\n\r\n
        guard let range = firstRange(of: separator, in: response) else { return nil }
        return Array(response[range.upperBound...])
    }

    private func firstRange(of pattern: [UInt8], in data: [UInt8]) -> Range<Int>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        for start in 0...(data.count - pattern.count) where Array(data[start..<start + pattern.count]) == pattern {
            return start..<(start + pattern.count)
        }
        return nil
    }
}
