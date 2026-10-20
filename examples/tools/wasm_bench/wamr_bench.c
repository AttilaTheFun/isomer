// Console benchmark: run the tap-counter reactor under WAMR (interp or AOT,
// decided by the artifact's magic bytes) through the shared C host
// (//shared/wamr_host) and print startup / tap timings:
//
//   wamr_bench <reactor.wasm|reactor.aot> [taps]

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "iso_wamr.h"

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static uint8_t g_tree[1 << 20];
static size_t g_tree_len = 0;

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

static int tree_contains(const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || g_tree_len < n) return 0;
    for (size_t i = 0; i + n <= g_tree_len; i++) {
        if (memcmp(g_tree + i, needle, n) == 0) return 1;
    }
    return 0;
}

static int find_tap_id(char *out, size_t out_len) {
    for (size_t i = 0; i + 4 <= g_tree_len; i++) {
        if (memcmp(g_tree + i, ".tap", 4) != 0) continue;
        size_t start = i;
        while (start > 0) {
            uint8_t c = g_tree[start - 1];
            if ((c >= '0' && c <= '9') || c == '.' || (c >= 'a' && c <= 'z')) start--;
            else break;
        }
        while (start < i && g_tree[start] == '.') start++;
        size_t len = i + 4 - start;
        if (start < i && len < out_len) {
            memcpy(out, g_tree + start, len);
            out[len] = 0;
            return 1;
        }
    }
    return 0;
}

static IsoWamr *g_rt;

static int32_t call_i32(const char *name, const IsoWamrValue *args, size_t nargs) {
    IsoWamrValue out;
    if (!iso_wamr_call(g_rt, name, args, nargs, &out)) return -1;
    return out.v.i32;
}

static void call_void(const char *name, const IsoWamrValue *args, size_t nargs) {
    iso_wamr_call(g_rt, name, args, nargs, NULL);
}

static void send_event(const char *id, const char *value) {
    IsoWamrValue a = { .is_f64 = 0, .v.i32 = (int32_t)strlen(id) };
    int32_t id_ptr = call_i32("iso_hot_alloc", &a, 1);
    IsoWamrValue b = { .is_f64 = 0, .v.i32 = (int32_t)strlen(value) };
    int32_t val_ptr = call_i32("iso_hot_alloc", &b, 1);
    iso_wamr_write_bytes(g_rt, (uint32_t)id_ptr, (const uint8_t *)id, (uint32_t)strlen(id));
    if (strlen(value))
        iso_wamr_write_bytes(g_rt, (uint32_t)val_ptr, (const uint8_t *)value, (uint32_t)strlen(value));
    IsoWamrValue ev[4] = {
        { .is_f64 = 0, .v.i32 = id_ptr },
        { .is_f64 = 0, .v.i32 = (int32_t)strlen(id) },
        { .is_f64 = 0, .v.i32 = val_ptr },
        { .is_f64 = 0, .v.i32 = (int32_t)strlen(value) },
    };
    call_void("iso_hot_event", ev, 4);
    IsoWamrValue f1 = { .is_f64 = 0, .v.i32 = id_ptr };
    call_void("iso_hot_free", &f1, 1);
    IsoWamrValue f2 = { .is_f64 = 0, .v.i32 = val_ptr };
    call_void("iso_hot_free", &f2, 1);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: wamr_bench <reactor.wasm|.aot> [taps]\n");
        return 2;
    }
    const char *path = argv[1];
    int taps = argc > 2 ? atoi(argv[2]) : 20;
    int is_aot = strstr(path, ".aot") != NULL;

    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "FAIL open %s\n", path); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *bytes = malloc((size_t)size);
    fread(bytes, 1, (size_t)size, f);
    fclose(f);

    IsoWamrCallbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.on_tree = on_tree;
    cb.on_log = on_log;

    char err[256] = {0};
    double t0 = now_ms();
    g_rt = iso_wamr_create(bytes, (size_t)size, cb, err, sizeof(err));
    if (!g_rt) { fprintf(stderr, "FAIL create: %s\n", err); return 1; }

    IsoWamrValue start_args[2] = {
        { .is_f64 = 1, .v.f64 = 390 },
        { .is_f64 = 1, .v.f64 = 680 },
    };
    call_void("iso_hot_start", start_args, 2);
    call_void("iso_hot_render", NULL, 0);
    double startup_ms = now_ms() - t0;

    if (!tree_contains("Tap me")) {
        fprintf(stderr, "FAIL: first frame lacks the counter (tree %zu bytes)\n", g_tree_len);
        return 1;
    }
    char tap_id[128];
    if (!find_tap_id(tap_id, sizeof(tap_id))) {
        fprintf(stderr, "FAIL: no tap id\n");
        return 1;
    }

    double *samples = calloc((size_t)taps, sizeof(double));
    for (int i = 0; i < taps; i++) {
        g_tree_len = 0;
        double t = now_ms();
        send_event(tap_id, "");
        call_void("iso_hot_render", NULL, 0);
        samples[i] = now_ms() - t;
        if (!tree_contains("Tapped")) {
            fprintf(stderr, "FAIL: tap %d produced no update\n", i);
            return 1;
        }
    }
    qsort(samples, (size_t)taps, sizeof(double), cmp_double);
    double mean = 0;
    for (int i = 0; i < taps; i++) mean += samples[i];
    mean /= taps;

    printf("RESULT engine=wamr artifact=%s size_mb=%.1f startup_ms=%.0f tap_med_ms=%.2f tap_mean_ms=%.2f taps=%d\n",
           is_aot ? "aot" : "wasm", (double)size / 1e6, startup_ms,
           samples[taps / 2], mean, taps);
    return 0;
}
