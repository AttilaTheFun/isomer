// The iOS on-device benchmark harness, compiled into each tap-counter cell.
//
// Activated by `-bench` or ISO_BENCH=1 (devicectl forwards env vars via its
// DEVICECTL_CHILD_ prefix); dormant otherwise.
//
// METHODOLOGY (uniform across every cell and framework, all stamps taken by
// native code in-process — never by JS or wasm):
//
//   1. Startup: PROCESS INIT (sysctl kp_proc.p_starttime — the kernel's fork
//      stamp, dyld + pre-main included) → the end of the CA commit that first
//      contains the label + button — i.e. the first content frame is laid out
//      and HANDED OFF to the render server. Detected by the first body/build
//      tick (`noteBodyTick` / `noteContentBuilt`), stamped by a runloop
//      observer at order 2,500,000 — AFTER Core Animation's commit observer
//      (order 2,000,000) in the same before-waiting pass, so the commit
//      (including the layout pass it runs) has completed synchronously when
//      the stamp is taken.
//   2. Taps: 15 triggers (0.9 s + random jitter — a fixed cadence can
//      phase-lock to a framework's render tick) through [tapTrigger] — the
//      same state mutation a touch-up performs. Measured TRIGGER RECEIPT →
//      the end of the CA commit containing the update: views re-laid-out and
//      SUBMITTED for drawing, the point where it leaves the app's hands.
//      Explicitly NOT frame-timing-dependent: no CADisplayLink anchor, no
//      CATransaction completion (that waits on the render server's
//      frame-paced processing). A framework that internally defers its
//      update to a later runloop turn pays that deferral — it's part of its
//      pipeline — but nothing after the commit handoff is counted.
//   3. Writes Documents/bench.json — pulled with `xcrun devicectl device
//      copy from --domain-type appDataContainer`.

#if os(iOS)
import UIKit

@MainActor
public final class BenchHarness: NSObject {
    public static let shared = BenchHarness()

    /// The cell wires this to its tap-equivalent state mutation.
    public static var tapTrigger: (() -> Void)?

    /// Set from a UIApplicationDelegateAdaptor's didFinishLaunching (cells
    /// that own their @main): splits startup into process-start → launch
    /// (dyld + pre-main) vs launch → first content.
    public static var launchedAt: CFTimeInterval?

    /// Cells call this from their body/build evaluation
    /// (TapCounterBenchBridge / IsomerTreeBenchHook.bodyTick): the turn's
    /// commit contains the content (phase 0) or the tap's update (phase 1);
    /// the post-commit observer stamps at the end of that commit.
    /// The interaction signpost's universal end-signal hook: every cell
    /// already routes its update evaluation through noteBodyTick, and
    /// InteractionSignpost (compiled only into signpost-instrumented cells)
    /// installs itself here.
    nonisolated(unsafe) public static var onUpdateSignal: (() -> Void)?

    public static func noteBodyTick() {
        shared.onBodyTick()
        onUpdateSignal?()
    }

    /// Cells without a body hook (the hand-written UIKit baseline) call this
    /// once their content views exist; the first commit after it is the
    /// content frame.
    public static func noteContentBuilt() {
        shared.contentPending = true
    }

    private var contentPending = false
    private var updatePending = false

    private func onBodyTick() {
        switch phase {
        case 0: contentPending = true
        case 1: if tapStarted > 0 { updatePending = true }
        default: break
        }
    }

    private var observer: CFRunLoopObserver?
    private var startupMs: Double?
    private var launchToContentMs: Double?
    private var tapStarted: CFTimeInterval = 0
    private var taps: [Double] = []
    private let tapsWanted = 15
    private var phase = 0 // 0 waiting-for-content, 1 tapping, 2 done

    /// No-op without -bench / ISO_BENCH=1. Called from the boot constructor
    /// on the launch (= main) thread, BEFORE @main runs.
    public static func installIfRequested() {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("-bench") || info.environment["ISO_BENCH"] == "1" else { return }
        shared.start()
    }

