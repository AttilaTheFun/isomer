// iwasm: runs a WASI command module from the shell (the Playground's compiler
// tried on a phone over adb, say).
//   iwasm [--dir=<path>]... [--map-dir=<guest>::<host>]... [--env=NAME=value]... <module.wasm|.aot> [args...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wasi_command.h"

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *bytes = malloc((size_t)n);
    if (bytes && fread(bytes, 1, (size_t)n, f) != (size_t)n) { free(bytes); bytes = NULL; }
    fclose(f);
    *len = (size_t)n;
    return bytes;
}

int main(int argc, const char **argv) {
    const char *dirs[64]; int dir_count = 0;
    const char *map_dirs[64]; int map_dir_count = 0;
    const char *envs[64]; int env_count = 0;
    int i = 1;
    for (; i < argc; i++) {
        if (strncmp(argv[i], "--dir=", 6) == 0 && dir_count < 64) dirs[dir_count++] = argv[i] + 6;
        else if (strncmp(argv[i], "--map-dir=", 10) == 0 && map_dir_count < 64) map_dirs[map_dir_count++] = argv[i] + 10;
        else if (strncmp(argv[i], "--env=", 6) == 0 && env_count < 64) envs[env_count++] = argv[i] + 6;
        else break;
    }
    if (i >= argc) { fprintf(stderr, "usage: iwasm [--dir=path]... [--map-dir=guest::host]... [--env=K=V]... module [args...]\n"); return 2; }
    size_t len = 0;
    uint8_t *module = read_file(argv[i], &len);
    if (!module) { fprintf(stderr, "iwasm: cannot read %s\n", argv[i]); return 2; }
    WasiCommandOptions options = {
        .argv = argv + i, .argc = argc - i,
        .dirs = dirs, .dir_count = dir_count,
        .map_dirs = map_dirs, .map_dir_count = map_dir_count,
        .envs = envs, .env_count = env_count,
        .stdout_fd = -1, .stderr_fd = -1, .stack_size = 0,
    };
    char err[256] = {0};
    int code = wasi_command_run(module, len, &options, err, sizeof(err));
    if (code < 0) fprintf(stderr, "iwasm: %s\n", err);
    free(module);
    return code < 0 ? 1 : code;
}
