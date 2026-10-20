// Shared "wasm mode" driver — see run.h. Runs the greeter reactor under
// swift_ffi's WAMR engine (//swift_ffi/runtime/c_host_wamr), driving it through
// the generated c-host bindings (greeter_c_host.h) with no compiled Swift on the
// host. The Linux and Windows wasm cells are a thin `main` over this.
#include "run.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "greeter_c_host.h"
#include "swift_ffi_wamr.h"

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)n ? (size_t)n : 1);
    if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    if (buf) *out_len = (size_t)n;
    return buf;
}

static char *dup_str(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static char *concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *p = (char *)malloc(la + lb + 1);
    if (!p) return NULL;
    memcpy(p, a, la);
    memcpy(p + la, b, lb + 1);
    return p;
}

static int file_readable(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

// If `path` names a readable file, adopt it (freeing it on failure); else free
// it and return NULL. Lets each candidate be a one-liner.
static char *adopt_if_readable(char *path) {
    if (path && file_readable(path)) return path;
    free(path);
    return NULL;
}

// Look up a runfiles rootpath in a Bazel MANIFEST (a "<runfiles-path> <real-path>"
// map): match the line whose key equals the rootpath or ends with "/" + it, and
// return the real path after the first space. Caller frees.
static char *lookup_manifest(const char *manifest, const char *path) {
    size_t mlen = 0;
    uint8_t *raw = read_file(manifest, &mlen);
    if (!raw) return NULL;
    uint8_t *grown = (uint8_t *)realloc(raw, mlen + 1);
    if (!grown) {
        free(raw);
        return NULL;
    }
    grown[mlen] = '\0';

    char *result = NULL;
    size_t plen = strlen(path);
    for (char *line = strtok((char *)grown, "\r\n"); line; line = strtok(NULL, "\r\n")) {
        char *space = strchr(line, ' ');
        if (!space) continue;
        size_t klen = (size_t)(space - line);
        int match = (klen == plen && strncmp(line, path, plen) == 0);
        if (!match && klen > plen && line[klen - plen - 1] == '/' &&
            strncmp(line + klen - plen, path, plen) == 0) {
            match = 1;
        }
        if (match) {
            result = dup_str(space + 1);
            break;
        }
    }
    free(grown);
    return result;
}

// Resolve a Bazel rootpath (e.g. "examples/.../greeter_reactor.wasm") to a real
// filesystem path. Under `bazel run`, Linux lays out a runfiles tree so the
// rootpath opens directly; Windows ships a MANIFEST (and a tree keyed under
// `_main/`) but doesn't set the manifest env var, so also derive locations from
// argv[0]. Returns a fresh string (caller frees) or NULL. Mirrors
// WindowsWasmApp's bundled-reactor lookup.
static char *resolve_runfile(const char *argv0, const char *path) {
    if (file_readable(path)) return dup_str(path);

    // Runfiles tree: $RUNFILES_DIR/_main/<path>, or <argv0>.runfiles/_main/<path>.
    const char *runfiles_dir = getenv("RUNFILES_DIR");
    char *found = NULL;
    if (runfiles_dir) {
        char *base = concat(runfiles_dir, "/_main/");
        if (base) found = adopt_if_readable(concat(base, path));
        free(base);
    }
    if (!found && argv0) {
        char *base = concat(argv0, ".runfiles/_main/");
        if (base) found = adopt_if_readable(concat(base, path));
        free(base);
    }
    if (found) return found;

    // Runfiles MANIFEST: $RUNFILES_MANIFEST_FILE, then argv[0]-derived names.
    const char *env_manifest = getenv("RUNFILES_MANIFEST_FILE");
    if (env_manifest) {
        char *hit = lookup_manifest(env_manifest, path);
        if (hit) return hit;
    }
    if (argv0) {
        const char *suffixes[] = {".runfiles/MANIFEST", ".runfiles_manifest"};
        for (int i = 0; i < 2; i++) {
            char *manifest = concat(argv0, suffixes[i]);
            if (manifest && file_readable(manifest)) {
                char *hit = lookup_manifest(manifest, path);
                free(manifest);
                if (hit) return hit;
            } else {
                free(manifest);
            }
        }
    }
    return NULL;
}

int run_greeter_reactor(const char *argv0, const char *wasm_path) {
    char *resolved = resolve_runfile(argv0, wasm_path);
    size_t wasm_len = 0;
    uint8_t *wasm = read_file(resolved ? resolved : wasm_path, &wasm_len);
    free(resolved);
    if (!wasm) {
        fprintf(stderr, "cannot read reactor at %s\n", wasm_path);
        return 2;
    }

    // Stand up the WAMR engine over the reactor, then the generated c-host
    // facade on top of it. No compiled Swift anywhere in this process.
    SwiftFFIWamr *rt = swift_ffi_wamr_new(wasm, wasm_len);
    free(wasm);
    if (!rt) {
        fprintf(stderr, "swift_ffi_wamr_new failed\n");
        return 1;
    }

    greeter_host *h =
        greeter_host_create(swift_ffi_wamr_engine(rt));
    if (!h) {
        fprintf(stderr, "host_create failed\n");
        swift_ffi_wamr_destroy(rt);
        return 1;
    }

    // Bind the reactor's FIXED `swift_ffi` import set (closure_invoke /
    // dependency_get / foreign_release / task_enqueue / task_enqueue_after /
    // async_complete — every reactor declares exactly these six) and
    // instantiate (this runs the
    // reactor's `_initialize`).
    const SwiftFFIHostImport *imports = NULL;
    size_t import_count = greeter_host_imports(h, &imports);
    swift_ffi_wamr_bind_imports(rt, imports, import_count);

    char err[256] = {0};
    if (!swift_ffi_wamr_instantiate(rt, err, sizeof err)) {
        fprintf(stderr, "instantiate failed: %s\n", err);
        greeter_host_destroy(h);
        swift_ffi_wamr_destroy(rt);
        return 1;
    }

    // Exercise the c-host-representable greeter surface: String in/out, scalars,
    // Bool, and a [UInt8] argument — every value crossing into the reactor and
    // back with no Swift on the host.
    int failures = 0;

    char *hello = greeter_greeting(h, "wasm");
    printf("greeting(\"wasm\")        = %s\n", hello ? hello : "(null)");
    if (!hello || strcmp(hello, "Hello from Swift, wasm!") != 0) failures++;
    free(hello);

    int32_t sum = greeter_add(h, 2, 40);
    printf("add(2, 40)              = %d\n", sum);
    if (sum != 42) failures++;

    int32_t even = greeter_isEven(h, 7);
    printf("isEven(7)               = %s\n", even ? "true" : "false");
    if (even != 0) failures++;

    // checksum reduces (acc + byte) % 251: 1,2,3,4,250 -> 9.
    const uint8_t data[] = {1, 2, 3, 4, 250};
    int32_t sumbytes = greeter_checksum(h, data, sizeof data);
    printf("checksum([1,2,3,4,250]) = %d\n", sumbytes);
    if (sumbytes != 9) failures++;

    greeter_host_destroy(h);
    swift_ffi_wamr_destroy(rt);

    if (failures) {
        fprintf(stderr, "FAIL: %d greeter call(s) returned unexpected values\n", failures);
        return 1;
    }
    printf("OK: the greeter reactor ran under WAMR with no compiled Swift.\n");
    return 0;
}
