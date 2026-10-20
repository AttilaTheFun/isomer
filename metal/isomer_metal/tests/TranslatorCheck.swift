// Translates Metal shaders to WGSL and checks what comes out: each case's
// entry points must translate, and their WGSL must contain the given lines
// (the spelling that matters: bindings, builtins, conversions). With
// --print the WGSL is printed; tools/metal/validate_wgsl.py feeds that to a
// browser's WebGPU to compile.

import IsomerMetal

struct Case {
    var name: String
    var source: String
    /// Entry point → substrings its WGSL must contain.
    var expectations: [String: [String]]
}

struct Failure {
    var source: String
    /// A substring of the error the translator must report.
    var error: String
}

let swiftGPUShaders = """
#include <metal_stdlib>
using namespace metal;

struct TexVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex TexVSOut tex_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 4;
    TexVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.uv = float2(verts[base + 2], verts[base + 3]);
    return out;
}

fragment float4 tex_fs(
    TexVSOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    return tex.sample(s, in.uv);
}

struct ColorVSOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorVSOut color_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 6;
    ColorVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.color = float4(verts[base + 2], verts[base + 3], verts[base + 4], verts[base + 5]);
    return out;
}

fragment float4 color_fs(ColorVSOut in [[stage_in]]) {
    return in.color;
}

struct RectVSOut {
    float4 position [[position]];
    float2 local;
    float2 halfSize;
    float radius;
    float border;
    float4 color;
};

vertex RectVSOut rect_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 12;
    RectVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.local = float2(verts[base + 2], verts[base + 3]);
    out.halfSize = float2(verts[base + 4], verts[base + 5]);
    out.radius = verts[base + 6];
    out.border = verts[base + 7];
    out.color = float4(verts[base + 8], verts[base + 9], verts[base + 10], verts[base + 11]);
    return out;
}

float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r);
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 rect_fs(RectVSOut in [[stage_in]]) {
    float r = min(in.radius, min(in.halfSize.x, in.halfSize.y));
    float d = sdRoundBox(in.local, in.halfSize, r);
    float alpha;
    if (in.border > 0.0) {
        alpha = 1.0 - smoothstep(-0.75, 0.75, fabs(d) - in.border * 0.5);
    } else {
        alpha = 1.0 - smoothstep(-0.75, 0.75, d);
    }
    return float4(in.color.rgb, in.color.a * alpha);
}
"""

