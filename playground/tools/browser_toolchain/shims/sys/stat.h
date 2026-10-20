// See unistd.h shim: umask (wasi-libc has no process umask).
#pragma once
#include_next <sys/stat.h>
#ifdef __cplusplus
extern "C" {
#endif
mode_t umask(mode_t);
#ifdef __cplusplus
}
#endif
