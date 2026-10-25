// wasi-libc has no <pwd.h>; LLVM's Path.inc uses getpwuid for the home
// directory fallback (never reached: $HOME is provided by the shim env).
#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
struct passwd { char *pw_name; char *pw_passwd; uid_t pw_uid; gid_t pw_gid; char *pw_gecos; char *pw_dir; char *pw_shell; };
static inline struct passwd *getpwuid(uid_t u) { (void)u; return (struct passwd *)0; }
static inline struct passwd *getpwnam(const char *n) { (void)n; return (struct passwd *)0; }
static inline int getpwnam_r(const char *n, struct passwd *p, char *b, size_t l, struct passwd **r) { (void)n; (void)p; (void)b; (void)l; *r = (struct passwd *)0; return 0; }
static inline int getpwuid_r(uid_t u, struct passwd *p, char *b, size_t l, struct passwd **r) { (void)u; (void)p; (void)b; (void)l; *r = (struct passwd *)0; return 0; }
#ifdef __cplusplus
}
#endif
