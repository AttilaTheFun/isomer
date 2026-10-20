// The flat C surface of the D3D11 shim (sgpu_d3d11.cpp), bound via
// `@_extern(c)` like the Android backend's GL bindings — no bridging header
// (the bridging-header PCH is flaky on Windows; see isomer's
// -disable-bridging-pch note). Only what the backend uses.

@_extern(c) func sgpu_d3d_init_hwnd(
    _ hwnd: UnsafeMutableRawPointer, _ widthPx: Int32, _ heightPx: Int32
) -> Int32
@_extern(c) func sgpu_d3d_init_offscreen(_ widthPx: Int32, _ heightPx: Int32) -> Int32
@_extern(c) func sgpu_d3d_resize(_ widthPx: Int32, _ heightPx: Int32)
@_extern(c) func sgpu_d3d_begin_frame(_ r: Float, _ g: Float, _ b: Float, _ a: Float)
@_extern(c) func sgpu_d3d_end_frame()
@_extern(c) func sgpu_d3d_read_pixels(_ out: UnsafeMutablePointer<UInt8>)
@_extern(c) func sgpu_d3d_set_transform(_ matrix16: UnsafePointer<Float>)
@_extern(c) func sgpu_d3d_make_texture(
    _ width: Int32, _ height: Int32, _ rgba: UnsafePointer<UInt8>
) -> Int32
@_extern(c) func sgpu_d3d_destroy_texture(_ id: Int32)
@_extern(c) func sgpu_d3d_draw_textured(
    _ vertices: UnsafePointer<Float>, _ floatCount: Int32, _ textureID: Int32
)
@_extern(c) func sgpu_d3d_draw_color(_ vertices: UnsafePointer<Float>, _ floatCount: Int32)
@_extern(c) func sgpu_d3d_draw_rect_vertices(
    _ vertices: UnsafePointer<Float>, _ floatCount: Int32
)
@_extern(c) func sgpu_d3d_set_scissor(_ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32)
@_extern(c) func sgpu_d3d_clear_scissor()
