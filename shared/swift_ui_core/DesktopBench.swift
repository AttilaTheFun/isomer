// The desktop (Windows/Linux) self-driving benchmark harness — the peer of the
// iOS cells' `-bench` accessibility harness and Android's ContentFrame helper.
// Desktop cells draw every pixel themselves (SwiftGPU), so no external
// accessibility/automation harness can see the content; instead the host loop
// drives the benchmark from the inside, through the same code paths real input
// takes (see docs/benchmarks.md#windows / #linux):
//
//   [iso-content-frame] <epoch_ms>   logged after the first presented frame
//   [iso-tap] <ms>                   per tap: pointer dispatch -> the present
//                                    of the frame reflecting the new state
//   [iso-tap-summary] med=… mean=…   then the process exits
//
// Activated by ISO_BENCH=1 (inert otherwise — `shared` is nil and the two
// hooks are no-ops). The host loops call `tick()` once per loop iteration
// (dispatches the next tap when due) and `framePresented()` after each frame
// that actually rendered + presented (closes the open tap measurement).
//
// Taps are dispatched at the window-center button position of the shared
// TapCounter.swift layout (label + 24px gap + button, centered) through
// `Runtime.pointerEvent` — the exact entry the platform mouse callback uses,
// so hit-testing, press feedback, and state updates all run the production
// path; only the hardware hop is skipped.

#if os(Windows) || canImport(Glibc)

#if os(Windows)
import ucrt
import WinSDK
#else
import Glibc
#endif

public final class DesktopBench {
    /// Non-nil only when the process runs with ISO_BENCH=1.
    public static let shared: DesktopBench? = {
        guard let raw = getenv("ISO_BENCH"), raw.pointee == CChar(UInt8(ascii: "1"))
        else { return nil }
        return DesktopBench()
    }()

    private let tapTarget = 15
    private var contentLogged = false
    private var taps: [Double] = []
    /// Dispatch time of the tap whose presenting frame we're waiting for.
    private var openTapT0: Double?
    private var nextTapAt: Double = .infinity

    /// Wall-clock epoch milliseconds (comparable across processes — the driver
    /// timestamps the spawn and subtracts).
    public static func epochMillis() -> Double {
        #if os(Windows)
        var ft = FILETIME()
        GetSystemTimePreciseAsFileTime(&ft)
        let ticks = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
        // FILETIME epoch (1601) -> Unix epoch (1970), 100ns ticks -> ms.
        return Double(ticks - 116_444_736_000_000_000) / 10_000.0
        #else
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) * 1_000.0 + Double(ts.tv_nsec) / 1_000_000.0
        #endif
    }

    /// Once per host-loop iteration: dispatches the next tap when due. Kept
    /// separate from `framePresented` because an idle loop (Linux) presents no
    /// frames between taps.
    public func tick() {
        guard contentLogged, openTapT0 == nil, taps.count < tapTarget else { return }
        let now = Self.epochMillis()
        guard now >= nextTapAt else { return }
        // The shared TapCounter layout, centered: 20px label + 24 gap + ~45px
        // button; the button's center sits ~26px below the window center.
        let x = Runtime.shared.width / 2
        let y = Runtime.shared.height / 2 + 26
        openTapT0 = Self.epochMillis()
        Runtime.shared.pointerEvent(kind: 0, x: x, y: y)  // down
        Runtime.shared.pointerEvent(kind: 1, x: x, y: y)  // up
    }

    /// After each frame that actually rendered and presented: the first one is
    /// the content frame; later ones close the open tap measurement (the first
    /// present after a tap IS the presenting frame — the desktop loops are
    /// synchronous, so the state change is already in it).
    public func framePresented() {
        let now = Self.epochMillis()
        if !contentLogged {
            contentLogged = true
            print("[iso-content-frame] \(now)")
            flushStdout()
            nextTapAt = now + 500  // settle before driving taps
            return
        }
        guard let t0 = openTapT0 else { return }
        let dt = now - t0
        openTapT0 = nil
        taps.append(dt)
        print("[iso-tap] \(dt)")
        flushStdout()
        nextTapAt = now + 150
        if taps.count >= tapTarget { summarizeAndExit() }
    }

    private func summarizeAndExit() {
        let sorted = taps.sorted()
        let mean = taps.reduce(0, +) / Double(taps.count)
        print("[iso-tap-summary] med=\(sorted[taps.count / 2]) mean=\(mean) n=\(taps.count)")
        flushStdout()
        exit(0)
    }

    private func flushStdout() {
        // fflush(NULL) flushes every open output stream (C99) — `stdout` itself
        // isn't importable through ucrt on Windows.
        fflush(nil)
    }
}

#endif
