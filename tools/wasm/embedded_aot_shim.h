// The embedded (`wamrc --xip`, executed-in-place) AOT image linked into this
// binary's __TEXT segment — the iOS-legal AOT tier of the hybrid delivery
// policy (interp remains the dynamically-deliverable tier). Returns the image
// bytes and writes their length; the memory is read-only, executable, and
// covered by the app's code signature.
#ifndef ISO_EMBEDDED_AOT_SHIM_H
#define ISO_EMBEDDED_AOT_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const uint8_t *iso_embedded_aot_data(size_t *len);

#ifdef __cplusplus
}
#endif

#endif  // ISO_EMBEDDED_AOT_SHIM_H
