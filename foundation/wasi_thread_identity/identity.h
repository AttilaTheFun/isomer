#ifndef ISO_WASI_THREAD_IDENTITY_H
#define ISO_WASI_THREAD_IDENTITY_H

/// Whether the calling thread is the guest's main thread: the one that ran
/// the reactor's constructors (`_initialize`), which is the thread the host
/// drives it from. 1 on a single-threaded build.
int iso_wasi_is_main_thread(void);

#endif
