// wasi-libc has no <sys/wait.h>; LLVM's Unix support layer includes it
// unconditionally. Declarations only — the browser toolchain never waits
// on a child (stubs/wasi_stubs.c returns ECHILD).
#pragma once
#include <sys/types.h>
#include <signal.h>
#ifdef __cplusplus
extern "C" {
#endif
#define WNOHANG 1
#define WUNTRACED 2
#define WEXITSTATUS(s) (((s) & 0xff00) >> 8)
#define WTERMSIG(s) ((s) & 0x7f)
#define WSTOPSIG(s) WEXITSTATUS(s)
#define WIFEXITED(s) (!WTERMSIG(s))
#define WIFSTOPPED(s) ((short)((((s) & 0xffff) * 0x10001) >> 8) > 0x7f00)
#define WIFSIGNALED(s) (((s) & 0xffff) - 1U < 0xffu)
#define WCOREDUMP(s) ((s) & 0x80)
pid_t wait(int *);
pid_t waitpid(pid_t, int *, int);
struct rusage;
pid_t wait4(pid_t, int *, int, struct rusage *);
#ifdef __cplusplus
}
#endif
