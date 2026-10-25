// A small libuuid for the Android host build of swift-frontend (Android
// ships none): the six functions swift/lib/Basic/UUID.cpp calls.
#ifndef ISO_ANDROID_UUID_H
#define ISO_ANDROID_UUID_H
#ifdef __cplusplus
extern "C" {
#endif
typedef unsigned char uuid_t[16];
void uuid_clear(uuid_t uu);
int uuid_compare(const uuid_t a, const uuid_t b);
void uuid_generate_random(uuid_t out);
void uuid_generate_time(uuid_t out);
int uuid_parse(const char *in, uuid_t uu);
void uuid_unparse_upper(const uuid_t uu, char *out);
#ifdef __cplusplus
}
#endif
#endif
