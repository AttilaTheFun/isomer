// Runs a WASI command module (one with `_start`: a compiler, a linker) under
// WAMR, the way `iwasm` would: its arguments, environment, the host
// directories it may open, and where its stdout and stderr go. What
// the Playground's compile is on Android (the browser's swift-frontend.wasm and
// wasm-ld.wasm, ahead-of-time compiled for the phone), and `iwasm` below.
#ifndef ISO_WASI_COMMAND_H
#define ISO_WASI_COMMAND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char **argv;       // argv[0] is the program's name
    int argc;
    const char **dirs;       // host directories preopened at the same paths
    int dir_count;
    // Guest paths over host directories, "guest::host" (WAMR's map dirs).
    const char **map_dirs;
    int map_dir_count;
    const char **envs;       // "NAME=value"
    int env_count;
    int stdout_fd;           // -1 for the process's own
    int stderr_fd;
    uint32_t stack_size;     // 0: 16 MiB
} WasiCommandOptions;

// The module's exit code (0 on a clean return from `_start`), or -1 when it
// could not be loaded, instantiated or run — `err` says why. The module bytes
// may be a .wasm or (when the runtime has the AOT loader) a wamrc .aot.
int wasi_command_run(const uint8_t *module, size_t module_len,
                     const WasiCommandOptions *options, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
#endif
