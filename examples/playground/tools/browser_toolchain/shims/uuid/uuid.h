// libuuid's interface for the wasm host (swift's lib/Basic UUID uses it on
// non-Darwin). Implemented in stubs/wasi_stubs.c over wasi's getentropy.
#pragma once
#include <stddef.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef unsigned char uuid_t[16];
#define UUID_STR_LEN 37
void uuid_generate(uuid_t out);
void uuid_generate_random(uuid_t out);
void uuid_generate_time(uuid_t out);
void uuid_clear(uuid_t uu);
void uuid_copy(uuid_t dst, const uuid_t src);
int uuid_compare(const uuid_t a, const uuid_t b);
int uuid_is_null(const uuid_t uu);
int uuid_parse(const char *in, uuid_t uu);
void uuid_unparse(const uuid_t uu, char *out);
void uuid_unparse_lower(const uuid_t uu, char *out);
void uuid_unparse_upper(const uuid_t uu, char *out);
#ifdef __cplusplus
}
#endif
