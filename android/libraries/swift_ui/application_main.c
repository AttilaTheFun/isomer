// How the runtime reaches the app's `@main`. In one library (the app's Swift
// and Isomer's linked together) `main` is the app's, found at link time. With
// a shared platform library (kt_swift_platform) the runtime is linked, and
// loaded, before the app's library: `main` is undefined there, so the
// reference is weak (null, not a failed load), and the app's library
// registers its `main` as it loads (application_entry.c).

typedef int (*iso_android_main)(int, char **);

extern int main(int, char **) __attribute__((weak));

static iso_android_main registered;

void iso_android_register_main(iso_android_main entry) { registered = entry; }

/// Runs the app's `@main` (installing its App in the runtime); -1 when no
/// app is linked or registered.
int iso_android_run_main(void) {
    iso_android_main entry = registered ? registered : main;
    return entry ? entry(0, 0) : -1;
}
