// Every module Isomer's Swift SDKs carry, touched the way an app touches
// it: Foundation's globals and statics (the ones whose module and archive
// must come from one build), FileManager's attributes (the owner and group
// lookups, getpwuid_r and getgrgid_r, which Bionic has from API 24 and the
// SDK must not call below it), NotificationCenter's Combine publisher,
// Combine, CoreGraphics, FoundationNetworking, numbers bridged to NSNumber,
// Isomer's Bridge (which writes to FileHandle.standardError), a Swift
// package from a dependency's isolated graph, and with the -i18n SDK dates
// and numbers formatted by FoundationInternationalization.

import Combine
import CoreGraphics
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Isomer
import SDKConsumerDep

public enum SmokeChecks {
    /// A line a check ("ok <name>" or "FAIL <name>: <why>"), then
    /// "SDKSMOKE PASS" or "SDKSMOKE FAIL".
    public static func report() -> [String] {
        var lines: [String] = []
        var failed = false
        func check(_ name: String, _ body: () throws -> String?) {
            do {
                if let problem = try body() {
                    lines.append("FAIL \(name): \(problem)")
                    failed = true
                } else {
                    lines.append("ok \(name)")
                }
            } catch {
                lines.append("FAIL \(name): \(error)")
                failed = true
            }
        }

        check("Foundation globals and statics") {
            let handles = [FileHandle.standardInput, FileHandle.standardOutput, FileHandle.standardError]
            guard handles.map(\.fileDescriptor) == [0, 1, 2] else { return "standard handles \(handles.map(\.fileDescriptor))" }
            guard NSLocalizedDescriptionKey == "NSLocalizedDescription" else { return "NSLocalizedDescriptionKey \(NSLocalizedDescriptionKey)" }
            let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "gone"])
            guard error.localizedDescription == "gone" else { return "localizedDescription \(error.localizedDescription)" }
            _ = ProcessInfo.processInfo.processIdentifier
            _ = Bundle.main
            _ = UserDefaults.standard
            _ = Locale.current
            _ = TimeZone.current
            return Date.distantPast < Date.distantFuture ? nil : "distantPast"
        }
        check("FileManager attributes (owner and group lookups)") {
            let attributes = try FileManager.default.attributesOfItem(atPath: NSTemporaryDirectory())
            // The names are looked up (getpwuid_r, getgrgid_r); a sandbox
            // may name none, but the call has to link and return.
            _ = attributes[.ownerAccountName]
            _ = attributes[.groupOwnerAccountName]
            return attributes[.type] == nil ? "no file type" : nil
        }
        check("NotificationCenter.publisher") {
            let name = Notification.Name("dev.isomer.sdksmoke")
            var received = 0
            let subscription = NotificationCenter.default.publisher(for: name).sink { _ in received += 1 }
            NotificationCenter.default.post(name: name, object: nil)
            subscription.cancel()
            NotificationCenter.default.post(name: name, object: nil)
            return received == 1 ? nil : "received \(received)"
        }
        check("Combine") {
            var values: [Int] = []
            let subject = PassthroughSubject<Int, Never>()
            let subscription = subject.map { $0 * 2 }.sink { values.append($0) }
            subject.send(1)
            subject.send(2)
            subscription.cancel()
            _ = Just(3).sink { values.append($0) }
            return values == [2, 4, 3] ? nil : "values \(values)"
        }
        check("CoreGraphics") {
            let rect = CGRect(x: 0, y: 0, width: 4, height: 2).applying(CGAffineTransform(scaleX: 2, y: 3))
            return rect.size == CGSize(width: 8, height: 6) ? nil : "rect \(rect)"
        }
        check("FoundationNetworking") {
            var request = URLRequest(url: URL(string: "https://example.invalid/a?b=c")!)
            request.httpMethod = "POST"
            _ = URLSession(configuration: .ephemeral)
            return request.url?.query == "b=c" ? nil : "query \(String(describing: request.url?.query))"
        }
        check("NSNumber bridging") {
            let object = try JSONSerialization.jsonObject(with: Data(#"{"n":7}"#.utf8)) as? [String: Any]
            return object?["n"] as? Int == 7 ? nil : "n \(String(describing: object?["n"]))"
        }
        check("Isomer's Bridge") {
            Bridge.log("sdk smoke")
            return Bridge.epochMilliseconds() > 0 ? nil : "epoch"
        }
        check("a Swift package from an isolated graph") {
            SDKConsumerDep.chunked([1, 2, 3, 4, 5]) == [[1, 2], [3, 4], [5]] ? nil : "chunks"
        }
        #if canImport(FoundationInternationalization)
        check("FoundationInternationalization (the -i18n SDK)") {
            let epoch = Date(timeIntervalSince1970: 0)
            let date = epoch.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "fr_FR"),
                                                         timeZone: TimeZone(identifier: "UTC")!))
            let number = 1234567.formatted(.number.locale(Locale(identifier: "de_DE")))
            return date == "1 janvier 1970" && number == "1.234.567" ? nil : "\(date), \(number)"
        }
        #endif
        lines.append(failed ? "SDKSMOKE FAIL" : "SDKSMOKE PASS")
        return lines
    }
}
