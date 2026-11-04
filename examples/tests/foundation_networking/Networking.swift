// Code written for Linux, which takes URLSession from FoundationNetworking:
// with Isomer's Foundation (Android, the web) that import is Isomer's
// FoundationNetworking (//foundation/networking), so URLSession is one type,
// not Isomer's beside the Swift SDK's corelibs one.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func session() -> URLSession {
    URLSession(configuration: .ephemeral)
}

func request(_ url: URL) -> URLRequest {
    URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
}
