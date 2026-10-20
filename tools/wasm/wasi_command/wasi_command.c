#include "wasi_command.h"

#include <stdio.h>
#include <string.h>

#include "wasm_export.h"

static void fail(char *err, size_t err_len, const char *what) {
    if (err && err_len) { strncpy(err, what, err_len - 1); err[err_len - 1] = 0; }
}

int wasi_command_run(const uint8_t *module_bytes, size_t module_len,
                     const WasiCommandOptions *options, char *err, size_t err_len) {
    // The runtime is process-global. Initialising it again after a reactor host
    // (the WasmView) has is a no-op in WAMR (it counts references), so a command
    // and a running app coexist.
    RuntimeInitArgs init;
    memset(&init, 0, sizeof(init));
    init.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init)) { fail(err, err_len, "wasm_runtime_full_init failed"); return -1; }

    int code = -1;
    char werr[256] = {0};
    // WAMR keeps a reference to the bytes for the module's lifetime (an AOT
    // module maps its code from them), so they stay alive until unload.
    wasm_module_t module = wasm_runtime_load((uint8_t *)module_bytes, (uint32_t)module_len, werr, sizeof(werr));
    if (!module) { fail(err, err_len, werr[0] ? werr : "module load failed"); goto done; }

    wasm_runtime_set_wasi_args_ex(module,
                                  options->dirs, (uint32_t)options->dir_count,
                                  options->map_dirs, (uint32_t)options->map_dir_count,
                                  options->envs, (uint32_t)options->env_count,
                                  (char **)options->argv, options->argc,
                                  -1, options->stdout_fd, options->stderr_fd);

    uint32_t stack = options->stack_size ? options->stack_size : 16 * 1024 * 1024;
    // No app heap: a WASI command brings its own allocator and grows memory.
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, stack, 0, werr, sizeof(werr));
    if (!inst) { fail(err, err_len, werr[0] ? werr : "instantiate failed"); goto unload; }

    if (wasm_application_execute_main(inst, options->argc, (char **)options->argv)) {
        code = (int)wasm_runtime_get_wasi_exit_code(inst);
    } else {
        const char *exception = wasm_runtime_get_exception(inst);
        // proc_exit(n) surfaces as an exception; the exit code is still there.
        if (exception && strstr(exception, "wasi proc exit")) {
            code = (int)wasm_runtime_get_wasi_exit_code(inst);
        } else {
            fail(err, err_len, exception ? exception : "the module trapped");
        }
    }
    wasm_runtime_deinstantiate(inst);
unload:
    wasm_runtime_unload(module);
done:
    wasm_runtime_destroy();
    return code;
}
