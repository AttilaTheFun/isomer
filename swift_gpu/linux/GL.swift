// Raw OpenGL bindings via `@_extern(c)`: no headers or module maps needed —
// the declarations resolve against libGL.so at link time (the library's
// linkopts add `-lGL`). Desktop GL exports the same entry points the Android
// backend binds from libGLESv2; only what the backend uses is declared.
// A copy of swift_gpu/android/GLES.swift (see the implementation guide).

// swiftlint:disable identifier_name

@_extern(c) func glClearColor(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float)
@_extern(c) func glClear(_ mask: UInt32)
@_extern(c) func glViewport(_ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32)

@_extern(c) func glCreateProgram() -> UInt32
@_extern(c) func glCreateShader(_ type: UInt32) -> UInt32
@_extern(c) func glShaderSource(
    _ shader: UInt32,
    _ count: Int32,
    _ string: UnsafePointer<UnsafePointer<CChar>?>,
    _ length: UnsafePointer<Int32>?
)
@_extern(c) func glCompileShader(_ shader: UInt32)
@_extern(c) func glAttachShader(_ program: UInt32, _ shader: UInt32)
@_extern(c) func glLinkProgram(_ program: UInt32)
@_extern(c) func glUseProgram(_ program: UInt32)
@_extern(c) func glGetAttribLocation(_ program: UInt32, _ name: UnsafePointer<CChar>) -> Int32
@_extern(c) func glGetUniformLocation(_ program: UInt32, _ name: UnsafePointer<CChar>) -> Int32

@_extern(c) func glUniform1i(_ location: Int32, _ value: Int32)
@_extern(c) func glUniformMatrix4fv(
    _ location: Int32,
    _ count: Int32,
    _ transpose: UInt8,
    _ value: UnsafePointer<Float>
)
@_extern(c) func glEnableVertexAttribArray(_ index: UInt32)
@_extern(c) func glDisableVertexAttribArray(_ index: UInt32)
@_extern(c) func glVertexAttribPointer(
    _ index: UInt32,
    _ size: Int32,
    _ type: UInt32,
    _ normalized: UInt8,
    _ stride: Int32,
    _ pointer: UnsafeRawPointer?
)
@_extern(c) func glDrawArrays(_ mode: UInt32, _ first: Int32, _ count: Int32)

@_extern(c) func glGenTextures(_ count: Int32, _ textures: UnsafeMutablePointer<UInt32>)
@_extern(c) func glDeleteTextures(_ count: Int32, _ textures: UnsafePointer<UInt32>)
@_extern(c) func glBindTexture(_ target: UInt32, _ texture: UInt32)
@_extern(c) func glActiveTexture(_ texture: UInt32)
@_extern(c) func glTexParameteri(_ target: UInt32, _ name: UInt32, _ value: Int32)
@_extern(c) func glTexImage2D(
    _ target: UInt32,
    _ level: Int32,
    _ internalFormat: Int32,
    _ width: Int32,
    _ height: Int32,
    _ border: Int32,
    _ format: UInt32,
    _ type: UInt32,
    _ pixels: UnsafeRawPointer?
)

// Core-profile plumbing (GL 3.3: client-side vertex arrays are gone, so
// draws stream through one VBO under one VAO).
@_extern(c) func glGenVertexArrays(_ count: Int32, _ arrays: UnsafeMutablePointer<UInt32>)
@_extern(c) func glBindVertexArray(_ array: UInt32)
@_extern(c) func glGenBuffers(_ count: Int32, _ buffers: UnsafeMutablePointer<UInt32>)
@_extern(c) func glBindBuffer(_ target: UInt32, _ buffer: UInt32)
@_extern(c) func glBufferData(
    _ target: UInt32,
    _ size: Int,
    _ data: UnsafeRawPointer?,
    _ usage: UInt32
)

@_extern(c) func glEnable(_ capability: UInt32)
@_extern(c) func glDisable(_ capability: UInt32)
@_extern(c) func glScissor(_ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32)
@_extern(c) func glBlendFuncSeparate(
    _ srcRGB: UInt32,
    _ dstRGB: UInt32,
    _ srcAlpha: UInt32,
    _ dstAlpha: UInt32
)
@_extern(c) func glReadPixels(
    _ x: Int32,
    _ y: Int32,
    _ width: Int32,
    _ height: Int32,
    _ format: UInt32,
    _ type: UInt32,
    _ pixels: UnsafeMutableRawPointer?
)

// The GL constants the backend touches.
let GL_COLOR_BUFFER_BIT: UInt32 = 0x4000
let GL_TRIANGLES: UInt32 = 0x0004
let GL_FLOAT: UInt32 = 0x1406
let GL_VERTEX_SHADER: UInt32 = 0x8B31
let GL_FRAGMENT_SHADER: UInt32 = 0x8B30
let GL_TEXTURE_2D: UInt32 = 0x0DE1
let GL_TEXTURE0: UInt32 = 0x84C0
let GL_TEXTURE_MIN_FILTER: UInt32 = 0x2801
let GL_TEXTURE_MAG_FILTER: UInt32 = 0x2800
let GL_TEXTURE_WRAP_S: UInt32 = 0x2802
let GL_TEXTURE_WRAP_T: UInt32 = 0x2803
let GL_LINEAR: Int32 = 0x2601
let GL_CLAMP_TO_EDGE: Int32 = 0x812F
let GL_RGBA: UInt32 = 0x1908
let GL_UNSIGNED_BYTE: UInt32 = 0x1401
let GL_BLEND: UInt32 = 0x0BE2
let GL_SRC_ALPHA: UInt32 = 0x0302
let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303
let GL_ONE: UInt32 = 0x0001
let GL_SCISSOR_TEST: UInt32 = 0x0C11
let GL_ARRAY_BUFFER: UInt32 = 0x8892
let GL_STREAM_DRAW: UInt32 = 0x88E0
