// The shim probe: file read/write/seek, directory listing, stdout/stderr, exit code.
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage\n"); return 2; }
    FILE *in = fopen(argv[1], "rb");
    if (!in) { perror("fopen in"); return 3; }
    char buf[256]; size_t n = fread(buf, 1, sizeof(buf) - 1, in); buf[n] = 0; fclose(in);
    printf("read: %s", buf);
    struct stat st; if (stat(argv[1], &st) == 0) printf("size: %lld\n", (long long)st.st_size);
    FILE *out = fopen(argv[2], "wb");
    if (!out) { perror("fopen out"); return 4; }
    fprintf(out, "copied: %s", buf); fseek(out, 0, SEEK_END); fprintf(out, "end\n"); fclose(out);
    DIR *d = opendir(argv[3]);
    if (!d) { perror("opendir"); return 5; }
    struct dirent *e; while ((e = readdir(d))) printf("entry: %s\n", e->d_name);
    closedir(d);
    fprintf(stderr, "warning: probe done\n");
    return 7;
}
