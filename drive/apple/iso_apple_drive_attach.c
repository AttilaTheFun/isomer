// Starts the Apple accessibility driver (AccessibilityDriver.swift) once the
// app is running: a constructor of the library --@isomer//drive:headful links
// into an app on Apple's SwiftUI, so the app's own code calls nothing. Half a
// second after launch, on the main queue (the app's first scene is up by
// then; the driver reads the screen afresh at every command anyway).
#include <dispatch/dispatch.h>

extern void iso_apple_drive_attach(void);

static void iso_apple_drive_start(void *context) {
    (void)context;
    iso_apple_drive_attach();
}

__attribute__((constructor)) static void iso_apple_drive_schedule(void) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), NULL,
                     iso_apple_drive_start);
}
