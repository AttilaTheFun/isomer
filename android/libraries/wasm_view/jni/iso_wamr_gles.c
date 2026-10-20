// The native OpenGL ES binding for a GPU (self-drawing) wasm reactor: WAMR
// "env" natives for the gl* imports swift_gpu's GLES backend emits when
// compiled to wasm (its @_extern(c) declarations stay undefined at link and
// surface as env imports). This is the same "the GPU implementation is
// entirely native code, bound on the platform side" contract as the compiled
// path — only the binding moment moves from link time to instantiate time.
//
// Every native runs on the host's GL thread with the EGL context current
// (the iso_wamr_* GPU entry points require it; see iso_wamr.h).
//
// Pointer discipline: wasm passes linear-memory offsets. Pointers consumed
// synchronously (shader sources, uniform data, texel uploads, out-handles)
// are translated at call time. Client vertex arrays are NOT — GL only reads
// them inside glDrawArrays, and the linear memory's base can move (memory.grow)
// between glVertexAttribPointer and the draw. So attrib pointers are recorded
// as offsets and bound (translated) inside glDrawArrays, immediately before
// the real draw.
#include <stdint.h>
#include <string.h>

#include <GLES2/gl2.h>

#include "wasm_export.h"

// Translate a guest offset to a host pointer (NULL-safe: offset 0 -> NULL,
// matching GL's optional-pointer parameters).
static void *addr(wasm_exec_env_t e, uint32_t ptr) {
    if (!ptr) return NULL;
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(e);
    return inst ? wasm_runtime_addr_app_to_native(inst, ptr) : NULL;
}

// ---- Deferred client vertex arrays (see header comment) ----

#define ISO_GLES_MAX_ATTRIBS 16

typedef struct {
    int bound;       // glVertexAttribPointer recorded for this index
    GLint size;
    GLenum type;
    GLboolean normalized;
    GLsizei stride;
    uint32_t app_ptr;  // guest offset of the client array
} AttribSlot;

// One GL context / one GL thread per process (the GLSurfaceView contract), so
// process-global slots are fine — mirroring GL's own per-context attrib state.
static AttribSlot g_attribs[ISO_GLES_MAX_ATTRIBS];

static void nat_glVertexAttribPointer(wasm_exec_env_t e, uint32_t index, uint32_t size,
                                      uint32_t type, uint32_t normalized, uint32_t stride,
                                      uint32_t pointer) {
    (void)e;
    if (index >= ISO_GLES_MAX_ATTRIBS) return;
    AttribSlot *s = &g_attribs[index];
    s->bound = 1;
    s->size = (GLint)size;
    s->type = (GLenum)type;
    s->normalized = (GLboolean)normalized;
    s->stride = (GLsizei)stride;
    s->app_ptr = pointer;
}

static void nat_glDrawArrays(wasm_exec_env_t e, uint32_t mode, uint32_t first, uint32_t count) {
    // Bind the recorded client arrays NOW (no wasm code runs between these
    // translations and the draw, so the base cannot move under GL).
    for (int i = 0; i < ISO_GLES_MAX_ATTRIBS; i++) {
        AttribSlot *s = &g_attribs[i];
        if (!s->bound) continue;
        glVertexAttribPointer((GLuint)i, s->size, s->type, s->normalized, s->stride,
                              addr(e, s->app_ptr));
    }
    glDrawArrays((GLenum)mode, (GLint)first, (GLsizei)count);
}

static void nat_glEnableVertexAttribArray(wasm_exec_env_t e, uint32_t index) {
    (void)e;
    glEnableVertexAttribArray((GLuint)index);
}

static void nat_glDisableVertexAttribArray(wasm_exec_env_t e, uint32_t index) {
    (void)e;
    if (index < ISO_GLES_MAX_ATTRIBS) g_attribs[index].bound = 0;
    glDisableVertexAttribArray((GLuint)index);
}

// ---- Straightforward wrappers (pointers translated at call time) ----

static void nat_glClearColor(wasm_exec_env_t e, float r, float g, float b, float a) {
    (void)e;
    glClearColor(r, g, b, a);
}

static void nat_glClear(wasm_exec_env_t e, uint32_t mask) {
    (void)e;
    glClear((GLbitfield)mask);
}

