// Injects the bench harness without touching any app source: a static
// constructor runs the install SYNCHRONOUSLY at load time (dyld runs
// initializers on the launch thread = the main thread), so the harness and
// its tap wiring exist BEFORE @main and the framework's first body/build
// evaluation — the phase-0 content signal (the first bodyTick) cannot be
// missed. Dormant without -bench / ISO_BENCH=1. `iso_bench_wire` is a WEAK
// reference resolved at static link: cells that define it (@_cdecl in their
// app sources) get their tap trigger wired; cells that don't simply skip it
// (dlsym can't be used — main executables don't export symbols).
extern void iso_bench_install(void);
extern void iso_bench_install_signpost(void) __attribute__((weak_import));
extern void iso_bench_wire(void) __attribute__((weak_import));

__attribute__((constructor)) static void iso_bench_boot(void) {
    if (iso_bench_wire) iso_bench_wire();
    iso_bench_install();
    // Signpost harness: present only in cells that link the SwiftUI tree
    // (all ISO cells). weak_import so the native-baseline cells skip it.
    if (iso_bench_install_signpost) iso_bench_install_signpost();
}
