#include "identity.h"

#if defined(_REENTRANT)
// Declared here, not through <pthread.h>: that reaches <stddef.h> in the
// compiler's builtin headers, which the wasm cc toolchain does not
// allow-list (before tools/patches/rules_swift_wasm_clang_resource_dir.patch;
// declared by hand since). wasi-libc's pthread_t is a
// pointer and pthread_equal compares it.
extern void *pthread_self(void);

// Captured by a constructor, which the reactor's initializer runs on the
// guest's main thread before any other thread exists: a lazily initialized
// Swift global could first be touched by a worker.
static void *main_thread;

__attribute__((constructor)) static void capture_main_thread(void) {
    main_thread = pthread_self();
}

int iso_wasi_is_main_thread(void) { return pthread_self() == main_thread; }
#else
int iso_wasi_is_main_thread(void) { return 1; }
#endif
