#include "uuid/uuid.h"
#include <stdio.h>
#include <string.h>
#include <sys/random.h>

void uuid_clear(uuid_t uu) { memset(uu, 0, 16); }
int uuid_compare(const uuid_t a, const uuid_t b) { return memcmp(a, b, 16); }
void uuid_generate_random(uuid_t out) {
    size_t got = 0;
    while (got < 16) {
        ssize_t n = getrandom(out + got, 16 - got, 0);
        if (n <= 0) break;
        got += (size_t)n;
    }
    out[6] = (out[6] & 0x0f) | 0x40;  // version 4
    out[8] = (out[8] & 0x3f) | 0x80;  // variant
}
void uuid_generate_time(uuid_t out) { uuid_generate_random(out); }
int uuid_parse(const char *in, uuid_t uu) {
    if (strlen(in) != 36) return -1;
    unsigned v[16];
    if (sscanf(in, "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
               &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7],
               &v[8], &v[9], &v[10], &v[11], &v[12], &v[13], &v[14], &v[15]) != 16) return -1;
    for (int i = 0; i < 16; i++) uu[i] = (unsigned char)v[i];
    return 0;
}
void uuid_unparse_upper(const uuid_t u, char *out) {
    sprintf(out, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}
