// Tile image decode for the desktop example hosts (Windows/Linux): the
// vendored stb_image turns fetched PNG/JPEG bytes into tightly packed
// straight-alpha RGBA for MapSceneRenderer.setTexture. Swift binds the two
// functions via @_extern(c).

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "stb_image.h"

unsigned char *sm_decode_rgba(const unsigned char *bytes, int len, int *out_w, int *out_h) {
  int channels = 0;
  return stbi_load_from_memory(bytes, len, out_w, out_h, &channels, 4);
}

void sm_free_rgba(unsigned char *pixels) { stbi_image_free(pixels); }
