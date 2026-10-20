// Host smoke test for iso_wamr: run the hot_demo reactor under WAMR (C) and
// assert it emits a render tree containing the demo greeting — the C peer of
// the Apple `hot_smoke` (WasmKit) check. Proves the WAMR Android engine runs a
// real SwiftWasm reactor with no Swift on the host side.
//
//   argv[1] = path to hot_demo.wasm
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iso_wamr.h"

#include "platform_services_c_host.h"

static unsigned char g_tree[1 << 16];
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

// Platform-services DI: answer promo_banner=true so the reactor renders the
// native-injected banner — proving the dictionary resolve + dispatch
// round-trips through the generic C host and the generated blob adapters.
static int32_t on_flag(void *ctx, const char *key) {
    (void)ctx;
    return key && strcmp(key, "promo_banner") == 0;
}
static void on_track(void *ctx, const char *event) {
    (void)ctx;
    (void)event;
}
static platformservices_ConfigurationService g_configuration = {NULL, on_flag};
static platformservices_AnalyticsService g_analytics = {NULL, on_track};

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <hot_demo.wasm>\n", argv[0]);
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
    cb.ffi_prefix = "swift_ffi_platform_services_";

    char err[256] = {0};
    IsoWamr *rt = iso_wamr_create(wasm, (size_t)n, cb, err, sizeof(err));
    free(wasm);
    if (!rt) {
        fprintf(stderr, "create failed: %s\n", err);
        return 1;
    }

    // The app-owned dependency table (before start, which activates it).
    SwiftFFIHostDependency deps[2];
    deps[0].key = "configuration";
    deps[0].registry_key = PLATFORMSERVICES_KEY_ConfigurationService;
    deps[0].register_symbol = PLATFORMSERVICES_REGISTER_ConfigurationService;
    deps[0].lazy = 1;
    deps[0].ctx = &g_configuration;
    deps[0].dispatch = platformservices__dispatch_ConfigurationService;
    deps[1].key = "analytics";
    deps[1].registry_key = PLATFORMSERVICES_KEY_AnalyticsService;
    deps[1].register_symbol = PLATFORMSERVICES_REGISTER_AnalyticsService;
    deps[1].lazy = 1;
    deps[1].ctx = &g_analytics;
    deps[1].dispatch = platformservices__dispatch_AnalyticsService;
    swift_ffi_host_set_dependencies(iso_wamr_ffi_host(rt), deps, 2);

    iso_wamr_start(rt, 900.0, 680.0);

    int greeting = g_tree_len > 0 &&
                   memmem(g_tree, g_tree_len, "Hot reload works.", 17) != NULL;
    // The banner only renders if ConfigurationService.flag("promo_banner") returned true
    // — i.e. install + foreign dispatch through the swift_ffi C host worked.
    int banner = memmem(g_tree, g_tree_len, "Promo from native host", 22) != NULL;
    fprintf(stderr, "tree is %zu bytes; greeting: %s; DI banner: %s\n", g_tree_len,
            greeting ? "YES" : "no", banner ? "YES" : "no");
    iso_wamr_destroy(rt);

    if (!greeting) {
        fprintf(stderr, "FAIL: tree did not contain the demo greeting\n");
        return 1;
    }
    if (!banner) {
        fprintf(stderr, "FAIL: platform-services DI banner missing (install/flag dispatch broke)\n");
        return 1;
    }
    fprintf(stderr, "OK: WAMR ran the reactor, emitted the tree, and platform-services DI round-tripped\n");
    return 0;
}
