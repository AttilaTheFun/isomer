// See unistd.h shim: rlimits (wasi-libc keeps only rusage, and only with
// _WASI_EMULATED_PROCESS_CLOCKS).
#pragma once
#include_next <sys/resource.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef RLIMIT_STACK
typedef unsigned long long rlim_t;
struct rlimit { rlim_t rlim_cur; rlim_t rlim_max; };
#define RLIM_INFINITY (~(rlim_t)0)
#define RLIM_SAVED_CUR RLIM_INFINITY
#define RLIM_SAVED_MAX RLIM_INFINITY
#define RLIMIT_CPU 0
#define RLIMIT_FSIZE 1
#define RLIMIT_DATA 2
#define RLIMIT_STACK 3
#define RLIMIT_CORE 4
#define RLIMIT_RSS 5
#define RLIMIT_NPROC 6
#define RLIMIT_NOFILE 7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS 9
int getrlimit(int, struct rlimit *);
int setrlimit(int, const struct rlimit *);
#endif
#ifdef __cplusplus
}
#endif
