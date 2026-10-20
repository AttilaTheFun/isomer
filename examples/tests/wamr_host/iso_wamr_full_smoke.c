// Host smoke for the FULL example app as a iso_hot wasm reactor under WAMR.
// The whole multi-tab `@main App` (//examples/shared/example_application) is the "full x
// wasm" Android matrix cell; this proves it instantiates and emits a render
// tree on the host before it's wired into the APK. (Its networking is
// Foundation's URLSession over the host's injected HTTP host: the Swift
// wasm_engines test drives that through this same C host.)
//
//   argv[1] = path to example_full.wasm
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iso_wamr.h"


static unsigned char g_tree[1 << 18];
static size_t g_tree_len = 0;

// Patches are the only wire format: the first on_tree buffer is a full-tree
// op and later ones are deltas, so the capture CONCATENATES the stream and
// the assertions search all of it (overwriting with the last buffer would
// leave only a tiny idle patch).
static void on_tree(void *ctx, const uint8_t *bytes, size_t len) {
    (void)ctx;
    if (g_tree_len + len <= sizeof(g_tree)) {
        memcpy(g_tree + g_tree_len, bytes, len);
        g_tree_len += len;
    }
}

static void on_log(void *ctx, const char *msg, size_t len) {
    (void)ctx;
    fprintf(stderr, "[wasm] %.*s\n", (int)len, msg);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <example_full.wasm>\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *wasm = malloc(n);
    if (fread(wasm, 1, n, f) != (size_t)n) {
        fprintf(stderr, "short read\n");
        return 2;
    }
    fclose(f);

    IsoWamrCallbacks cb = {0};
    cb.on_tree = on_tree;
    cb.on_log = on_log;
    // The swift_ffi transport, with nothing injected: the runtime still asks
    // the dependency dictionary (for the network hosts) at start.
    cb.ffi_prefix = "swift_ffi_";

    char err[256] = {0};
    IsoWamr *rt = iso_wamr_create(wasm, (size_t)n, cb, err, sizeof(err));
    free(wasm);
    if (!rt) {
        fprintf(stderr, "create failed: %s\n", err);
        return 1;
    }

    iso_wamr_start(rt, 900.0, 680.0);

    int ok = g_tree_len > 100;
    fprintf(stderr, "tree is %zu bytes\n", g_tree_len);

    iso_wamr_run_jobs(rt);
    iso_wamr_render(rt);
    if (!ok) {
        fprintf(stderr, "FAIL: the full app rendered no tree\n");
        iso_wamr_destroy(rt);
        return 1;
    }
    fprintf(stderr, "OK: WAMR ran the FULL example app\n");
    iso_wamr_destroy(rt);
    return 0;
}
