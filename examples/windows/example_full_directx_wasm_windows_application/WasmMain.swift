// Entry point for the Windows **wasm** example cell. Unlike the compiled cell
// (whose `@main` is the shared `ExampleApplication`), here the UI lives in an
// `example_full.wasm` reactor: this .exe loads those bytes and hands them to
// `WindowsWasmApp`, which runs them on WasmKit and draws the decoded tree
// through SwiftGPU/D3D11. The reactor path is passed as the first argument —
// build it where the SwiftWasm toolchain runs (WSL/Linux/macOS:
// `bazel build -c opt //examples/wasm/example_full_feature:example_full.wasm`)
// — or serve it via ISO_HOT_RELOAD_SERVER; there is no committed prebuilt.
//
// Hot reload: if `ISO_HOT_RELOAD_SERVER=http://host:port` is set, the reactor
// comes from that server and the loop polls it for rebuilds, so one server
// drives this app and a Linux wasm cell side by side.

import IsomerDesktopWasmHost  // LinuxWasmApp / WindowsWasmApp: the reactor on WasmKit in a window

#if canImport(WinSDK)
import WinSDK
#endif
#if canImport(ucrt)
import ucrt
#endif

@main
@MainActor
struct WasmCellMain {
    static func main() {
        let arguments = CommandLine.arguments
        // Reactor bytes come from an explicit path argument or the hot-reload
        // server. (There is deliberately NO committed prebuilt: the SwiftWasm
        // toolchain doesn't run on a Windows host, so build the reactor in
        // WSL/Linux/macOS and pass its path. See windows/README.md.)
        let reactorPath = arguments.count >= 2 ? arguments[1] : nil
        let packaged = reactorPath.flatMap(readAllBytes)

        if let server = environment("ISO_HOT_RELOAD_SERVER"),
           let client = HotReloadClient(url: server) {
            let initial = client.fetchWasm() ?? packaged
            guard let bytes = initial else {
                print("error: no reactor bytes (server unreachable and no bundled/passed wasm)")
                return
            }
            print("[wasm-cell] hot-reload: serving from \(server) (build \(client.lastVersion))")
            WindowsWasmApp.run(wasmBytes: bytes, nextReload: { client.nextReload() })
            return
        }

        guard let bytes = packaged else {
            print("usage: \(arguments.first ?? "wasm_cell") [example_full.wasm]")
            print("error: no reactor — pass a .wasm path or set ISO_HOT_RELOAD_SERVER")
            return
        }
        WindowsWasmApp.run(wasmBytes: bytes)
    }
}

/// Reads a whole file into memory via C stdio.
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

// MARK: - Hot-reload client (WinSock; peer of the Linux Glibc client)

/// Polls `GET /version` (a build counter) and re-fetches `GET /wasm` on a bump,
/// over blocking WinSock — the desktop peer of Apple's `HotReloadServerSource`.
final class HotReloadClient {
    private let host: String
    private let port: UInt16
    private(set) var lastVersion: Int = .min

    init?(url: String) {
        #if canImport(WinSDK)
        var wsaData = WSADATA()
        _ = WSAStartup(0x0202, &wsaData)
        #endif
        var rest = url
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
        guard let h = parts.first, !h.isEmpty else { return nil }
        host = h
        port = parts.count > 1 ? (UInt16(parts[1]) ?? 8787) : 80
        lastVersion = fetchVersion() ?? .min
    }

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

    #if canImport(WinSDK)
    /// Blocking HTTP/1.1 GET over WinSock; body runs to EOF (server sends
    /// `Connection: close`). nil on any failure.
    private func httpGet(_ path: String) -> [UInt8]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM)
        // WinSDK imports IPPROTO_TCP as an `IPPROTO` enum (not an integer macro,
        // unlike POSIX), so reach its Int32 rawValue for the addrinfo field.
        hints.ai_protocol = Int32(IPPROTO_TCP.rawValue)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock != INVALID_SOCKET else { return nil }
        defer { closesocket(sock) }
        guard connect(sock, info.pointee.ai_addr, Int32(info.pointee.ai_addrlen)) == 0 else { return nil }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { ptr in send(sock, ptr, Int32(strlen(ptr)), 0) }
        guard sent > 0 else { return nil }

        var response: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { raw in
                recv(sock, raw.baseAddress!.assumingMemoryBound(to: CChar.self), 65536, 0)
            }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<Int(n)])
        }

        let separator: [UInt8] = [13, 10, 13, 10]
        guard let range = firstRange(of: separator, in: response) else { return nil }
        return Array(response[range.upperBound...])
    }
    #else
    private func httpGet(_ path: String) -> [UInt8]? { nil }
    #endif

    private func firstRange(of pattern: [UInt8], in data: [UInt8]) -> Range<Int>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        for start in 0...(data.count - pattern.count) where Array(data[start..<start + pattern.count]) == pattern {
            return start..<(start + pattern.count)
        }
        return nil
    }
}
