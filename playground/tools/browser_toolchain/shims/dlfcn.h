// See unistd.h shim: dladdr's Dl_info (LLVM's Path.inc uses it for the
// "path of this executable" fallback; wasm has no dynamic loading).
#pragma once
#include_next <dlfcn.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef __iso_dl_info
#define __iso_dl_info 1
typedef struct { const char *dli_fname; void *dli_fbase; const char *dli_sname; void *dli_saddr; } Dl_info;
static inline int dladdr(const void *a, Dl_info *i) { (void)a; (void)i; return 0; }
#endif
#ifdef __cplusplus
}
#endif
