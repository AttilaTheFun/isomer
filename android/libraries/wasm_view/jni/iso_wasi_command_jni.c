// JNI for dev.isomer.runtime.WasiCommand: runs a WASI command module (a
// compiler, a linker) under the same WAMR the reactors run in
// (//tools/wasm/wasi_command). The module is read from a file; its stdout and
// stderr go to another, which Kotlin reads back as the program's output.
#include <fcntl.h>
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "tools/wasm/wasi_command/wasi_command.h"

static const char **strings(JNIEnv *env, jobjectArray array, int *count) {
    int n = array ? (*env)->GetArrayLength(env, array) : 0;
    const char **out = calloc((size_t)n + 1, sizeof(char *));
    for (int i = 0; i < n; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
        out[i] = strdup(utf ? utf : "");
        (*env)->ReleaseStringUTFChars(env, s, utf);
        (*env)->DeleteLocalRef(env, s);
    }
    *count = n;
    return out;
}

static void free_strings(const char **list, int count) {
    for (int i = 0; i < count; i++) free((void *)list[i]);
    free(list);
}

static uint8_t *read_file(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }
    uint8_t *bytes = malloc((size_t)st.st_size);
    size_t got = 0;
    while (bytes && got < (size_t)st.st_size) {
        ssize_t n = read(fd, bytes + got, (size_t)st.st_size - got);
        if (n <= 0) { free(bytes); bytes = NULL; break; }
        got += (size_t)n;
    }
    close(fd);
    *len = (size_t)st.st_size;
    return bytes;
}

// The exit code, or -1 with the runtime's error appended to the output file.
JNIEXPORT jint JNICALL Java_dev_isomer_runtime_WasiCommand_nativeRun(
    JNIEnv *env, jclass cls, jstring module_path, jobjectArray argv, jobjectArray dirs,
    jobjectArray envs, jstring output_path) {
    (void)cls;
    const char *module_utf = (*env)->GetStringUTFChars(env, module_path, NULL);
    size_t module_len = 0;
    uint8_t *module = read_file(module_utf, &module_len);
    (*env)->ReleaseStringUTFChars(env, module_path, module_utf);
    const char *output_utf = (*env)->GetStringUTFChars(env, output_path, NULL);
    int out = open(output_utf, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    (*env)->ReleaseStringUTFChars(env, output_path, output_utf);
    if (!module || out < 0) {
        if (out >= 0) { dprintf(out, "cannot read the module\n"); close(out); }
        free(module);
        return -1;
    }
    int argc = 0, dir_count = 0, env_count = 0;
    const char **args = strings(env, argv, &argc);
    const char **dir_list = strings(env, dirs, &dir_count);
    const char **env_list = strings(env, envs, &env_count);
    WasiCommandOptions options = {
        .argv = args, .argc = argc,
        .dirs = dir_list, .dir_count = dir_count,
        .envs = env_list, .env_count = env_count,
        .stdout_fd = out, .stderr_fd = out, .stack_size = 0,
    };
    char err[256] = {0};
    int code = wasi_command_run(module, module_len, &options, err, sizeof(err));
    if (code < 0) dprintf(out, "%s\n", err);
    close(out);
    free_strings(args, argc);
    free_strings(dir_list, dir_count);
    free_strings(env_list, env_count);
    free(module);
    return code;
}
