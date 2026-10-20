// The iso_hot render ABI's exports, as the C functions a natively compiled
// feature defines (HotBridge.swift's @_cdecl functions): what the host calls,
// in the reactor's names and shapes, with host memory where a reactor takes
// guest memory.
#ifndef ISO_HOT_EXPORTS_H
#define ISO_HOT_EXPORTS_H

#include "iso_hot_native.h"

void iso_hot_set_host(const IsoHotHost *host);
void iso_hot_start(double width, double height);
void iso_hot_render(void);
void iso_hot_render_pending(void);
void iso_hot_shutdown(void);
int32_t iso_hot_pending_tasks(void);
void iso_hot_resize(double width, double height);
void iso_hot_configure(const uint8_t *key, int32_t key_length, const uint8_t *value, int32_t value_length);
void iso_hot_set_color_scheme(int32_t dark);
void iso_hot_set_scene_phase(int32_t phase);
void iso_hot_set_size_classes(int32_t horizontal, int32_t vertical);
void iso_hot_event(const uint8_t *id, int32_t id_length, const uint8_t *value, int32_t value_length);

#endif
