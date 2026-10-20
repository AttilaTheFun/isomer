// Single translation unit that compiles the stb_image implementation, kept
// separate from renderer.c so the heavy header is built once.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#include "stb/stb_image.h"
