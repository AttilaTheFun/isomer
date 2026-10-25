// See unistd.h shim: terminal window size (LLVM's Process.inc asks for the
// column count; the browser has no terminal, ioctl fails).
#pragma once
#include_next <sys/ioctl.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef TIOCGWINSZ
#define TIOCGWINSZ 0x5413
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
#endif
#ifdef __cplusplus
}
#endif
