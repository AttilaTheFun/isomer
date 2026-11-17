// Built against a wasm_sdk_bundle out of band (program.bzl), as the
// Playground builds a project, and run as a WASI command: Foundation,
// CoreGraphics and Combine from the Swift SDK through the bundle, and
// FoundationInternationalization when the SDK is the -i18n one. Prints
// "FAIL …" for a wrong answer and "ok" at the end.

import Combine
import CoreGraphics
import Foundation
#if canImport(FoundationInternationalization)
import FoundationInternationalization
#endif
import SDKBundleGreeting

var failures = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if !condition {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

func run() {
    // The bundle's own library, over the same Foundation.
    check(greeting("bundle") == "Hello, bundle: 42", "deps' library", greeting("bundle"))

    // Foundation: Essentials, and the classic layer Isomer adds (NSNumber's
    // bridge, JSONSerialization).
    let data = Data("{\"n\": 3, \"s\": \"x\"}".utf8)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    check(json?["n"] as? Int == 3, "JSONSerialization", "\(String(describing: json))")
    check(Data("hi".utf8).base64EncodedString() == "aGk=", "base64")
    let url = URL(string: "https://example.com/a/b?q=1")
    check(url?.lastPathComponent == "b" && url?.query == "q=1", "URL", "\(String(describing: url))")
    let date = Date(timeIntervalSince1970: 86_400)
    check(date.timeIntervalSince1970 == 86_400, "Date")
    struct Point: Codable, Equatable { var x: Int; var y: Int }
    let encoded = try? JSONEncoder().encode(Point(x: 1, y: 2))
    let decoded = encoded.flatMap { try? JSONDecoder().decode(Point.self, from: $0) }
    check(decoded == Point(x: 1, y: 2), "Codable", "\(String(describing: decoded))")

    // CoreGraphics.
    let rect = CGRect(x: 0, y: 0, width: 10, height: 20).insetBy(dx: 2, dy: 3)
    check(rect == CGRect(x: 2, y: 3, width: 6, height: 14), "CGRect", "\(rect)")
    let moved = CGPoint(x: 1, y: 1).applying(CGAffineTransform(translationX: 4, y: 5))
    check(moved == CGPoint(x: 5, y: 6), "CGAffineTransform", "\(moved)")

    // Combine.
    var received: [Int] = []
    let subject = PassthroughSubject<Int, Never>()
    let cancellable = subject.map { $0 * 2 }.sink { received.append($0) }
    subject.send(1)
    subject.send(2)
    cancellable.cancel()
    subject.send(3)
    check(received == [2, 4], "Combine", "\(received)")

    #if canImport(FoundationInternationalization)
    // The -i18n SDK's: ICU's formatting.
    let de = (1234567.891).formatted(.number.locale(Locale(identifier: "de_DE")))
    check(de == "1.234.567,891", "number de_DE", de)
    print("FoundationInternationalization: \(de)")
    #endif

    if failures == 0 { print("ok") }
}

@_cdecl("__main_argc_argv")
func programMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    run()
    return failures == 0 ? 0 : 1
}
