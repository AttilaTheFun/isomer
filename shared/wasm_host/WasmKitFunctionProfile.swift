// A profile of a runtime module's functions under WasmKit's interpreter: how
// many times each was called and the time spent in it but not in what it
// called (self time), by its index in the module. Mixed mode's native set is
// chosen from such profiles of a corpus (tools/wasm_mixed_corpus;
// docs/side_modules.md). Give one to `WasmKitRuntime.profile` before
// `launch`; the interpreter then reports each call (slower: a profile is for
// the counts and the time's shares).
//
// Functions of other instances (a side module's) are counted together as
// `other`; time in host functions counts as their wasm caller's.

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
@_spi(OnlyForCLI) import WasmKit

public final class WasmKitFunctionProfile: EngineInterceptor {
    private var indexOf: [Reference: Int] = [:]
    public private(set) var calls: [Int] = []
    public private(set) var selfNanos: [UInt64] = []
    public private(set) var otherCalls = 0
    public private(set) var otherNanos: UInt64 = 0

    // The interpreter's stack: each frame's function (-1: other), when it
    // began, and the time its callees took.
    private var stackIndex: [Int] = []
    private var stackStart: [UInt64] = []
    private var stackChildren: [UInt64] = []

    public init() {}

    /// The runtime module's instance, whose functions are counted.
    func attach(_ instance: Instance) {
        var index = 0
        while let function = instance.function(at: index) {
            indexOf[function.reference] = index
            index += 1
        }
        calls = Array(repeating: 0, count: index)
        selfNanos = Array(repeating: 0, count: index)
    }

    @inline(__always) private static func now() -> UInt64 {
        #if canImport(Darwin)
            clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
            var t = timespec()
            clock_gettime(CLOCK_MONOTONIC, &t)
            return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
        #endif
    }

    public func onEnterFunction(_ function: Function) {
        stackIndex.append(indexOf[function.reference] ?? -1)
        stackChildren.append(0)
        stackStart.append(Self.now())
    }

    public func onExitFunction(_ function: Function) {
        let end = Self.now()
        guard let index = stackIndex.popLast(), let start = stackStart.popLast(),
              let children = stackChildren.popLast() else { return }
        let elapsed = end &- start
        let own = elapsed > children ? elapsed - children : 0
        if index >= 0 {
            calls[index] += 1
            selfNanos[index] += own
        } else {
            otherCalls += 1
            otherNanos += own
        }
        if !stackChildren.isEmpty { stackChildren[stackChildren.count - 1] += elapsed }
    }

    /// `<index> <calls> <self ns>` a line for each runtime function called,
    /// then `other <calls> <self ns>`.
    public func report() -> String {
        var lines: [String] = []
        for index in 0..<calls.count where calls[index] > 0 {
            lines.append("\(index) \(calls[index]) \(selfNanos[index])")
        }
        lines.append("other \(otherCalls) \(otherNanos)")
        return lines.joined(separator: "\n") + "\n"
    }
}
