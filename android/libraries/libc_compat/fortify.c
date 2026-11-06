// __fread_chk and __fwrite_chk for Android below API 24, where bionic has
// neither: the Swift SDK's prebuilt ICU (lib_FoundationICU.a, built at API
// 28 with _FORTIFY_SOURCE) calls them, so an app with
// --@isomer//foundation:internationalization links them. Checked as
// bionic's are: a read or write past the buffer aborts.
#include <android/api-level.h>

#if __ANDROID_API__ < 24
#include <stdio.h>
#include <stdlib.h>

size_t __fread_chk(void *buffer, size_t buffer_size, size_t size, size_t count, FILE *stream) {
    if (size != 0 && count > buffer_size / size) abort();
    return fread(buffer, size, count, stream);
}

size_t __fwrite_chk(const void *buffer, size_t buffer_size, size_t size, size_t count, FILE *stream) {
    if (size != 0 && count > buffer_size / size) abort();
    return fwrite(buffer, size, count, stream);
}
#endif
