// The OpenGL ES 2 backend: Swift calls GL directly (see GLES.swift) on the
// host's GL thread. The host owns the EGL surface/context (an Android
// GLSurfaceView); this backend owns programs, textures, and draws.
//
// Threading contract: every call happens on the GL thread with the context
// current. After a context loss the host calls `contextLost()` — programs
// and textures are rebuilt/refetched by the consumer (handles died with
// the context).

private let texturedVertexShader = """
attribute vec2 pos;
attribute vec2 uv;
uniform mat4 transform;
varying vec2 vUV;
void main() {
    gl_Position = transform * vec4(pos, 0.0, 1.0);
    vUV = uv;
}
"""

private let texturedFragmentShader = """
precision mediump float;
varying vec2 vUV;
uniform sampler2D tex;
void main() { gl_FragColor = texture2D(tex, vUV); }
"""

private let colorVertexShader = """
attribute vec2 pos;
attribute vec4 color;
uniform mat4 transform;
varying vec4 vColor;
void main() {
    gl_Position = transform * vec4(pos, 0.0, 1.0);
    vColor = color;
}
"""

private let colorFragmentShader = """
precision mediump float;
varying vec4 vColor;
void main() { gl_FragColor = vColor; }
"""

// The SDF rounded-rect program consumes expandRectInstances vertices
// (stride 12); attributes pack as pos(2)+local(2)+halfSize(2) then
// radius+border(2)+color(4).
private let rectVertexShader = """
attribute vec2 pos;
attribute vec2 localPos;
attribute vec2 halfSize;
attribute vec2 radiusBorder;
attribute vec4 color;
uniform mat4 transform;
varying vec2 vLocal;
varying vec2 vHalfSize;
varying vec2 vRadiusBorder;
varying vec4 vColor;
void main() {
    gl_Position = transform * vec4(pos, 0.0, 1.0);
    vLocal = localPos;
    vHalfSize = halfSize;
    vRadiusBorder = radiusBorder;
    vColor = color;
}
"""

private let rectFragmentShader = """
precision mediump float;
varying vec2 vLocal;
varying vec2 vHalfSize;
varying vec2 vRadiusBorder;
varying vec4 vColor;
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
void main() {
    float r = min(vRadiusBorder.x, min(vHalfSize.x, vHalfSize.y));
    float d = sdRoundBox(vLocal, vHalfSize, r);
    float alpha;
    if (vRadiusBorder.y > 0.0) {
        alpha = 1.0 - smoothstep(-0.75, 0.75, abs(d) - vRadiusBorder.y * 0.5);
    } else {
        alpha = 1.0 - smoothstep(-0.75, 0.75, d);
    }
    gl_FragColor = vec4(vColor.rgb, vColor.a * alpha);
}
"""

private struct GLProgram {
    var program: UInt32 = 0
    var position: Int32 = 0
    var attribute1: Int32 = 0 // uv or color
    var transform: Int32 = 0
}

private struct GLRectProgram {
    var program: UInt32 = 0
    var position: Int32 = 0
    var local: Int32 = 0
    var halfSize: Int32 = 0
    var radiusBorder: Int32 = 0
    var color: Int32 = 0
    var transform: Int32 = 0
}

private final class GLESTexture: GPUTexture {
    let handle: UInt32

    init(id: Int, handle: UInt32, width: Int, height: Int) {
        self.handle = handle
        super.init(id: id, width: width, height: height)
    }
}

public final class GLESGPUDevice: GPUDevice {
    private var textured = GLProgram()
    private var color = GLProgram()
    private var rect = GLRectProgram()
    private var programsReady = false
    private var nextTextureID = 1
    fileprivate var surfaceHeightPx: Int32 = 0

    public init() {}

    /// The EGL context was lost (GLSurfaceView recreated it): all GL object
    /// handles are dead. Programs rebuild lazily; the consumer must drop
    /// its texture handles (e.g. MapSceneRenderer.reset()).
    public func contextLost() {
        programsReady = false
    }

    // MARK: - GPUDevice