static void nat_glViewport(wasm_exec_env_t e, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    (void)e;
    glViewport((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

static uint32_t nat_glCreateProgram(wasm_exec_env_t e) {
    (void)e;
    return (uint32_t)glCreateProgram();
}

static uint32_t nat_glCreateShader(wasm_exec_env_t e, uint32_t type) {
    (void)e;
    return (uint32_t)glCreateShader((GLenum)type);
}

// glShaderSource(shader, count, const char **string, const int *length): the
// string array holds GUEST pointers (u32 offsets) — translate each.
static void nat_glShaderSource(wasm_exec_env_t e, uint32_t shader, uint32_t count,
                               uint32_t strings_ptr, uint32_t lengths_ptr) {
    enum { MAX_SOURCES = 8 };
    if (count == 0 || count > MAX_SOURCES) return;
    const uint32_t *guest_ptrs = (const uint32_t *)addr(e, strings_ptr);
    if (!guest_ptrs) return;
    const GLchar *sources[MAX_SOURCES];
    for (uint32_t i = 0; i < count; i++) {
        sources[i] = (const GLchar *)addr(e, guest_ptrs[i]);
        if (!sources[i]) return;
    }
    const GLint *lengths = (const GLint *)addr(e, lengths_ptr);
    glShaderSource((GLuint)shader, (GLsizei)count, sources, lengths);
}

static void nat_glCompileShader(wasm_exec_env_t e, uint32_t shader) {
    (void)e;
    glCompileShader((GLuint)shader);
}

static void nat_glAttachShader(wasm_exec_env_t e, uint32_t program, uint32_t shader) {
    (void)e;
    glAttachShader((GLuint)program, (GLuint)shader);
}

static void nat_glLinkProgram(wasm_exec_env_t e, uint32_t program) {
    (void)e;
    glLinkProgram((GLuint)program);
}

static void nat_glUseProgram(wasm_exec_env_t e, uint32_t program) {
    (void)e;
    glUseProgram((GLuint)program);
}

static uint32_t nat_glGetAttribLocation(wasm_exec_env_t e, uint32_t program, uint32_t name) {
    const GLchar *n = (const GLchar *)addr(e, name);
    return n ? (uint32_t)glGetAttribLocation((GLuint)program, n) : (uint32_t)-1;
}

static uint32_t nat_glGetUniformLocation(wasm_exec_env_t e, uint32_t program, uint32_t name) {
    const GLchar *n = (const GLchar *)addr(e, name);
    return n ? (uint32_t)glGetUniformLocation((GLuint)program, n) : (uint32_t)-1;
}

static void nat_glUniform1i(wasm_exec_env_t e, uint32_t location, uint32_t value) {
    (void)e;
    glUniform1i((GLint)location, (GLint)value);
}

static void nat_glUniformMatrix4fv(wasm_exec_env_t e, uint32_t location, uint32_t count,
                                   uint32_t transpose, uint32_t value) {
    const GLfloat *v = (const GLfloat *)addr(e, value);
    if (v) glUniformMatrix4fv((GLint)location, (GLsizei)count, (GLboolean)transpose, v);
}

static void nat_glGenTextures(wasm_exec_env_t e, uint32_t count, uint32_t textures) {
    GLuint *out = (GLuint *)addr(e, textures);
    if (out) glGenTextures((GLsizei)count, out);
}

static void nat_glDeleteTextures(wasm_exec_env_t e, uint32_t count, uint32_t textures) {
    const GLuint *in = (const GLuint *)addr(e, textures);
    if (in) glDeleteTextures((GLsizei)count, in);
}

static void nat_glBindTexture(wasm_exec_env_t e, uint32_t target, uint32_t texture) {
    (void)e;
    glBindTexture((GLenum)target, (GLuint)texture);
}

static void nat_glActiveTexture(wasm_exec_env_t e, uint32_t texture) {
    (void)e;
    glActiveTexture((GLenum)texture);
}

static void nat_glTexParameteri(wasm_exec_env_t e, uint32_t target, uint32_t name,
                                uint32_t value) {
    (void)e;
    glTexParameteri((GLenum)target, (GLenum)name, (GLint)value);
}

static void nat_glTexImage2D(wasm_exec_env_t e, uint32_t target, uint32_t level,
                             uint32_t internal_format, uint32_t width, uint32_t height,
                             uint32_t border, uint32_t format, uint32_t type,
                             uint32_t pixels) {
    glTexImage2D((GLenum)target, (GLint)level, (GLint)internal_format, (GLsizei)width,
                 (GLsizei)height, (GLint)border, (GLenum)format, (GLenum)type,
                 addr(e, pixels));
}

static void nat_glEnable(wasm_exec_env_t e, uint32_t capability) {
    (void)e;
    glEnable((GLenum)capability);
}

static void nat_glDisable(wasm_exec_env_t e, uint32_t capability) {
    (void)e;
    glDisable((GLenum)capability);
}

static void nat_glScissor(wasm_exec_env_t e, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    (void)e;
    glScissor((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

static void nat_glBlendFuncSeparate(wasm_exec_env_t e, uint32_t src_rgb, uint32_t dst_rgb,
                                    uint32_t src_alpha, uint32_t dst_alpha) {
    (void)e;
    glBlendFuncSeparate((GLenum)src_rgb, (GLenum)dst_rgb, (GLenum)src_alpha, (GLenum)dst_alpha);
}

static NativeSymbol g_gles_natives[] = {
    {"glClearColor", (void *)nat_glClearColor, "(ffff)", NULL},
    {"glClear", (void *)nat_glClear, "(i)", NULL},
    {"glViewport", (void *)nat_glViewport, "(iiii)", NULL},
    {"glCreateProgram", (void *)nat_glCreateProgram, "()i", NULL},
    {"glCreateShader", (void *)nat_glCreateShader, "(i)i", NULL},
    {"glShaderSource", (void *)nat_glShaderSource, "(iiii)", NULL},
    {"glCompileShader", (void *)nat_glCompileShader, "(i)", NULL},
    {"glAttachShader", (void *)nat_glAttachShader, "(ii)", NULL},
    {"glLinkProgram", (void *)nat_glLinkProgram, "(i)", NULL},
    {"glUseProgram", (void *)nat_glUseProgram, "(i)", NULL},
    {"glGetAttribLocation", (void *)nat_glGetAttribLocation, "(ii)i", NULL},
    {"glGetUniformLocation", (void *)nat_glGetUniformLocation, "(ii)i", NULL},
    {"glUniform1i", (void *)nat_glUniform1i, "(ii)", NULL},
    {"glUniformMatrix4fv", (void *)nat_glUniformMatrix4fv, "(iiii)", NULL},
    {"glEnableVertexAttribArray", (void *)nat_glEnableVertexAttribArray, "(i)", NULL},
    {"glDisableVertexAttribArray", (void *)nat_glDisableVertexAttribArray, "(i)", NULL},
    {"glVertexAttribPointer", (void *)nat_glVertexAttribPointer, "(iiiiii)", NULL},
    {"glDrawArrays", (void *)nat_glDrawArrays, "(iii)", NULL},
    {"glGenTextures", (void *)nat_glGenTextures, "(ii)", NULL},
    {"glDeleteTextures", (void *)nat_glDeleteTextures, "(ii)", NULL},
    {"glBindTexture", (void *)nat_glBindTexture, "(ii)", NULL},
    {"glActiveTexture", (void *)nat_glActiveTexture, "(i)", NULL},
    {"glTexParameteri", (void *)nat_glTexParameteri, "(iii)", NULL},
    {"glTexImage2D", (void *)nat_glTexImage2D, "(iiiiiiiii)", NULL},
    {"glEnable", (void *)nat_glEnable, "(i)", NULL},
    {"glDisable", (void *)nat_glDisable, "(i)", NULL},
    {"glScissor", (void *)nat_glScissor, "(iiii)", NULL},
    {"glBlendFuncSeparate", (void *)nat_glBlendFuncSeparate, "(iiii)", NULL},
};

// Registered with the process-global WAMR runtime via
// iso_wamr_set_extra_natives (JNI_OnLoad installs it). Returns non-zero on
// success, mirroring wasm_runtime_register_natives.
int iso_wamr_register_gles_natives(void) {
    memset(g_attribs, 0, sizeof(g_attribs));
    return wasm_runtime_register_natives(
        "env", g_gles_natives, sizeof(g_gles_natives) / sizeof(g_gles_natives[0]));
}
