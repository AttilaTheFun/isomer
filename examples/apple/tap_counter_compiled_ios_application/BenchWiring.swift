// Bench wiring for the compiled cell (found via dlsym by BenchHarness): the
// tap trigger is the shared TapCounterBenchBridge closure — the same state
// mutation a touch-up performs, without touching the shared app source.
@_cdecl("iso_bench_wire")
public func iso_bench_wire() {
    // Called from the boot constructor on the launch (= main) thread, before
    // @main — the wiring exists before the first body evaluation.
    MainActor.assumeIsolated {
        BenchHarness.tapTrigger = { TapCounterBenchBridge.increment?() }
        TapCounterBenchBridge.bodyTick = { BenchHarness.noteBodyTick() }
        TapCounterBenchBridge.onTap = { InteractionSignpost.tapReceived() }
    }
}
