// Signposts for timing a keystroke (or any event) through a wasm host, for
// typing benchmarks: os_signpost intervals in subsystem "dev.isomer.typing",
// category "Typing", read with Instruments, `log stream --signpost`, or an
// XCTest `XCTOSSignpostMetric`. Nothing is recorded unless something asks
// for them, so they stay in.
//
//   input           a text field's change, in the host (IsomerTree's
//                   EchoedText): the native callback, guest-event within
//   guest-event     the event's calls into the guest (WasmFeatureRuntime)
//   guest-render    the frame the host pumps: the guest's build, its
//                   serialization, and the patch's delivery (patch-apply
//                   within)
//   patch-apply     the patch onto the host's retained tree (WasmViewModel)
//   swiftui-commit  from the new tree to the end of the Core Animation
//                   commit that carries it (a run-loop observer after CA's)
//   echo            a field's value from the change to the guest's echo of
//                   it reaching the field (EchoedText)
//   tree-delivered  (an event) a patch handed out by the guest, its size
//
// Their messages number what they carry, so a keystroke can be followed
// through: "input=N" (IsomerTree's EchoedText, which also signposts the
// local-commit and ack-commit of edits and how each echo ended), "event=N"
// for each event a runtime sends, "events=a-b" for the events a pumped
// frame is the first to render, "frame=N" for each patch the guest hands
// out and the host applies, and "commit=N frames=a-b" for the commit that
// draws them ("commit=N" also ends local-commit and ack-commit: one number
// for a run-loop pass's Core Animation commit).

#if canImport(os)
import os

public enum IsomerTypingSignposts {
    public static let log = OSLog(subsystem: "dev.isomer.typing", category: "Typing")

    /// `body` inside an interval named `name`.
    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try body()
    }

    /// Begins an interval to be ended elsewhere (`end`).
    public static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    public static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    /// Begins an interval whose message is `key=a` (or `key=a-b`).
    public static func begin(_ name: StaticString, _ key: StaticString, _ a: Int, _ b: Int? = nil) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        if let b {
            os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}s=%{public}d-%{public}d",
                        String(describing: key), a, b)
        } else {
            os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}s=%{public}d", String(describing: key), a)
        }
        return id
    }

    /// A point event whose message is `key=a` and `bytes=b`.
    public static func event(_ name: StaticString, _ key: StaticString, _ a: Int, bytes: Int) {
        os_signpost(.event, log: log, name: name, "%{public}s=%{public}d bytes=%{public}d",
                    String(describing: key), a, bytes)
    }
}
#else
/// No os_signpost off Apple: the signposts are no-ops.
public enum IsomerTypingSignposts {
    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { try body() }
    @inline(__always)
    public static func event(_ name: StaticString, _ key: StaticString, _ a: Int, bytes: Int) {}
}
#endif
