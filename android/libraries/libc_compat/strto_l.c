// strtod_l and strtof_l for Android below API 26, where bionic has none:
// the Swift runtime (libswiftCore's Stubs.cpp, built at API 28) parses
// floating-point text with them in the C locale, which bionic's strtod and
// strtof always use. (Below 26 the NDK's <stdlib.h> has them as inline
// functions for C, not as symbols: so declared here, not included.)
#include <android/api-level.h>

#if __ANDROID_API__ < 26
double strtod(const char *string, char **end);
float strtof(const char *string, char **end);

double strtod_l(const char *string, char **end, void *locale) {
    (void)locale;
    return strtod(string, end);
}

float strtof_l(const char *string, char **end, void *locale) {
    (void)locale;
    return strtof(string, end);
}
#endif
