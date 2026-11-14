// A C++ library's C entry, for the app's Swift: what it computes goes
// through libc++ (strings, vectors, an exception thrown and caught, a
// dynamic_cast), so the app's library refers to libc++ from C++ objects
// of its own as well as from the Swift runtime's.
#ifndef ISOMER_LIBCXX_PROBE_H
#define ISOMER_LIBCXX_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

// The length of a string built in C++, or -1 if C++'s exceptions and RTTI
// misbehave.
int libcxx_probe(int count);

#ifdef __cplusplus
}
#endif

#endif