    public func makeTexture(width: Int, height: Int, rgba: [UInt8]) -> GPUTexture {
        var handle: UInt32 = 0
        glGenTextures(1, &handle)
        glBindTexture(GL_TEXTURE_2D, handle)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        rgba.withUnsafeBytes { bytes in
            glTexImage2D(
                GL_TEXTURE_2D, 0, Int32(GL_RGBA), Int32(width), Int32(height),
                0, GL_RGBA, GL_UNSIGNED_BYTE, bytes.baseAddress)
        }
        nextTextureID += 1
        return GLESTexture(id: nextTextureID, handle: handle, width: width, height: height)
    }

    public func destroyTexture(_ texture: GPUTexture) {
        guard let glTexture = texture as? GLESTexture else { return }
        var handle = glTexture.handle
        glDeleteTextures(1, &handle)
    }

    // MARK: - Frames

    /// Render one frame on the current GL context. `widthPx`/`heightPx`
    /// size the viewport in device pixels; the transform matrices map the
    /// caller's logical space to clip space, so logical/pixel scaling is
    /// entirely the caller's concern.
    public func renderFrame(
        widthPx: Int,
        heightPx: Int,
        clear: GPUColor,
        _ body: (GPURenderPass) -> Void
    ) {
        body(beginFrame(widthPx: widthPx, heightPx: heightPx, clear: clear))
        endFrame()
    }

    /// Open-ended frame API (GLSurfaceView presents on return from
    /// onDrawFrame, so endFrame only closes the pass).
    public func beginFrame(widthPx: Int, heightPx: Int, clear: GPUColor) -> GPURenderPass {
        ensurePrograms()
        surfaceHeightPx = Int32(heightPx)
        glViewport(0, 0, Int32(widthPx), Int32(heightPx))
        glClearColor(Float(clear.red), Float(clear.green), Float(clear.blue), Float(clear.alpha))
        glClear(GL_COLOR_BUFFER_BIT)
        return GLESRenderPass(device: self)
    }

    public func endFrame() {
        glDisable(GL_SCISSOR_TEST)
    }

    private func ensurePrograms() {
        guard !programsReady else { return }
        textured = buildProgram(
            vertex: texturedVertexShader,
            fragment: texturedFragmentShader,
            attribute1: "uv"
        )
        color = buildProgram(
            vertex: colorVertexShader,
            fragment: colorFragmentShader,
            attribute1: "color"
        )
        rect = buildRectProgram()
        programsReady = true
    }

    private func buildProgram(vertex: String, fragment: String, attribute1: String) -> GLProgram {
        func compile(_ type: UInt32, _ source: String) -> UInt32 {
            let shader = glCreateShader(type)
            source.withCString { cString in
                var pointer: UnsafePointer<CChar>? = cString
                withUnsafePointer(to: &pointer) { pointers in
                    glShaderSource(shader, 1, pointers, nil)
                }
            }
            glCompileShader(shader)
            return shader
        }
        var result = GLProgram()
        result.program = glCreateProgram()
        glAttachShader(result.program, compile(GL_VERTEX_SHADER, vertex))
        glAttachShader(result.program, compile(GL_FRAGMENT_SHADER, fragment))
        glLinkProgram(result.program)
        result.position = "pos".withCString { glGetAttribLocation(result.program, $0) }
        result.attribute1 = attribute1.withCString { glGetAttribLocation(result.program, $0) }
        result.transform = "transform".withCString { glGetUniformLocation(result.program, $0) }
        return result
    }

    private func buildRectProgram() -> GLRectProgram {
        let base = buildProgram(
            vertex: rectVertexShader,
            fragment: rectFragmentShader,
            attribute1: "color"
        )
        var result = GLRectProgram()
        result.program = base.program
        result.position = base.position
        result.color = base.attribute1
        result.transform = base.transform
        result.local = "localPos".withCString { glGetAttribLocation(base.program, $0) }
        result.halfSize = "halfSize".withCString { glGetAttribLocation(base.program, $0) }
        result.radiusBorder = "radiusBorder".withCString { glGetAttribLocation(base.program, $0) }
        return result
    }

    // MARK: - Draws (invoked by the pass)

