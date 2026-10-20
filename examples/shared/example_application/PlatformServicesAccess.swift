// How the example app reaches the network and its files: Foundation's own,
// as an app on Apple platforms does. `URLSession` goes through the host's
// networking (the browser's fetch on the web, Android's own client, Apple's
// URLSession in a WasmView), and the app's files are FileManager's, in its
// Application Support, which persists on every platform. The same code runs
// compiled (Apple / Linux / Windows / Android) and as a wasm reactor under
// every host.

import Foundation
import SwiftUI
#if (os(Linux) || os(Windows)) && canImport(FoundationNetworking)
// The toolchain's Foundation there (Isomer's is on wasm and Android) keeps
// URLSession in a module of its own.
import FoundationNetworking
#endif

/// GET `url` and hand back the body as text. A failed request (or a status
/// other than 2xx) throws; the completion form gives nil and the models show
/// their empty state.
enum Networking {
    static func fetchText(_ url: String) async throws -> String {
        guard let address = URL(string: url) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: address)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Completion form, delivered on the main actor (where the models mutate
    /// their published state).
    static func fetch(_ url: String, completion: @escaping @MainActor (String?) -> Void) {
        Task { @MainActor in
            do {
                completion(try await fetchText(url))
            } catch {
                completion(nil)
            }
        }
    }
}

/// Text files in the app's Application Support (FileManager's).
enum SandboxFiles {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("example_application", isDirectory: true)
    }

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name, isDirectory: false)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ name: String, _ contents: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: directory.appendingPathComponent(name, isDirectory: false))
    }
}
