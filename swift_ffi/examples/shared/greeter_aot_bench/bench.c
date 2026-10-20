// AOT-vs-interp cold-start benchmark for the WAMR "wasm mode" path.
//
// Loads a reactor file (a .wasm run under the fast interpreter, or a
// wamrc-produced .aot run as native code) from scratch each iteration and times
// the whole load + instantiate + exercise cycle via run_greeter_reactor. The
// .aot skips the interpreter's per-load bytecode preprocessing and runs native,
// so this is where AOT pays off. Pass the same driver two files to compare.
//
//   greeter_aot_bench <reactor-path> [iters]   (default 30 iters)

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "run.h"

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <reactor-path> [iters]\n", argv[0]);
        return 2;
    }
    int iters = argc > 2 ? atoi(argv[2]) : 30;

    // One warm-up load to fault in the file/code pages before timing.
    if (run_greeter_reactor(argv[0], argv[1]) != 0) {
        fprintf(stderr, "[bench] warm-up load failed for %s\n", argv[1]);
        return 1;
    }

    double best = 1e18, total = 0.0;
    for (int i = 0; i < iters; i++) {
        double a = now_ms();
        int rc = run_greeter_reactor(argv[0], argv[1]);
        double d = now_ms() - a;
        if (rc != 0) {
            fprintf(stderr, "[bench] reactor failed rc=%d\n", rc);
            return rc;
        }
        if (d < best) best = d;
        total += d;
    }
    fprintf(stderr, "[bench] %s\n         best %.3f ms | avg %.3f ms | %d iters\n",
            argv[1], best, total / iters, iters);
    return 0;
}
