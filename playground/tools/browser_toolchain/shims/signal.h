// See unistd.h shim: sigaction & friends, absent from wasi-libc's emulated
// <signal.h>. Handlers are never installed (LLVM_ENABLE_BACKTRACES /
// CRASH_OVERRIDES are off); these exist so the sources compile.
#pragma once
#include_next <signal.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef SA_SIGINFO
#define SA_NOCLDSTOP 1
#define SA_NOCLDWAIT 2
#define SA_SIGINFO 4
#define SA_ONSTACK 0x08000000
#define SA_RESTART 0x10000000
#define SA_NODEFER 0x40000000
#define SA_RESETHAND 0x80000000
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
#ifndef SIGSTKSZ
#define SIGSTKSZ 8192
#define MINSIGSTKSZ 2048
#endif
#ifndef SIGKILL
#define SIGKILL 9
#endif
#ifndef SIGPIPE
#define SIGPIPE 13
#endif
#ifndef SIGUSR1
#define SIGUSR1 10
#define SIGUSR2 12
#endif
#ifndef SIGCHLD
#define SIGCHLD 17
#endif
#ifndef SIGHUP
#define SIGHUP 1
#endif
#ifndef SIGQUIT
#define SIGQUIT 3
#endif
#ifndef SIGTRAP
#define SIGTRAP 5
#endif
#ifndef SIGBUS
#define SIGBUS 7
#endif
#ifndef SIGSYS
#define SIGSYS 31
#endif
#ifndef SIGXCPU
#define SIGXCPU 24
#define SIGXFSZ 25
#endif
#ifndef SIGWINCH
#define SIGWINCH 28
#endif
#ifndef SIGINFO
#define SIGINFO 29
#endif
typedef struct { unsigned long __bits[128 / sizeof(long)]; } __iso_sigset_t;
#ifndef __DEFINED_sigset_t
typedef __iso_sigset_t sigset_t;
#define __DEFINED_sigset_t
#endif
#ifndef __DEFINED_siginfo_t
typedef struct { int si_signo, si_errno, si_code; void *si_addr; int si_pid; } siginfo_t;
#define __DEFINED_siginfo_t
#endif
struct sigaction {
  union {
    void (*sa_handler)(int);
    void (*sa_sigaction)(int, siginfo_t *, void *);
  } __sa_handler;
  sigset_t sa_mask;
  int sa_flags;
  void (*sa_restorer)(void);
};
#define sa_handler __sa_handler.sa_handler
#define sa_sigaction __sa_handler.sa_sigaction
#ifndef __DEFINED_stack_t
typedef struct sigaltstack { void *ss_sp; int ss_flags; size_t ss_size; } stack_t;
#define __DEFINED_stack_t
#endif
static inline int sigemptyset(sigset_t *s) { (void)s; return 0; }
static inline int sigfillset(sigset_t *s) { (void)s; return 0; }
static inline int sigaddset(sigset_t *s, int n) { (void)s; (void)n; return 0; }
static inline int sigdelset(sigset_t *s, int n) { (void)s; (void)n; return 0; }
static inline int sigismember(const sigset_t *s, int n) { (void)s; (void)n; return 0; }
static inline int sigprocmask(int h, const sigset_t *s, sigset_t *o) { (void)h; (void)s; (void)o; return 0; }
static inline int sigaction(int n, const struct sigaction *a, struct sigaction *o) { (void)n; (void)a; (void)o; return 0; }
static inline int sigaltstack(const stack_t *s, stack_t *o) { (void)s; (void)o; return 0; }
static inline int kill(pid_t p, int s) { (void)p; (void)s; return -1; }
static inline int sigsuspend(const sigset_t *s) { (void)s; return -1; }
#endif
#ifdef __cplusplus
}
#endif
