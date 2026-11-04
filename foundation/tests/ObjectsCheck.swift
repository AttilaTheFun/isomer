import Foundation
import Synchronization

// What apps written for Apple's Foundation ask of its object and
// notification API: NSObject, NotificationCenter, OperationQueue,
// NSLocalizedString, a session's cookie storage, Dispatch's time constants,
// NSUUID, and the resource values an app sets on its files.

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

        checkUUIDs()
        checkResourceValues()
    }

    // NSUUID over UUID: from bytes and strings, back to bytes, equal and
    // hashed by value, bridged to and from UUID.
    static func checkUUIDs() {
        let bytes: [UInt8] = [0xE6, 0x21, 0xE1, 0xF8, 0xC3, 0x6C, 0x49, 0x5A, 0x93, 0xFC, 0x0C, 0x24, 0x7A, 0x3E, 0x6E, 0x5F]
        let fromBytes = bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) }
        check("nsuuid bytes", fromBytes.uuidString, "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        check("nsuuid nil bytes", NSUUID(uuidBytes: nil).uuidString, "00000000-0000-0000-0000-000000000000")
        let fromString = NSUUID(uuidString: "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
        check("nsuuid string", "\(fromString?.uuidString ?? "nil") \(NSUUID(uuidString: "not a uuid") == nil)",
              "E621E1F8-C36C-495A-93FC-0C247A3E6E5F true")
        var back = [UInt8](repeating: 0, count: 16)
        back.withUnsafeMutableBufferPointer { fromBytes.getBytes($0.baseAddress!) }
        check("nsuuid getBytes", "\(back == bytes)", "true")
        let random = NSUUID()
        check("nsuuid round trip", "\(NSUUID(uuidString: random.uuidString)?.isEqual(random) ?? false) \(random.uuidString.count)", "true 36")
        check("nsuuid equality", "\(fromBytes.isEqual(fromString)) \(fromBytes == fromString!) \(fromBytes.isEqual(random)) \(fromBytes.hash == fromString!.hash)",
              "true true false true")
        check("nsuuid set", "\(Set([fromBytes, fromString!, random]).count)", "2")
        check("nsuuid description", fromBytes.description, fromBytes.uuidString)
        let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        check("nsuuid compare", "\(fromBytes.compare(uuid) == .orderedSame) \(NSUUID(uuidBytes: nil).compare(uuid) == .orderedAscending)", "true true")
        let bridged = (fromBytes as Any) as? UUID, toObject = (uuid as Any) as? NSUUID
        check("nsuuid bridging", "\(bridged == uuid) \(toObject?.isEqual(fromBytes) ?? false)", "true true")
    }

    // URLResourceValues: the backup and hidden flags accepted, a name
    // renaming the item and moving the URL with it.
    static func checkResourceValues() {
        let fileManager = FileManager.default
        var directory = fileManager.temporaryDirectory.appendingPathComponent("isomer-resources", isDirectory: true)
        let renamedPath = fileManager.temporaryDirectory.appendingPathComponent("isomer-renamed").path
        try? fileManager.removeItem(at: directory)
        try? fileManager.removeItem(atPath: renamedPath)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var flags = URLResourceValues()
            flags.isExcludedFromBackup = true
            flags.isHidden = false
            try directory.setResourceValues(flags)
            check("resource flags", "\(directory.lastPathComponent) \(flags.isExcludedFromBackup ?? false) \(flags.name == nil)",
                  "isomer-resources true true")
            var file = directory.appendingPathComponent("a.txt")
            try Data("a".utf8).write(to: file)
            var name = URLResourceValues()
            name.name = "b.txt"
            try file.setResourceValues(name)
            check("resource name file", "\(file.lastPathComponent) \(fileManager.fileExists(atPath: file.path)) \(fileManager.fileExists(atPath: directory.appendingPathComponent("a.txt").path))",
                  "b.txt true false")
            name.name = "isomer-renamed"
            try directory.setResourceValues(name)
            check("resource name directory", "\(directory.lastPathComponent) \(directory.hasDirectoryPath) \(fileManager.fileExists(atPath: directory.appendingPathComponent("b.txt").path))",
                  "isomer-renamed true true")
            name.name = "a/b"
            check("resource name invalid", "\((try? directory.setResourceValues(name)) == nil)", "true")
            try fileManager.removeItem(at: directory)
        } catch {
            check("resource values", "\(error)", "no error")
        }
    }
}
