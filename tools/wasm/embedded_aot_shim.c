// Accessor for a `wamrc --xip` AOT image embedded in the app's signed __TEXT
// segment (see embedded_xip_aot in //tools/wasm:defs.bzl). The symbols come
// from the generated .incbin assembly stub linked into the same binary.
#include "embedded_aot_shim.h"

extern const uint8_t iso_embedded_aot_start __asm("_iso_embedded_aot_start");
extern const uint8_t iso_embedded_aot_end __asm("_iso_embedded_aot_end");

const uint8_t *iso_embedded_aot_data(size_t *len) {
    *len = (size_t)(&iso_embedded_aot_end - &iso_embedded_aot_start);
    return &iso_embedded_aot_start;
}
