// Process/OS facilities the compiler sources reference but wasi-libc lacks.
// Everything here is unreachable in the browser toolchain (the frontend
// spawns nothing, loads no plugins, installs no signal handlers) — the
// definitions exist so the link resolves; each fails with ENOSYS if called.
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/types.h>

#define STUB_ATTR __attribute__((weak))

typedef struct { int _; } posix_spawnattr_t_stub;
STUB_ATTR int posix_spawn(pid_t *pid, const char *path, const void *fa, const void *attr, char *const argv[], char *const envp[]) { (void)pid; (void)path; (void)fa; (void)attr; (void)argv; (void)envp; return ENOSYS; }
STUB_ATTR int posix_spawnp(pid_t *pid, const char *file, const void *fa, const void *attr, char *const argv[], char *const envp[]) { (void)pid; (void)file; (void)fa; (void)attr; (void)argv; (void)envp; return ENOSYS; }
STUB_ATTR int posix_spawn_file_actions_init(void *fa) { (void)fa; return 0; }
STUB_ATTR int posix_spawn_file_actions_destroy(void *fa) { (void)fa; return 0; }
STUB_ATTR int posix_spawn_file_actions_adddup2(void *fa, int a, int b) { (void)fa; (void)a; (void)b; return 0; }
STUB_ATTR int posix_spawn_file_actions_addopen(void *fa, int fd, const char *p, int o, mode_t m) { (void)fa; (void)fd; (void)p; (void)o; (void)m; return 0; }
STUB_ATTR int posix_spawn_file_actions_addclose(void *fa, int fd) { (void)fa; (void)fd; return 0; }
STUB_ATTR int posix_spawnattr_init(void *a) { (void)a; return 0; }
STUB_ATTR int posix_spawnattr_destroy(void *a) { (void)a; return 0; }
STUB_ATTR int posix_spawnattr_setflags(void *a, short f) { (void)a; (void)f; return 0; }
STUB_ATTR int posix_spawnattr_setsigmask(void *a, const void *m) { (void)a; (void)m; return 0; }
STUB_ATTR int posix_spawnattr_setsigdefault(void *a, const void *m) { (void)a; (void)m; return 0; }
STUB_ATTR unsigned alarm(unsigned s) { (void)s; return 0; }
STUB_ATTR unsigned ualarm(unsigned a, unsigned b) { (void)a; (void)b; return 0; }
STUB_ATTR pid_t fork(void) { errno = ENOSYS; return -1; }
STUB_ATTR pid_t vfork(void) { errno = ENOSYS; return -1; }
STUB_ATTR int execv(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
STUB_ATTR int execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; errno = ENOSYS; return -1; }
STUB_ATTR int execvp(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
STUB_ATTR pid_t waitpid(pid_t p, int *s, int o) { (void)p; (void)s; (void)o; errno = ECHILD; return -1; }
STUB_ATTR pid_t wait(int *s) { (void)s; errno = ECHILD; return -1; }
STUB_ATTR pid_t wait4(pid_t p, int *s, int o, void *r) { (void)p; (void)s; (void)o; (void)r; errno = ECHILD; return -1; }
STUB_ATTR pid_t setsid(void) { errno = ENOSYS; return -1; }
STUB_ATTR pid_t getsid(pid_t p) { (void)p; return 1; }
STUB_ATTR int kill(pid_t p, int s) { (void)p; (void)s; errno = ENOSYS; return -1; }
STUB_ATTR int pipe(int fds[2]) { (void)fds; errno = ENOSYS; return -1; }
STUB_ATTR int dup(int fd) { (void)fd; errno = ENOSYS; return -1; }
STUB_ATTR int dup2(int a, int b) { (void)a; (void)b; errno = ENOSYS; return -1; }
STUB_ATTR int getrusage(int who, void *r) { (void)who; (void)r; errno = ENOSYS; return -1; }
STUB_ATTR int getrlimit(int r, void *l) { (void)r; (void)l; errno = ENOSYS; return -1; }
STUB_ATTR int setrlimit(int r, const void *l) { (void)r; (void)l; errno = ENOSYS; return -1; }
STUB_ATTR void *dlopen(const char *f, int m) { (void)f; (void)m; return NULL; }
STUB_ATTR void *dlsym(void *h, const char *s) { (void)h; (void)s; return NULL; }
STUB_ATTR int dlclose(void *h) { (void)h; return 0; }
STUB_ATTR char *dlerror(void) { return "dynamic loading is not available in the browser toolchain"; }
STUB_ATTR int posix_madvise(void *a, size_t l, int adv) { (void)a; (void)l; (void)adv; return 0; }
// libc++abi's thread_local destructor hook: single-threaded, so process exit.
extern int __cxa_atexit(void (*)(void *), void *, void *);
extern void *__dso_handle;
STUB_ATTR int __cxa_thread_atexit(void (*dtor)(void *), void *obj, void *dso) { return __cxa_atexit(dtor, obj, dso); }
STUB_ATTR int mkfifo(const char *p, mode_t m) { (void)p; (void)m; errno = ENOSYS; return -1; }
STUB_ATTR pid_t getppid(void) { return 1; }
STUB_ATTR uid_t getuid(void) { return 0; }
STUB_ATTR uid_t geteuid(void) { return 0; }
STUB_ATTR gid_t getgid(void) { return 0; }
STUB_ATTR gid_t getegid(void) { return 0; }
STUB_ATTR int chdir(const char *p) { (void)p; errno = ENOSYS; return -1; }
STUB_ATTR int chmod(const char *p, mode_t m) { (void)p; (void)m; return 0; }
STUB_ATTR int fchmod(int fd, mode_t m) { (void)fd; (void)m; return 0; }
STUB_ATTR mode_t umask(mode_t m) { (void)m; return 022; }
STUB_ATTR int fchown(int fd, uid_t u, gid_t g) { (void)fd; (void)u; (void)g; return 0; }
STUB_ATTR int flock(int fd, int op) { (void)fd; (void)op; return 0; }
STUB_ATTR int gethostname(char *n, size_t l) { if (l) { n[0] = 'w'; n[1] = 0; } return 0; }
STUB_ATTR int isatty_stub_unused(void) { return 0; }
STUB_ATTR char *ttyname(int fd) { (void)fd; return NULL; }
STUB_ATTR char *realpath_stub_unused(void) { return NULL; }
STUB_ATTR long sysconf_stub_unused(void) { return -1; }

// ---- C++ exception runtime entry points: the SDK's libc++abi was built
// without exceptions, and wasm has no unwinding here; a throw aborts.
STUB_ATTR void *__cxa_allocate_exception(size_t n) { return malloc(n ? n : 1); }
STUB_ATTR void __cxa_free_exception(void *p) { free(p); }
STUB_ATTR void __cxa_throw(void *obj, void *type, void (*dtor)(void *)) { (void)obj; (void)type; (void)dtor; abort(); }
STUB_ATTR void *__cxa_begin_catch(void *e) { return e; }
STUB_ATTR void __cxa_end_catch(void) {}
STUB_ATTR void __cxa_rethrow(void) { abort(); }

// ---- libuuid over wasi's getentropy (see shims/uuid/uuid.h) ----
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef unsigned char uuid_t[16];
void uuid_generate_random(uuid_t out) {
  if (getentropy(out, 16) != 0) { for (int i = 0; i < 16; i++) out[i] = (unsigned char)rand(); }
  out[6] = (out[6] & 0x0f) | 0x40;  // version 4
  out[8] = (out[8] & 0x3f) | 0x80;  // variant
}
void uuid_generate(uuid_t out) { uuid_generate_random(out); }
void uuid_generate_time(uuid_t out) { uuid_generate_random(out); }
void uuid_clear(uuid_t uu) { memset(uu, 0, 16); }
void uuid_copy(uuid_t dst, const uuid_t src) { memcpy(dst, src, 16); }
int uuid_compare(const uuid_t a, const uuid_t b) { return memcmp(a, b, 16); }
int uuid_is_null(const uuid_t uu) { for (int i = 0; i < 16; i++) if (uu[i]) return 0; return 1; }
static void uuid_unparse_fmt(const uuid_t u, char *out, const char *fmt) {
  sprintf(out, fmt, u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}
void uuid_unparse_lower(const uuid_t uu, char *out) { uuid_unparse_fmt(uu, out, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"); }
void uuid_unparse_upper(const uuid_t uu, char *out) { uuid_unparse_fmt(uu, out, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X"); }
void uuid_unparse(const uuid_t uu, char *out) { uuid_unparse_upper(uu, out); }
int uuid_parse(const char *in, uuid_t uu) {
  if (strlen(in) != 36) return -1;
  unsigned v[16];
  if (sscanf(in, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8], &v[9], &v[10], &v[11], &v[12], &v[13], &v[14], &v[15]) != 16) return -1;
  for (int i = 0; i < 16; i++) uu[i] = (unsigned char)v[i];
  return 0;
}
