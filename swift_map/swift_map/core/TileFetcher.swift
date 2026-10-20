// The injectable network layer: the engine decides *what* to fetch; a
// TileFetcher moves the bytes. `FoundationTileFetcher` is the provided
// cross-platform implementation (URLSession, via FoundationNetworking off
// Darwin); platforms with their own networking stacks (the Android host's
// HttpURLConnection pool, the browser's fetch) inject their own instead.

/// Fetches raw tile image bytes (PNG/JPEG) for a URL. Implementations may
/// call `completion` on any thread; the caller marshals back to its render
/// thread.
public protocol TileFetcher: AnyObject {
    func fetch(url: String, completion: @escaping ([UInt8]?) -> Void)
}

// Darwin + Linux + Windows: platforms whose Swift runtime ships URLSession
// without bloating the artifact (the Android SDK has FoundationNetworking
// too, but linking it drags libcurl into the .so — the Android host injects
// a HttpURLConnection-backed fetcher instead).
#if canImport(Darwin) || os(Linux) || os(Windows)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The provided URLSession-backed fetcher, with the identifying User-Agent
/// the OSM tile policy requires.
public final class FoundationTileFetcher: TileFetcher {
    private let session: URLSession

    public init(userAgent: String = "SwiftMap/0.1 (+https://github.com/AttilaTheFun/isomer)") {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: configuration)
    }

    public func fetch(url: String, completion: @escaping ([UInt8]?) -> Void) {
        guard let requestURL = URL(string: url) else {
            completion(nil)
            return
        }
        let task = session.dataTask(with: requestURL) { data, response, _ in
            if let data,
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                completion([UInt8](data))
            } else {
                completion(nil)
            }
        }
        task.resume()
    }
}

#endif
