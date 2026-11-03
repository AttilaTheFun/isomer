import Foundation
import Synchronization

// What apps written for Apple's Foundation ask of its object and
// notification API: NSObject, NotificationCenter, OperationQueue,
// NSLocalizedString, a session's cookie storage, Dispatch's time constants.

final class Model: NSObject {}

final class Named: NSObject {
    let name: String
    init(_ name: String) { self.name = name }
    override func isEqual(_ object: Any?) -> Bool { (object as? Named)?.name == name }
    override var hash: Int { name.hashValue }
}

final class Seen: @unchecked Sendable {
    private let names = Mutex<[String]>([])
    func add(_ name: String) { names.withLock { $0.append(name) } }
    var all: [String] { names.withLock { $0 } }
}

extension FoundationCheck {
    static func checkObjects() async {
        // NSObject: equal by identity unless a subclass says otherwise.
        let a = Model(), b = Model()
        check("nsobject identity", "\(a == a) \(a == b) \(a.isEqual(a)) \(a.isEqual(nil))", "true false true false")
        check("nsobject hash", "\(a.hash == a.hash) \(Set([a, a, b]).count)", "true 2")
        check("nsobject description", "\(a.description.hasPrefix("<Model: 0x"))", "true")
        check("nsobject subclass equality", "\(Named("x") == Named("x")) \(Set([Named("x"), Named("x")]).count)", "true 1")
        let protocolObject: any NSObjectProtocol = a
        check("nsobjectprotocol", "\(protocolObject.isEqual(a))", "true")

        // Notifications: by name, filtered by object, until removed.
        let center = NotificationCenter()
        let seen = Seen()
        let name = Notification.Name("check.ping"), other = NSNotification.Name(rawValue: "check.other")
        let any = center.addObserver(forName: name, object: nil, queue: nil) { seen.add("any:\($0.userInfo?["n"] as? Int ?? 0)") }
        let fromA = center.addObserver(forName: name, object: a, queue: nil) { _ in seen.add("a") }
        let every = center.addObserver(forName: nil, object: nil, queue: nil) { seen.add("every:\($0.name.rawValue)") }
        center.post(name: name, object: a, userInfo: ["n": 1])
        center.post(name: name, object: b)
        center.post(Notification(name: other))
        check("notifications seen", seen.all.sorted().joined(separator: " "),
              "a any:0 any:1 every:check.other every:check.ping every:check.ping")
        center.removeObserver(any)
        center.removeObserver(fromA)
        center.removeObserver(every, name: other, object: nil)
        center.post(name: name, object: a)
        check("notifications removed", "\(seen.all.count)", "7")
        center.removeObserver(every)
        center.post(name: name, object: a)
        check("notifications all removed", "\(seen.all.count)", "7")
        check("notification equality", "\(Notification(name: name, object: a) == Notification(name: name, object: a)) \(Notification(name: name, object: a) == Notification(name: name, object: b))", "true false")

        // An observer on the main queue runs as a task on the main actor.
        let onMain = center.addObserver(forName: name, object: nil, queue: .main) { _ in seen.add("main") }
        center.post(name: name, object: nil)
        for _ in 0..<20 where !seen.all.contains("main") { await Task.yield() }
        check("notification on the main queue", "\(seen.all.contains("main"))", "true")
        center.removeObserver(onMain)

        // As an asynchronous sequence.
        let notifications = center.notifications(named: other)
        Task { center.post(name: other, object: nil, userInfo: ["n": 2]) }
        var iterator = notifications.makeAsyncIterator()
        check("notifications sequence", "\(await iterator.next()?.userInfo?["n"] as? Int ?? 0)", "2")

        check("nslocalizedstring", NSLocalizedString("greeting", comment: "") + " " + NSLocalizedString("k", value: "Hi", comment: ""),
              "greeting Hi")
        let configuration = URLSessionConfiguration.default
        check("cookie storage", "\(configuration.httpCookieStorage === HTTPCookieStorage.shared) \(configuration.urlCredentialStorage != nil)",
              "true true")
        check("nsec per sec", "\(NSEC_PER_SEC / NSEC_PER_MSEC) \(USEC_PER_SEC)", "1000 1000000")
    }
}
