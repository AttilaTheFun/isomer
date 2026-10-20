// The iso_hot render ABI natively: what a wasm reactor imports from its host
// (render_tree, log, epoch_millis, schedule_render, platform_command,
// host_value), as callbacks a host app hands to a feature compiled into it
// against Isomer's frameworks (apple/compiled). The feature's side of it is
// wasm/libraries/swift_ui/HotBridge.swift, compiled natively.
#ifndef ISO_HOT_NATIVE_H
#define ISO_HOT_NATIVE_H

#include <stdint.h>

typedef struct IsoHotHost {
    void *ctx;
    /// The feature pushed a serialized render tree (tree.fbs Patch).
    void (*render_tree)(void *ctx, const uint8_t *bytes, int32_t length);
    void (*log)(void *ctx, const uint8_t *bytes, int32_t length);
    double (*epoch_millis)(void *ctx);
    /// The feature asked for a frame soon.
    void (*schedule_render)(void *ctx);
    /// "copy", "openURL", "share", …: key and value, UTF-8.
    void (*platform_command)(void *ctx, const uint8_t *key, int32_t key_length, const uint8_t *value,
                             int32_t value_length);
    /// A value the host holds ("pasteboard"): written into `out` (up to
    /// `capacity` bytes); its full length, or -1 for none.
    int32_t (*host_value)(void *ctx, const uint8_t *key, int32_t key_length, uint8_t *out, int32_t capacity);
} IsoHotHost;

#endif
