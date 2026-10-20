// XIP smoke: run a `wamrc --xip` AOT image IN PLACE from a READ-ONLY mapping
// (the shape of an image embedded in a signed iOS __TEXT segment). Catches
// any loader write into the image (SIGBUS here == signal 10 on device) and
// asserts the reactor renders. Usage: iso_wamr_xip_smoke <file.aot>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "iso_wamr.h"

static int g_got_tree = 0;

static void on_tree(void *ctx, const uint8_t *bytes, size_t len) {
    (void)ctx; (void)bytes;
    if (len > 0) g_got_tree = 1;
}

static void on_log(void *ctx, const char *msg, size_t len) {
    (void)ctx;
    fprintf(stderr, "[guest] %.*s\n", (int)len, msg);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file.aot>\n", argv[0]); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 2; }
    struct stat st;
    fstat(fd, &st);
    // PROT_READ only: macOS (like iOS) refuses exec mappings of unsigned
    // files, but write-detection is the point — any loader write into the
    // image SIGBUSes here exactly as it does on device. Pass a second arg to
    // also RUN the reactor (requires a writable copy, losing write-detection).
    int run = argc > 2;
    void *map;
    if (run) {
        map = malloc((size_t)st.st_size);
        FILE *f = fdopen(fd, "rb");
        if (fread(map, 1, (size_t)st.st_size, f) != (size_t)st.st_size) return 2;
    } else {
        map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map == MAP_FAILED) { perror("mmap"); return 2; }
    }

    IsoWamrCallbacks cb = {0};
    cb.on_tree = on_tree;
    cb.on_log = on_log;

    char err[256] = {0};
    IsoWamr *rt = iso_wamr_create_in_place((const uint8_t *)map,
                                           (size_t)st.st_size, cb, err, sizeof(err));
    if (!rt) { fprintf(stderr, "create_in_place failed: %s\n", err); return 1; }
    if (run) {
        iso_wamr_start(rt, 390, 844);
        if (!g_got_tree) { fprintf(stderr, "no tree rendered\n"); return 1; }
        fprintf(stderr, "XIP OK: tree rendered\n");
    } else {
        fprintf(stderr, "XIP load OK: no writes into the read-only image\n");
    }
    iso_wamr_destroy(rt);
    return 0;
}
