// See unistd.h shim: POSIX advisory record locks (LLVM's Path.inc tryLockFile;
// wasi's fcntl rejects the commands, which LLVM treats as "lock unavailable").
#pragma once
#include_next <fcntl.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef F_RDLCK
#define F_RDLCK 0
#define F_WRLCK 1
#define F_UNLCK 2
#endif
#ifndef F_SETLK
#define F_SETLK 6
#define F_SETLKW 7
#define F_GETLK 5
#endif
#ifdef __cplusplus
}
#endif