let cases: [Case] = [
    Case(name: "SwiftGPU", source: swiftGPUShaders, expectations: [
        "tex_vs": [
            "@group(0) @binding(0) var<storage, read> verts: array<f32>;",
            "@group(0) @binding(1) var<storage, read> transform: mat4x4<f32>;",
            "@vertex",
            "@builtin(vertex_index) vid: u32",
            "@builtin(position) position: vec4<f32>,",
            "@location(0) uv: vec2<f32>,",
            "var base: u32 = (vid * 4);",
            "verts[(base + 1)]",
        ],
        "tex_fs": [
            "@group(1) @binding(32) var tex: texture_2d<f32>;",
            "@group(1) @binding(64) var s: sampler;",
            "fn tex_fs(in: TexVSOut) -> @location(0) vec4<f32>",
            "return textureSample(tex, s, in.uv);",
        ],
        "color_fs": ["return in.color;"],
        "rect_fs": [
            "fn sdRoundBox(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {",
            "return vec4<f32>(in.color.rgb, (in.color.a * alpha));",
        ],
    ]),
    Case(name: "compute", source: """
        #include <metal_stdlib>
        using namespace metal;

        kernel void add_arrays(device const float* a [[buffer(0)]],
                               device const float* b [[buffer(1)]],
                               device float* result [[buffer(2)]],
                               uint index [[thread_position_in_grid]])
        {
            result[index] = a[index] + b[index];
        }

        kernel void scale(device float *data [[buffer(0)]],
                          constant float &factor [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]],
                          uint2 size [[threads_per_grid]])
        {
            data[gid.y * size.x + gid.x] *= factor;
        }
        """, expectations: [
        "scale": [
            "let size: vec2<u32> = _isomer_grid.xy;",
            "data[((gid.y * size.x) + gid.x)] *= factor;",
        ],
        "add_arrays": [
            "@group(0) @binding(0) var<storage, read> a: array<f32>;",
            "@group(0) @binding(2) var<storage, read_write> result: array<f32>;",
            "@group(1) @binding(0) var<uniform> _isomer_grid: vec3<u32>;",
            "@compute @workgroup_size(_isomer_wg_x, _isomer_wg_y, _isomer_wg_z)",
            "if (any(_isomer_global_invocation_id >= _isomer_grid)) { return; }",
            "result[index] = (a[index] + b[index]);",
        ],
    ]),
    Case(name: "language", source: """
        #include <metal_stdlib>
        using namespace metal;

        #define COUNT 4
        constant float weights[COUNT] = { 0.1, 0.2, 0.3, 0.4 };
        constant int kMode = 2;

        struct Particle {
            float3 position;
            float3 velocity;
            float life;
        };

        struct VertexIn {
            float2 position [[attribute(0)]];
            float4 color [[attribute(1)]];
            uint flags [[attribute(2)]];
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
            uint flags;
        };

        void accumulate(thread float &total, float value) {
            total += value;
        }

        float weighted(float x) {
            float total = 0;
            for (int i = 0; i < COUNT; i++) {
                accumulate(total, weights[i] * x);
            }
            return total;
        }

        vertex VertexOut particle_vs(VertexIn in [[stage_in]],
                                     uint iid [[instance_id]],
                                     const device Particle *particles [[buffer(1)]]) {
            VertexOut out;
            Particle p = particles[iid];
            float2 pos = in.position + p.position.xy;
            pos.yx += float2(0.5, 0.25);
            out.position = float4(pos, 0, 1);
            out.color = in.color;
            out.color.rgb *= p.life > 0.5 ? 1.0 : 0.5;
            out.flags = in.flags;
            return out;
        }

        fragment float4 particle_fs(VertexOut in [[stage_in]]) {
            constexpr sampler linearSampler(filter::linear, address::repeat);
            float4 c = in.color;
            int mode = kMode;
            switch (mode) {
                case 0:
                    c = float4(1);
                    break;
                case 1:
                case 2:
                    c.a = weighted(c.a);
                    break;
                default:
                    break;
            }
            int n = 0;
            do {
                n++;
            } while (n < 3);
            if (in.flags & 1) {
                discard_fragment();
            }
            return c * (float)n;
        }

        kernel void update(device Particle *particles [[buffer(0)]],
                           constant float &dt [[buffer(1)]],
                           texture2d<float, access::write> output [[texture(0)]],
                           uint id [[thread_position_in_grid]]) {
            device Particle &p = particles[id];
            p.position += p.velocity * dt;
            p.life = max(p.life - dt, 0.0f);
            output.write(float4(p.life), uint2(id, 0));
        }
        """, expectations: [
        "particle_vs": [
            "@location(0) position: vec2<f32>,",
            "@location(2) flags: u32,",
            "@location(1) @interpolate(flat) flags: u32,",
            "@size(16) position: vec3<f32>,",
            "@builtin(instance_index) iid: u32",
            "var<storage, read> particles: array<Particle>;",
        ],
        "particle_fs": [
            "const kMode: i32 = 2;",
            "var<private> weights: array<f32, 4>",
            "fn accumulate(total: ptr<function, f32>, value: f32) {",
            "accumulate(&total, (weights[i] * x));",
            "loop {",
            "break if !((n < 3));",
            "discard;",
            "case 1, 2: {",
            "@group(1) @binding(96) var _isomer_sampler_linearSampler: sampler;",
        ],
        "update": [
            "var<storage, read_write> particles: array<Particle>;",
            "@group(0) @binding(32) var output: texture_storage_2d<rgba8unorm, write>;",
            "textureStore(output,",
        ],
    ]),
]

let failures: [Failure] = [
    Failure(source: """
        vertex float4 v(device float *out [[buffer(0)]]) { out[0] = 1.0; return float4(0); }
        """, error: "cannot write a buffer"),
    Failure(source: """
        #if FOO
        #endif
        """, error: "#if"),
    Failure(source: """
        fragment float4 f(packed_float3 x [[stage_in]]) { return float4(0); }
        """, error: "packed"),
]

@main
enum TranslatorCheck {
    static func main() {
        let printWGSL = CommandLine.arguments.contains("--print")
        var failed = 0

        for testCase in cases {
            do {
                let translator = try MSLTranslator(source: testCase.source)
                for (name, _) in translator.entryPoints {
                    let translated = try translator.translate(entryPoint: name)
                    if printWGSL {
                        print("// ===== \(testCase.name) / \(name)")
                        print(translated.wgsl)
                        print("// reflection: \(translated.reflectionJSON)")
                    }
                    for expected in testCase.expectations[name] ?? [] {
                        if !translated.wgsl.contains(expected) {
                            print("FAIL \(testCase.name)/\(name): missing \(expected)")
                            failed += 1
                        }
                    }
                }
            } catch {
                print("FAIL \(testCase.name): \(error)")
                failed += 1
            }
        }

        for failure in failures {
            do {
                let translator = try MSLTranslator(source: failure.source)
                _ = try translator.translateAll()
                print("FAIL expected an error containing '\(failure.error)'")
                failed += 1
            } catch {
                if !"\(error)".contains(failure.error) {
                    print("FAIL expected an error containing '\(failure.error)', got: \(error)")
                    failed += 1
                }
            }
        }

        if failed == 0 && !printWGSL { print("ok") }
        if printWGSL && failed == 0 { print("// ok") }
    }
}