    private func start() {
        // Order 2,500,000: after Core Animation's commit observer (2,000,000)
        // in the same before-waiting pass. CA commits synchronously inside its
        // observer — layout of dirty layers, encode, IPC to the render server
        // — so when this fires, the turn's frame has been handed off. The
        // observer always runs before the loop sleeps, so an early commit in
        // a turn can't be idle-delayed.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.afterCommit() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        // A fresh run must never be confused with a previous launch's file.
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("bench.json"))
        }
        NSLog("[bench] harness armed (post-commit anchors)")
    }

    private func afterCommit() {
        switch phase {
        case 0:
            guard contentPending else { return }
            contentPending = false
            startupMs = Self.msSinceProcessStart()
            if let launched = Self.launchedAt {
                launchToContentMs = (CACurrentMediaTime() - launched) * 1000
            }
            phase = 1
            NSLog("[bench] content commit sinceStart=%.0fms sinceLaunch=%.0fms",
                  startupMs ?? -1, launchToContentMs ?? -1)
            scheduleTap(after: 1.0) // settle before the tap train
        case 1:
            guard updatePending, tapStarted > 0 else { return }
            updatePending = false
            let ms = (CACurrentMediaTime() - tapStarted) * 1000
            taps.append(ms)
            NSLog("[bench] tap #%d %.2fms (to commit-handoff)", taps.count, ms)
            tapStarted = 0
            if taps.count >= tapsWanted {
                phase = 2
                finish()
            } else {
                scheduleTap(after: 0.25 + Double.random(in: 0...0.05))
            }
        default:
            break
        }
    }

    private func scheduleTap(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fireTap()
        }
    }

    private func fireTap() {
        guard phase == 1, tapStarted == 0 else { return }
        guard let trigger = Self.tapTrigger else {
            // Not wired yet (e.g. onAppear hasn't run) — retry shortly.
            scheduleTap(after: 0.5)
            return
        }
        tapStarted = CACurrentMediaTime()
        updatePending = false
        trigger()
        // Watchdog: a lost update must not stall the run — skip this tap.
        let token = tapStarted
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.tapStarted == token else { return }
            NSLog("[bench] tap timed out (no bodyTick/commit)")
            self.tapStarted = 0
            self.scheduleTap(after: 0.3)
        }
    }

    private func finish() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let sorted = taps.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let mean = taps.isEmpty ? 0 : taps.reduce(0, +) / Double(taps.count)
        let payload: [String: Any] = [
            "run": ProcessInfo.processInfo.environment["ISO_BENCH_RUN"] ?? "",
            "startupMs": startupMs ?? -1,
            "launchToContentMs": launchToContentMs ?? -1,
            "taps": taps.map { (($0 * 100).rounded()) / 100 },
            "tapMedianMs": ((median * 100).rounded()) / 100,
            "tapMeanMs": ((mean * 100).rounded()) / 100,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: dir.appendingPathComponent("bench.json"))
            NSLog("[bench] done: %@", String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Process init (the kernel's fork stamp: dyld + pre-main included)

    private static func msSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startSec = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        // Foundation's Date explicitly: in cells whose module carries the
        // reimplementation core, a bare `Date` resolves to its calendar shim.
        return (Foundation.Date().timeIntervalSince1970 - startSec) * 1000
    }
}
#endif

/// C-visible entry so the `:boot` constructor can install the harness into
/// ANY cell — including the compiled one, whose `@main` lives in the shared
/// TapCounter.swift that must stay untouched for cross-platform fairness.
@_cdecl("iso_bench_install")
public func iso_bench_install() {
    #if os(iOS)
    // The boot constructor runs on the launch thread — the main thread — but
    // the C entry is nonisolated as far as the compiler knows.
    MainActor.assumeIsolated {
        BenchHarness.installIfRequested()
    }
    #endif
}
