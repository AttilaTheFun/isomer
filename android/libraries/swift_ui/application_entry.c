// Linked into the app's own library: registers its `@main` with the runtime
// as the library loads (application_main.c), which a runtime in a shared
// platform library can't find by name.

extern int main(int, char **);
extern void iso_android_register_main(int (*)(int, char **));

__attribute__((constructor)) static void iso_android_register_app_main(void) {
    iso_android_register_main(main);
}