    fileprivate func drawTextured(vertices: [Float], texture: GPUTexture, transform: [Float]) {
        guard vertices.count >= 12, let glTexture = texture as? GLESTexture else { return }
        // Premultiplied-alpha blending (opaque content unaffected).
        glEnable(GL_BLEND)
        glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        glUseProgram(textured.program)
        transform.withUnsafeBufferPointer { matrix in
            glUniformMatrix4fv(textured.transform, 1, 0, matrix.baseAddress!)
        }
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, glTexture.handle)
        drawTriangles(program: textured, vertices: vertices, stride: 4, attribute1Size: 2)
        glDisable(GL_BLEND)
    }

    fileprivate func drawColor(vertices: [Float], transform: [Float]) {
        guard vertices.count >= 18 else { return }
        glEnable(GL_BLEND)
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        glUseProgram(color.program)
        transform.withUnsafeBufferPointer { matrix in
            glUniformMatrix4fv(color.transform, 1, 0, matrix.baseAddress!)
        }
        drawTriangles(program: color, vertices: vertices, stride: 6, attribute1Size: 4)
        glDisable(GL_BLEND)
    }

    fileprivate func drawRects(instances: [Float], transform: [Float]) {
        let vertices = expandRectInstances(instances)
        guard !vertices.isEmpty else { return }
        glEnable(GL_BLEND)
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        glUseProgram(rect.program)
        transform.withUnsafeBufferPointer { matrix in
            glUniformMatrix4fv(rect.transform, 1, 0, matrix.baseAddress!)
        }
        let byteStride: Int32 = 12 * 4
        vertices.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            let attributes: [(Int32, Int32, Int)] = [
                (rect.position, 2, 0), (rect.local, 2, 2), (rect.halfSize, 2, 4),
                (rect.radiusBorder, 2, 6), (rect.color, 4, 8),
            ]
            for (location, size, offset) in attributes {
                glEnableVertexAttribArray(UInt32(location))
                glVertexAttribPointer(UInt32(location), size, GL_FLOAT, 0, byteStride, base + offset * 4)
            }
            glDrawArrays(GL_TRIANGLES, 0, Int32(vertices.count / 12))
            for (location, _, _) in attributes {
                glDisableVertexAttribArray(UInt32(location))
            }
        }
        glDisable(GL_BLEND)
    }

    private func drawTriangles(program: GLProgram, vertices: [Float], stride: Int, attribute1Size: Int) {
        let byteStride = Int32(stride * MemoryLayout<Float>.size)
        vertices.withUnsafeBufferPointer { buffer in
            let base = UnsafeRawPointer(buffer.baseAddress!)
            glEnableVertexAttribArray(UInt32(program.position))
            glEnableVertexAttribArray(UInt32(program.attribute1))
            glVertexAttribPointer(UInt32(program.position), 2, GL_FLOAT, 0, byteStride, base)
            glVertexAttribPointer(
                UInt32(program.attribute1), Int32(attribute1Size), GL_FLOAT, 0, byteStride,
                base + 2 * MemoryLayout<Float>.size)
            glDrawArrays(GL_TRIANGLES, 0, Int32(vertices.count / stride))
            glDisableVertexAttribArray(UInt32(program.position))
            glDisableVertexAttribArray(UInt32(program.attribute1))
        }
    }
}

private final class GLESRenderPass: GPURenderPass {
    private let device: GLESGPUDevice
    private var transform: [Float] = [
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
    ]

    init(device: GLESGPUDevice) {
        self.device = device
    }

    func setTransform(_ matrix: [Double]) {
        transform = matrix.map { Float($0) }
    }

    func drawTextured(vertices: [Float], texture: GPUTexture) {
        device.drawTextured(vertices: vertices, texture: texture, transform: transform)
    }

    func drawColor(vertices: [Float]) {
        device.drawColor(vertices: vertices, transform: transform)
    }

    func drawRects(instances: [Float]) {
        device.drawRects(instances: instances, transform: transform)
    }

    func setScissor(x: Int, y: Int, width: Int, height: Int) {
        // GL scissor origin is bottom-left; callers pass top-left px.
        glEnable(GL_SCISSOR_TEST)
        glScissor(Int32(x), device.surfaceHeightPx - Int32(y + height), Int32(width), Int32(height))
    }

    func clearScissor() {
        glDisable(GL_SCISSOR_TEST)
    }
}
