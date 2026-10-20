// wasi-libc hides the process APIs WASI cannot implement; the compiler
// sources reference them without ever reaching them. Declarations only —
// stubs/wasi_stubs.c supplies ENOSYS definitions.
#pragma once
#include_next <unistd.h>
#ifdef __cplusplus
extern "C" {
#endif
unsigned alarm(unsigned);
pid_t getsid(pid_t);
pid_t setsid(void);
pid_t getppid(void);
int pipe(int[2]);
pid_t fork(void);
pid_t vfork(void);
int execv(const char *, char *const[]);
int execvp(const char *, char *const[]);
int execve(const char *, char *const[], char *const[]);
int dup(int);
int dup2(int, int);
int chdir(const char *);
int fchown(int, uid_t, gid_t);
int gethostname(char *, size_t);
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);
char *ttyname(int);
#ifdef __cplusplus
}
#endif
