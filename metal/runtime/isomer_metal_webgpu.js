// Isomer's Metal on WebGPU: performs the command streams Isomer's `Metal`
// module records (metal/isomer_metal/backend/MetalCommands.swift is the
// format; keep the two in step). This and swift_gpu's executor are the
// only code that touches navigator.gpu.
//
// Usage (before the app makes its Metal device):
//   const metalHost = await createIsomerMetalHost(canvas);
//   metalHost.connect(bridge);
//
// What Metal sets while encoding and WebGPU fixes in a pipeline (the
// primitive type, cull mode and winding, depth-stencil state, depth bias)
// picks a variant of the pipeline, made when first drawn with. Shaders'
// resources are bound by the scheme of the translator (ShaderReflection
// .swift): group 0 a vertex or kernel function's, group 1 a fragment
// function's (or a kernel's grid size).

const PIXEL_FORMATS = {
  10: "r8unorm", 12: "r8snorm", 13: "r8uint", 14: "r8sint",
  20: "r16unorm", 22: "r16snorm", 23: "r16uint", 24: "r16sint", 25: "r16float",
  30: "rg8unorm", 32: "rg8snorm", 33: "rg8uint", 34: "rg8sint",
  53: "r32uint", 54: "r32sint", 55: "r32float",
  60: "rg16unorm", 62: "rg16snorm", 63: "rg16uint", 64: "rg16sint", 65: "rg16float",
  70: "rgba8unorm", 71: "rgba8unorm-srgb", 72: "rgba8snorm", 73: "rgba8uint", 74: "rgba8sint",
  80: "bgra8unorm", 81: "bgra8unorm-srgb",
  90: "rgb10a2unorm", 91: "rgb10a2uint", 92: "rg11b10ufloat", 93: "rgb9e5ufloat",
  103: "rg32uint", 104: "rg32sint", 105: "rg32float",
  110: "rgba16unorm", 112: "rgba16snorm", 113: "rgba16uint", 114: "rgba16sint", 115: "rgba16float",
  123: "rgba32uint", 124: "rgba32sint", 125: "rgba32float",
  250: "depth16unorm", 252: "depth32float", 253: "stencil8", 255: "depth24plus-stencil8",
  260: "depth32float-stencil8",
};

const BYTES_PER_PIXEL = {
  10: 1, 12: 1, 13: 1, 14: 1, 20: 2, 22: 2, 23: 2, 24: 2, 25: 2, 30: 2, 32: 2, 33: 2, 34: 2,
  53: 4, 54: 4, 55: 4, 60: 4, 62: 4, 63: 4, 64: 4, 65: 4, 70: 4, 71: 4, 72: 4, 73: 4, 74: 4,
  80: 4, 81: 4, 90: 4, 91: 4, 92: 4, 93: 4, 103: 8, 104: 8, 105: 8, 110: 8, 112: 8, 113: 8,
  114: 8, 115: 8, 123: 16, 124: 16, 125: 16, 252: 4, 253: 1,
};

const VERTEX_FORMATS = {
  1: "uint8x2", 3: "uint8x4", 4: "sint8x2", 6: "sint8x4", 7: "unorm8x2", 9: "unorm8x4",
  10: "snorm8x2", 12: "snorm8x4", 13: "uint16x2", 15: "uint16x4", 16: "sint16x2", 18: "sint16x4",
  19: "unorm16x2", 21: "unorm16x4", 22: "snorm16x2", 24: "snorm16x4", 25: "float16x2", 27: "float16x4",
  28: "float32", 29: "float32x2", 30: "float32x3", 31: "float32x4", 32: "sint32", 33: "sint32x2",
  34: "sint32x3", 35: "sint32x4", 36: "uint32", 37: "uint32x2", 38: "uint32x3", 39: "uint32x4",
  41: "unorm10-10-10-2", 42: "unorm8x4-bgra", 45: "uint8", 46: "sint8", 47: "unorm8", 48: "snorm8",
  49: "uint16", 50: "sint16", 51: "unorm16", 52: "snorm16", 53: "float16",
};

const BLEND_FACTORS = [
  "zero", "one", "src", "one-minus-src", "src-alpha", "one-minus-src-alpha", "dst", "one-minus-dst",
  "dst-alpha", "one-minus-dst-alpha", "src-alpha-saturated", "constant", "one-minus-constant",
  "constant", "one-minus-constant", "src1", "one-minus-src1", "src1-alpha", "one-minus-src1-alpha",
];
const BLEND_OPERATIONS = ["add", "subtract", "reverse-subtract", "min", "max"];
const COMPARE = ["never", "less", "equal", "less-equal", "greater", "not-equal", "greater-equal", "always"];
const STENCIL_OPERATIONS = [
  "keep", "zero", "replace", "increment-clamp", "decrement-clamp", "invert", "increment-wrap", "decrement-wrap",
];
const TOPOLOGIES = ["point-list", "line-list", "line-strip", "triangle-list", "triangle-strip"];
const CULL_MODES = ["none", "front", "back"];
const ADDRESS_MODES = ["clamp-to-edge", "mirror-repeat", "repeat", "mirror-repeat", "clamp-to-edge", "clamp-to-edge"];
const VIEW_DIMENSIONS = {
  texture1d: "1d", texture1dArray: "2d-array", texture2d: "2d", texture2dArray: "2d-array",
  texture2dMS: "2d", texture3d: "3d", textureCube: "cube", textureCubeArray: "cube-array",
  depth2d: "2d", depth2dArray: "2d-array", depth2dMS: "2d", depthCube: "cube",
};
// MTLTextureType → the view a shader binds.
const TYPE_VIEW = ["1d", "2d-array", "2d", "2d-array", "2d", "cube", "cube-array", "3d", "2d-array", "1d"];
const ARENA = -2;
const OPTIONAL_FEATURES = [
  "depth32float-stencil8", "float32-filterable", "rg11b10ufloat-renderable", "bgra8unorm-storage",
  "dual-source-blending", "texture-compression-bc", "unorm16-texture-formats", "snorm16-texture-formats",
];

const MIPMAP_SHADER = /* wgsl */ `
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var linear: sampler;
struct Out { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> Out {
  let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
  return Out(vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0), vec2<f32>(p.x, 1.0 - p.y));
}
@fragment fn fs(in: Out) -> @location(0) vec4<f32> {
  return textureSampleLevel(source, linear, in.uv, 0.0);
}`;

/** Makes the executor for a canvas (surface 1). */
export async function createIsomerMetalHost(canvas, { powerPreference = "high-performance", alphaMode = "opaque" } = {}) {
  const adapter = await navigator.gpu?.requestAdapter({ powerPreference });
  if (!adapter) throw new Error("WebGPU unavailable");
  const requiredFeatures = OPTIONAL_FEATURES.filter((f) => adapter.features.has(f));
  const device = await adapter.requestDevice({ requiredFeatures });
  const executor = new Executor(device, adapter, alphaMode);
  if (canvas) executor.addSurface(1, canvas);
  const host = {
    metalPerform(commands, token) { executor.perform(commands, token); },
    metalSurfaceWidth(surface) { return executor.surfaces.get(surface)?.canvas.width ?? 0; },
    metalSurfaceHeight(surface) { return executor.surfaces.get(surface)?.canvas.height ?? 0; },
    metalAdapterName() {
      const info = adapter.info || {};
      return info.description || [info.vendor, info.architecture].filter(Boolean).join(" ") || "WebGPU";
    },
    /** Hands the executor to the app (its swift_ffi bridge). */
    connect(bridge) {
      executor.bridge = bridge;
      bridge.metalConnect(host);
    },
    /** Another canvas: its surface number, for IsomerMetalLayer(surface:). */
    addSurface(otherCanvas) {
      const id = ++executor.lastSurface;
      executor.addSurface(id, otherCanvas);
      return id;
    },
    /** A canvas the page no longer draws to. */
    removeSurface(id) {
      executor.surfaces.delete(id);
    },
    device,
  };
  return host;
}

class Reader {
  constructor(bytes) {
    if (bytes.byteOffset % 4 !== 0) bytes = bytes.slice();
    this.bytes = bytes;
    this.ints = new Int32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength >> 2);
    this.floats = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength >> 2);
    this.position = 0;
  }
  get done() { return this.position >= this.ints.length; }
  int() { return this.ints[this.position++]; }
  uint() { return this.ints[this.position++] >>> 0; }
  float() { return this.floats[this.position++]; }
  data() {
    const count = this.int();
    const start = this.position * 4;
    this.position += (count + 3) >> 2;
    return this.bytes.subarray(start, start + count);
  }
  string() { return new TextDecoder().decode(this.data()); }
}

class Executor {
  constructor(device, adapter, alphaMode) {
    this.device = device;
    this.queue = device.queue;
    this.alphaMode = alphaMode;
    this.objects = new Map();
    this.surfaces = new Map();
    this.lastSurface = 1;
    this.samplerCache = new Map();
    this.warned = new Set();
    this.arena = null;
    this.gridArena = null;
    this.bridge = null;
    this.mipmapPipelines = new Map();
    device.addEventListener?.("uncapturederror", (event) => this.warn(event.error?.message || String(event.error)));
  }

  warn(message) {
    if (this.warned.has(message) || this.warned.size > 100) return;
    this.warned.add(message);
    console.warn("[isomer metal]", message);
  }

  addSurface(id, canvas) {
    const context = canvas.getContext("webgpu");
    this.surfaces.set(id, { canvas, context, format: null });
  }

  // MARK: Streams

  perform(bytes, token) {
    const reader = new Reader(bytes);
    const frame = { encoder: null, pass: null, kind: null, state: null, reads: [], bindGroups: new Map(), gridOffset: 0 };
    this.device.pushErrorScope("validation");
    while (!reader.done) {
      const opcode = reader.uint();
      const handler = this.handlers[opcode];
      if (!handler) {
        this.warn(`unknown command ${opcode}`);
        break;
      }
      handler.call(this, reader, frame);
    }
    if (frame.pass) frame.pass.end();
    const staging = [];
    if (frame.reads.length) {
      frame.encoder ??= this.device.createCommandEncoder();
      for (const read of frame.reads) staging.push(this.encodeRead(frame.encoder, read));
    }
    if (frame.encoder) this.queue.submit([frame.encoder.finish()]);
    this.device.popErrorScope().then((error) => { if (error) this.warn(error.message); });
    if (!token) return;
    const done = staging.length
      ? Promise.all(staging.filter(Boolean).map((s) => s.buffer.mapAsync(GPUMapMode.READ).then(() => s)))
      : this.queue.onSubmittedWorkDone().then(() => []);
    done.then((results) => {
      this.bridge?.metalCompleted(token, this.readbackBytes(results));
    }).catch((error) => {
      this.warn(`readback failed: ${error}`);
      this.bridge?.metalCompleted(token, new Uint8Array(0));
    });
  }

  ensureEncoder(frame) {
    frame.encoder ??= this.device.createCommandEncoder();
    return frame.encoder;
  }

  endPass(frame) {
    if (frame.pass) frame.pass.end();
    frame.pass = null;
    frame.kind = null;
    frame.state = null;
  }

  // MARK: Resources

  buffer(id) {
    if (id === ARENA) return this.arena;
    return this.objects.get(id)?.buffer;
  }

  textureView(id, level = 0, slice = 0, depthPlane = 0) {
    const object = this.objects.get(id);
    if (!object) return null;
    if (object.drawable) return object.texture.createView();
    if (object.view && level === 0 && slice === 0) return object.view;
    return object.texture.createView({
      dimension: object.type === 7 ? "3d" : "2d",
      baseMipLevel: level + (object.baseLevel || 0), mipLevelCount: 1,
      baseArrayLayer: object.type === 7 ? 0 : slice + (object.baseSlice || 0), arrayLayerCount: 1,
    });
  }

  makeTexture(id, type, format, width, height, depth, layers, levels, samples, usage) {
    const gpuFormat = PIXEL_FORMATS[format];
    if (!gpuFormat) {
      this.warn(`pixel format ${format} is not supported on WebGPU`);
      return;
    }
    const isDepth = format >= 250;
    let gpuUsage = GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING;
    if (usage & 2 && !isDepth) gpuUsage |= GPUTextureUsage.STORAGE_BINDING;
    if (usage & 4 || (levels > 1 && !isDepth)) gpuUsage |= GPUTextureUsage.RENDER_ATTACHMENT;
    if (samples > 1) gpuUsage = GPUTextureUsage.RENDER_ATTACHMENT | (usage & 1 ? GPUTextureUsage.TEXTURE_BINDING : 0);
    const texture = this.device.createTexture({
      dimension: type === 7 ? "3d" : type === 0 || type === 9 ? "1d" : "2d",
      size: { width, height: type === 0 || type === 9 ? 1 : height, depthOrArrayLayers: type === 7 ? depth : layers },
      format: gpuFormat, mipLevelCount: levels, sampleCount: samples, usage: gpuUsage,
    });
    const viewDimension = TYPE_VIEW[type];
    const view = texture.createView({ dimension: viewDimension });
    this.objects.set(id, { kind: "texture", texture, view, type, format, width, height, depth, layers, levels });
  }

  handlers = {
    // createBuffer: id, length, storage mode
    1(r) {
      const id = r.int(), length = r.int();
      r.int();
      const buffer = this.device.createBuffer({
        size: Math.max(4, (length + 3) & ~3),
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.VERTEX | GPUBufferUsage.INDEX | GPUBufferUsage.UNIFORM
          | GPUBufferUsage.INDIRECT | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST,
      });
      this.objects.set(id, { kind: "buffer", buffer, length });
    },
    // writeBuffer: id, offset, bytes
    2(r) {
      const id = r.int(), offset = r.int(), data = r.data();
      const buffer = this.buffer(id);
      if (buffer && data.length) this.queue.writeBuffer(buffer, offset, data, 0, Math.min(data.length, buffer.size - offset) & ~3);
    },
    // createTexture
    3(r) {
      const id = r.int(), type = r.int(), format = r.int(), width = r.int(), height = r.int(), depth = r.int();
      const layers = r.int(), levels = r.int(), samples = r.int(), usage = r.int();
      this.makeTexture(id, type, format, width, height, depth, layers, levels, samples, usage);
    },
    // writeTexture
    4(r) {
      const id = r.int(), level = r.int(), slice = r.int(), x = r.int(), y = r.int(), z = r.int();
      const width = r.int(), height = r.int(), depth = r.int(), bytesPerRow = r.int(), bytesPerImage = r.int();
      const data = r.data();
      const object = this.objects.get(id);
      if (!object) return;
      this.queue.writeTexture(
        { texture: object.texture, mipLevel: level, origin: { x, y, z: object.type === 7 ? z : slice } },
        data, { bytesPerRow, rowsPerImage: Math.max(1, Math.floor(bytesPerImage / Math.max(bytesPerRow, 1))) },
        { width, height, depthOrArrayLayers: depth },
      );
    },
    // createSampler
    5(r) {
      const id = r.int(), min = r.int(), mag = r.int(), mip = r.int(), s = r.int(), t = r.int(), rr = r.int();
      const compare = r.int(), anisotropy = r.int(), lodMin = r.float(), lodMax = r.float();
      r.int();
      const filtering = min === 1 && mag === 1 && mip === 2;
      const sampler = this.device.createSampler({
        minFilter: min ? "linear" : "nearest", magFilter: mag ? "linear" : "nearest",
        mipmapFilter: mip === 2 ? "linear" : "nearest",
        addressModeU: ADDRESS_MODES[s], addressModeV: ADDRESS_MODES[t], addressModeW: ADDRESS_MODES[rr],
        compare: compare >= 0 ? COMPARE[compare] : undefined,
        maxAnisotropy: filtering ? Math.max(1, Math.min(anisotropy, 16)) : 1,
        lodMinClamp: lodMin, lodMaxClamp: mip === 0 ? lodMin : lodMax,
      });
      this.objects.set(id, { kind: "sampler", sampler });
    },
    // createShader: id, WGSL, reflection
    6(r) {
      const id = r.int(), code = r.string(), reflection = JSON.parse(r.string());
      const module = this.device.createShaderModule({ code });
      module.getCompilationInfo?.().then((info) => {
        for (const m of info.messages) if (m.type === "error") this.warn(`${reflection.entry}: ${m.lineNum}:${m.linePos} ${m.message}`);
      });
      this.objects.set(id, { kind: "shader", module, reflection });
    },
    // createRenderPipeline: id, descriptor JSON
    7(r) {
      const id = r.int(), descriptor = JSON.parse(r.string());
      const vertex = this.objects.get(descriptor.vertex);
      const fragment = descriptor.fragment != null ? this.objects.get(descriptor.fragment) : null;
      const layouts = [
        this.bindGroupLayout(vertex.reflection.bindings.filter((b) => b.group === 0), GPUShaderStage.VERTEX),
        this.bindGroupLayout(fragment ? fragment.reflection.bindings.filter((b) => b.group === 1) : [], GPUShaderStage.FRAGMENT),
      ];
      const layout = this.device.createPipelineLayout({ bindGroupLayouts: layouts });
      this.objects.set(id, { kind: "render", descriptor, vertex, fragment, layouts, layout, variants: new Map() });
    },
    // createComputePipeline: id, shader
    8(r) {
      const id = r.int(), shader = this.objects.get(r.int());
      const layouts = [
        this.bindGroupLayout(shader.reflection.bindings.filter((b) => b.group === 0), GPUShaderStage.COMPUTE),
        this.bindGroupLayout(shader.reflection.bindings.filter((b) => b.group === 1), GPUShaderStage.COMPUTE),
      ];
      const layout = this.device.createPipelineLayout({ bindGroupLayouts: layouts });
      this.objects.set(id, { kind: "compute", shader, layouts, layout, variants: new Map() });
    },
    // destroy: id
    9(r) {
      const id = r.int();
      const object = this.objects.get(id);
      if (!object) return;
      if (object.kind === "buffer") object.buffer.destroy();
      if (object.kind === "texture" && !object.drawable && !object.isView) object.texture.destroy();
      this.objects.delete(id);
    },
    // createTextureView
    10(r) {
      const id = r.int(), source = this.objects.get(r.int()), format = r.int(), type = r.int();
      const baseLevel = r.int(), levels = r.int(), baseSlice = r.int(), slices = r.int();
      if (!source) return;
      const view = source.texture.createView({
        format: PIXEL_FORMATS[format], dimension: TYPE_VIEW[type],
        baseMipLevel: baseLevel, mipLevelCount: levels, baseArrayLayer: baseSlice, arrayLayerCount: slices,
      });
      this.objects.set(id, { ...source, view, type, format, baseLevel, baseSlice, isView: true });
    },
    // writeArena: bytes
    11(r) {
      const data = r.data();
      const size = (data.length + 255) & ~255;
      if (!this.arena || this.arena.size < size) {
        this.arena?.destroy();
        this.arena = this.device.createBuffer({
          size: Math.max(size * 2, 64 << 10),
          usage: GPUBufferUsage.STORAGE | GPUBufferUsage.VERTEX | GPUBufferUsage.INDEX | GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });
      }
      this.queue.writeBuffer(this.arena, 0, data, 0, data.length & ~3);
    },

    // MARK: Render passes

    20(r, frame) {
      this.endPass(frame);
      const colorCount = r.int();
      const colorAttachments = [];
      const formats = [];
      let sampleCount = 1;
      for (let i = 0; i < colorCount; i++) {
        const id = r.int(), level = r.int(), slice = r.int(), depthPlane = r.int(), load = r.int(), store = r.int();
        const clearValue = { r: r.float(), g: r.float(), b: r.float(), a: r.float() };
        const resolve = r.int(), resolveLevel = r.int(), resolveSlice = r.int();
        const object = this.objects.get(id);
        if (id < 0 || !object) { colorAttachments.push(null); formats.push(null); continue; }
        sampleCount = object.texture.sampleCount || 1;
        const attachment = {
          view: this.textureView(id, level, slice), loadOp: load === 1 ? "load" : "clear", clearValue,
          storeOp: store === 1 || store === 3 || store === 4 ? "store" : "discard",
        };
        if (object.type === 7) attachment.depthSlice = depthPlane;
        if (resolve >= 0 && (store === 2 || store === 3)) attachment.resolveTarget = this.textureView(resolve, resolveLevel, resolveSlice);
        colorAttachments.push(attachment);
        formats.push(object.texture.format);
      }
      const depthID = r.int(), depthLevel = r.int(), depthSlice = r.int(), depthLoad = r.int(), depthStore = r.int(), clearDepth = r.float();
      const stencilID = r.int(), stencilLevel = r.int(), stencilSlice = r.int(), stencilLoad = r.int(), stencilStore = r.int(), clearStencil = r.uint();
      const width = r.int(), height = r.int();
      let depthStencilAttachment;
      let depthFormat = null;
      const depthObject = this.objects.get(depthID >= 0 ? depthID : stencilID);
      if (depthObject) {
        const format = depthObject.texture.format;
        depthFormat = format;
        sampleCount = depthObject.texture.sampleCount || sampleCount;
        depthStencilAttachment = { view: this.textureView(depthID >= 0 ? depthID : stencilID, depthID >= 0 ? depthLevel : stencilLevel, depthID >= 0 ? depthSlice : stencilSlice) };
        if (format.startsWith("depth")) {
          Object.assign(depthStencilAttachment, {
            depthLoadOp: depthLoad === 1 ? "load" : "clear", depthStoreOp: depthStore === 1 || depthStore === 3 ? "store" : "discard",
            depthClearValue: clearDepth,
          });
        }
        if (format.includes("stencil")) {
          Object.assign(depthStencilAttachment, {
            stencilLoadOp: stencilLoad === 1 ? "load" : "clear", stencilStoreOp: stencilStore === 1 ? "store" : "discard",
            stencilClearValue: clearStencil,
          });
        }
      }
      frame.pass = this.ensureEncoder(frame).beginRenderPass({ colorAttachments, depthStencilAttachment });
      frame.kind = "render";
      frame.state = {
        width, height, pipeline: null, variant: null, buffers: [new Map(), new Map()], textures: [new Map(), new Map()],
        samplers: [new Map(), new Map()], cull: 0, winding: 0, depthStencil: null, depthBias: null, formats, depthFormat, sampleCount,
      };
    },
    // endEncoding
    21(r, frame) { this.endPass(frame); },
    // setRenderPipeline
    22(r, frame) { frame.state.pipeline = this.objects.get(r.int()); },
    // setBuffer: stage, index, id, offset
    23(r, frame) {
      const stage = r.int(), index = r.int(), id = r.int(), offset = r.int();
      frame.state.buffers[stage === 2 ? 0 : stage].set(index, { id, offset });
    },
    // setTexture
    24(r, frame) {
      const stage = r.int(), index = r.int(), id = r.int();
      frame.state.textures[stage === 2 ? 0 : stage].set(index, id);
    },
    // setSampler
    25(r, frame) {
      const stage = r.int(), index = r.int(), id = r.int();
      frame.state.samplers[stage === 2 ? 0 : stage].set(index, id);
    },
    // setViewport
    26(r, frame) {
      const x = r.float(), y = r.float(), w = r.float(), h = r.float(), near = r.float(), far = r.float();
      frame.pass.setViewport(x, y, Math.max(w, 0), Math.max(h, 0), Math.min(Math.max(near, 0), 1), Math.min(Math.max(far, 0), 1));
    },
    // setScissor
    27(r, frame) {
      const { width, height } = frame.state;
      const x = Math.min(Math.max(r.int(), 0), width), y = Math.min(Math.max(r.int(), 0), height);
      const w = Math.min(Math.max(r.int(), 0), width - x), h = Math.min(Math.max(r.int(), 0), height - y);
      frame.pass.setScissorRect(x, y, w, h);
    },
    28(r, frame) { frame.state.cull = r.int(); },
    29(r, frame) { frame.state.winding = r.int(); },
    // setDepthStencil
    30(r, frame) {
      const depthCompare = r.int(), depthWrite = r.int();
      const face = () => ({ compare: r.int(), fail: r.int(), depthFail: r.int(), pass: r.int(), readMask: r.uint(), writeMask: r.uint() });
      const front = face(), back = face();
      frame.state.depthStencil = { depthCompare, depthWrite, front, back };
    },
    31(r, frame) { frame.pass.setBlendConstant({ r: r.float(), g: r.float(), b: r.float(), a: r.float() }); },
    32(r, frame) {
      const front = r.uint();
      r.uint();
      frame.pass.setStencilReference(front);
    },
    // draw: primitive, start, count, instances, base instance
    33(r, frame) {
      const primitive = r.int(), start = r.int(), count = r.int(), instances = r.int(), baseInstance = r.int();
      if (this.prepareDraw(frame, primitive, null)) frame.pass.draw(count, instances, start, baseInstance);
    },
    // drawIndexed
    34(r, frame) {
      const primitive = r.int(), count = r.int(), indexType = r.int(), indexBuffer = r.int(), indexOffset = r.int();
      const instances = r.int(), baseVertex = r.int(), baseInstance = r.int();
      const format = indexType === 0 ? "uint16" : "uint32";
      if (!this.prepareDraw(frame, primitive, format)) return;
      const buffer = this.buffer(indexBuffer);
      if (!buffer) return;
      frame.pass.setIndexBuffer(buffer, format, indexOffset);
      frame.pass.drawIndexed(count, instances, 0, baseVertex, baseInstance);
    },
    35(r, frame) { frame.state.depthBias = { bias: r.float(), slope: r.float(), clamp: r.float() }; },
    36(r) {
      if (r.int() === 1) this.warn("triangle fill mode .lines is not supported on WebGPU");
    },

    // MARK: Compute passes

    40(r, frame) {
      this.endPass(frame);
      frame.pass = this.ensureEncoder(frame).beginComputePass();
      frame.kind = "compute";
      frame.state = { pipeline: null, buffers: [new Map()], textures: [new Map()], samplers: [new Map()] };
    },
    41(r, frame) { frame.state.pipeline = this.objects.get(r.int()); },
    // dispatch: groups, threads per group, grid
    42(r, frame) {
      const gx = r.int(), gy = r.int(), gz = r.int(), tx = r.int(), ty = r.int(), tz = r.int();
      const grid = [r.int(), r.int(), r.int()];
      const pipeline = frame.state.pipeline;
      if (!pipeline) return;
      const key = `${tx},${ty},${tz}`;
      let variant = pipeline.variants.get(key);
      if (!variant) {
        const constants = {};
        if (pipeline.shader.reflection.workgroupOverrides) Object.assign(constants, { _isomer_wg_x: tx, _isomer_wg_y: ty, _isomer_wg_z: tz });
        variant = this.device.createComputePipeline({
          layout: pipeline.layout, compute: { module: pipeline.shader.module, entryPoint: pipeline.shader.reflection.entry, constants },
        });
        pipeline.variants.set(key, variant);
      }
      frame.pass.setPipeline(variant);
      const bindings = pipeline.shader.reflection.bindings;
      const group0 = this.bindGroup(frame, pipeline.layouts[0], bindings.filter((b) => b.group === 0), 0);
      if (group0 === false) return;
      frame.pass.setBindGroup(0, group0);
      const gridBindings = bindings.filter((b) => b.group === 1);
      if (gridBindings.length) {
        const offset = this.writeGrid(frame, grid);
        frame.pass.setBindGroup(1, this.device.createBindGroup({
          layout: pipeline.layouts[1], entries: [{ binding: 0, resource: { buffer: this.gridArena, offset, size: 16 } }],
        }));
      } else {
        frame.pass.setBindGroup(1, this.device.createBindGroup({ layout: pipeline.layouts[1], entries: [] }));
      }
      frame.pass.dispatchWorkgroups(gx, gy, gz);
    },

    // MARK: Blit passes

    50(r, frame) { this.endPass(frame); this.ensureEncoder(frame); frame.kind = "blit"; },
    // copyBufferToBuffer
    51(r, frame) {
      const source = this.buffer(r.int()), sourceOffset = r.int(), destination = this.buffer(r.int());
      const destinationOffset = r.int(), size = r.int();
      if (source && destination) frame.encoder.copyBufferToBuffer(source, sourceOffset, destination, destinationOffset, (size + 3) & ~3);
    },
    // copyBufferToTexture
    52(r, frame) {
      const buffer = this.buffer(r.int()), offset = r.int(), bytesPerRow = r.int(), bytesPerImage = r.int();
      const width = r.int(), height = r.int(), depth = r.int();
      const texture = this.objects.get(r.int()), slice = r.int(), level = r.int(), x = r.int(), y = r.int(), z = r.int();
      if (!buffer || !texture) return;
      const rowsPerImage = Math.max(1, Math.floor(bytesPerImage / Math.max(bytesPerRow, 1)));
      const destination = (row) => ({ texture: texture.texture, mipLevel: level, origin: { x, y: y + row, z: texture.type === 7 ? z : slice } });
      if (bytesPerRow % 256 === 0 || height === 1) {
        frame.encoder.copyBufferToTexture({ buffer, offset, bytesPerRow, rowsPerImage }, destination(0), { width, height, depthOrArrayLayers: depth });
      } else {
        for (let row = 0; row < height; row++) {
          frame.encoder.copyBufferToTexture({ buffer, offset: offset + row * bytesPerRow }, destination(row), { width, height: 1, depthOrArrayLayers: 1 });
        }
      }
    },
    // copyTextureToBuffer
    53(r, frame) {
      const texture = this.objects.get(r.int()), slice = r.int(), level = r.int(), x = r.int(), y = r.int(), z = r.int();
      const width = r.int(), height = r.int(), depth = r.int();
      const buffer = this.buffer(r.int()), offset = r.int(), bytesPerRow = r.int(), bytesPerImage = r.int();
      if (!buffer || !texture) return;
      const rowsPerImage = Math.max(1, Math.floor(bytesPerImage / Math.max(bytesPerRow, 1)));
      const source = (row) => ({ texture: texture.texture, mipLevel: level, origin: { x, y: y + row, z: texture.type === 7 ? z : slice } });
      if (bytesPerRow % 256 === 0 || height === 1) {
        frame.encoder.copyTextureToBuffer(source(0), { buffer, offset, bytesPerRow, rowsPerImage }, { width, height, depthOrArrayLayers: depth });
      } else {
        for (let row = 0; row < height; row++) {
          frame.encoder.copyTextureToBuffer(source(row), { buffer, offset: offset + row * bytesPerRow }, { width, height: 1, depthOrArrayLayers: 1 });
        }
      }
    },
    // copyTextureToTexture
    54(r, frame) {
      const source = this.objects.get(r.int()), sourceSlice = r.int(), sourceLevel = r.int();
      const sx = r.int(), sy = r.int(), sz = r.int(), width = r.int(), height = r.int(), depth = r.int();
      const destination = this.objects.get(r.int()), destinationSlice = r.int(), destinationLevel = r.int();
      const dx = r.int(), dy = r.int(), dz = r.int();
      if (!source || !destination) return;
      frame.encoder.copyTextureToTexture(
        { texture: source.texture, mipLevel: sourceLevel, origin: { x: sx, y: sy, z: source.type === 7 ? sz : sourceSlice } },
        { texture: destination.texture, mipLevel: destinationLevel, origin: { x: dx, y: dy, z: destination.type === 7 ? dz : destinationSlice } },
        { width, height, depthOrArrayLayers: depth },
      );
    },
    // fillBuffer
    55(r, frame) {
      const buffer = this.buffer(r.int()), offset = r.int(), length = r.int(), value = r.int();
      if (!buffer) return;
      if (value === 0 && offset % 4 === 0 && length % 4 === 0) {
        frame.encoder.clearBuffer(buffer, offset, length);
        return;
      }
      const size = (length + 3) & ~3;
      const fill = this.device.createBuffer({ size, usage: GPUBufferUsage.COPY_SRC, mappedAtCreation: true });
      new Uint8Array(fill.getMappedRange()).fill(value);
      fill.unmap();
      frame.encoder.copyBufferToBuffer(fill, 0, buffer, offset & ~3, size);
    },
    // generateMipmaps
    56(r, frame) {
      const texture = this.objects.get(r.int());
      if (texture) this.generateMipmaps(frame.encoder, texture);
    },

    // MARK: Readback

    60(r, frame) { frame.reads.push({ kind: 1, id: r.int() }); },
    61(r, frame) { frame.reads.push({ kind: 2, id: r.int(), slice: r.int(), level: r.int() }); },

    // MARK: Surfaces

    // acquireDrawable: surface, id, pixel format
    70(r) {
      const surfaceID = r.int(), id = r.int(), format = r.int();
      const surface = this.surfaces.get(surfaceID);
      if (!surface) return;
      const gpuFormat = PIXEL_FORMATS[format] || "bgra8unorm";
      if (surface.format !== gpuFormat) {
        surface.context.configure({ device: this.device, format: gpuFormat, alphaMode: this.alphaMode, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST });
        surface.format = gpuFormat;
      }
      const texture = surface.context.getCurrentTexture();
      this.objects.set(id, { kind: "texture", texture, type: 2, format, drawable: true, width: texture.width, height: texture.height });
    },
    // present: the browser presents the canvas when the task ends.
    71(r) { r.int(); r.int(); },
  };

  // MARK: Pipelines and bindings

  bindGroupLayout(bindings, visibility) {
    const entries = bindings.map((b) => {
      const entry = { binding: b.binding, visibility };
      switch (b.kind) {
        case "read-only-storage": entry.buffer = { type: visibility === GPUShaderStage.VERTEX || b.kind === "read-only-storage" ? "read-only-storage" : "storage" }; break;
        case "storage": entry.buffer = { type: "storage" }; break;
        case "uniform": case "grid": entry.buffer = { type: "uniform" }; break;
        case "texture":
          entry.texture = {
            sampleType: b.sampleType === "depth" ? "depth" : b.sampleType === "float" ? "float" : b.sampleType,
            viewDimension: VIEW_DIMENSIONS[b.dimension] || "2d", multisampled: b.dimension === "texture2dMS" || b.dimension === "depth2dMS",
          };
          break;
        case "storage-texture":
          entry.storageTexture = { access: b.access, format: b.format, viewDimension: VIEW_DIMENSIONS[b.dimension] || "2d" };
          break;
        case "sampler": entry.sampler = { type: "filtering" }; break;
        case "comparison-sampler": entry.sampler = { type: "comparison" }; break;
        case "inline-sampler": entry.sampler = { type: b.sampler.compare ? "comparison" : "filtering" }; break;
      }
      return entry;
    });
    return this.device.createBindGroupLayout({ entries });
  }

  renderVariant(frame, pipeline, primitive, stripIndexFormat) {
    const state = frame.state;
    const d = pipeline.descriptor;
    const key = JSON.stringify([primitive, stripIndexFormat, state.cull, state.winding, state.depthStencil, state.depthBias]);
    let variant = pipeline.variants.get(key);
    if (variant) return variant;
    const buffers = d.vertexBuffers.map((layout) => ({
      arrayStride: layout.stride, stepMode: layout.step === 2 ? "instance" : "vertex",
      attributes: layout.attributes.map((a) => ({ shaderLocation: a.location, format: VERTEX_FORMATS[a.format], offset: a.offset })),
    }));
    const targets = d.colors.map((c) => {
      if (!c.format || !PIXEL_FORMATS[c.format]) return null;
      const target = { format: PIXEL_FORMATS[c.format], writeMask: ((c.writeMask & 8) >> 3) | ((c.writeMask & 4) >> 1) | ((c.writeMask & 2) << 1) | ((c.writeMask & 1) << 3) };
      if (c.blend) {
        target.blend = {
          color: { srcFactor: BLEND_FACTORS[c.srcRGB], dstFactor: BLEND_FACTORS[c.dstRGB], operation: BLEND_OPERATIONS[c.opRGB] },
          alpha: { srcFactor: BLEND_FACTORS[c.srcAlpha], dstFactor: BLEND_FACTORS[c.dstAlpha], operation: BLEND_OPERATIONS[c.opAlpha] },
        };
        for (const part of [target.blend.color, target.blend.alpha]) {
          if (part.operation === "min" || part.operation === "max") { part.srcFactor = "one"; part.dstFactor = "one"; }
        }
      }
      return target;
    });
    const descriptor = {
      layout: pipeline.layout,
      vertex: { module: pipeline.vertex.module, entryPoint: pipeline.vertex.reflection.entry, buffers },
      primitive: {
        topology: TOPOLOGIES[primitive],
        stripIndexFormat: primitive === 2 || primitive === 4 ? stripIndexFormat ?? undefined : undefined,
        frontFace: state.winding === 0 ? "cw" : "ccw", cullMode: CULL_MODES[state.cull],
      },
      multisample: { count: d.sampleCount || 1, alphaToCoverageEnabled: !!d.alphaToCoverage },
    };
    if (pipeline.fragment) {
      descriptor.fragment = { module: pipeline.fragment.module, entryPoint: pipeline.fragment.reflection.entry, targets };
    }
    const depthFormat = PIXEL_FORMATS[d.depthFormat] || PIXEL_FORMATS[d.stencilFormat];
    if (depthFormat) {
      const ds = state.depthStencil || {
        depthCompare: 7, depthWrite: 0,
        front: { compare: 7, fail: 0, depthFail: 0, pass: 0, readMask: 0xffffffff, writeMask: 0xffffffff },
        back: { compare: 7, fail: 0, depthFail: 0, pass: 0, readMask: 0xffffffff, writeMask: 0xffffffff },
      };
      const face = (f) => ({ compare: COMPARE[f.compare], failOp: STENCIL_OPERATIONS[f.fail], depthFailOp: STENCIL_OPERATIONS[f.depthFail], passOp: STENCIL_OPERATIONS[f.pass] });
      descriptor.depthStencil = {
        format: depthFormat,
        depthWriteEnabled: depthFormat.startsWith("depth") ? !!ds.depthWrite : undefined,
        depthCompare: depthFormat.startsWith("depth") ? COMPARE[ds.depthCompare] : undefined,
        stencilFront: face(ds.front), stencilBack: face(ds.back),
        stencilReadMask: ds.front.readMask, stencilWriteMask: ds.front.writeMask,
        depthBias: state.depthBias ? Math.round(state.depthBias.bias) : 0,
        depthBiasSlopeScale: state.depthBias?.slope ?? 0, depthBiasClamp: state.depthBias?.clamp ?? 0,
      };
    }
    variant = this.device.createRenderPipeline(descriptor);
    pipeline.variants.set(key, variant);
    return variant;
  }

  prepareDraw(frame, primitive, stripIndexFormat) {
    const state = frame.state;
    const pipeline = state.pipeline;
    if (!pipeline) return false;
    const variant = this.renderVariant(frame, pipeline, primitive, stripIndexFormat);
    if (state.variant !== variant) {
      frame.pass.setPipeline(variant);
      state.variant = variant;
    }
    const vertexGroup = this.bindGroup(frame, pipeline.layouts[0], pipeline.vertex.reflection.bindings.filter((b) => b.group === 0), 0);
    if (vertexGroup === false) return false;
    frame.pass.setBindGroup(0, vertexGroup);
    const fragmentGroup = pipeline.fragment
      ? this.bindGroup(frame, pipeline.layouts[1], pipeline.fragment.reflection.bindings.filter((b) => b.group === 1), 1)
      : this.bindGroup(frame, pipeline.layouts[1], [], 1);
    if (fragmentGroup === false) return false;
    frame.pass.setBindGroup(1, fragmentGroup);
    pipeline.descriptor.vertexBuffers.forEach((layout, slot) => {
      const bound = state.buffers[0].get(layout.index);
      const buffer = bound && this.buffer(bound.id);
      if (buffer) frame.pass.setVertexBuffer(slot, buffer, bound.offset);
      else this.warn(`no buffer at index ${layout.index} for vertex fetch`);
    });
    return true;
  }

  /** A bind group for a stage's bindings as bound now; false when one is missing. */
  bindGroup(frame, layout, bindings, stage) {
    const state = frame.state;
    const entries = [];
    const keyParts = [];
    for (const b of bindings) {
      let resource;
      switch (b.kind) {
        case "read-only-storage": case "storage": case "uniform": {
          const bound = state.buffers[stage].get(b.index);
          const buffer = bound && this.buffer(bound.id);
          if (!buffer) { this.warn(`${b.name}: no buffer at index ${b.index}`); return false; }
          if (bound.offset % 256 !== 0) { this.warn(`${b.name}: buffer offset ${bound.offset} is not a multiple of 256 (WebGPU's alignment)`); return false; }
          resource = { buffer, offset: bound.offset, size: (buffer.size - bound.offset) & ~3 };
          keyParts.push(`${bound.id}@${bound.offset}`);
          break;
        }
        case "texture": case "storage-texture": {
          const id = state.textures[stage].get(b.index);
          const object = this.objects.get(id);
          if (!object) { this.warn(`${b.name}: no texture at index ${b.index}`); return false; }
          resource = object.view || object.texture.createView();
          keyParts.push(`t${id}`);
          break;
        }
        case "sampler": case "comparison-sampler": {
          const id = state.samplers[stage].get(b.index);
          const object = this.objects.get(id);
          if (!object) { this.warn(`${b.name}: no sampler at index ${b.index}`); return false; }
          resource = object.sampler;
          keyParts.push(`s${id}`);
          break;
        }
        case "inline-sampler": {
          const key = JSON.stringify(b.sampler);
          let sampler = this.samplerCache.get(key);
          if (!sampler) {
            sampler = this.device.createSampler(b.sampler);
            this.samplerCache.set(key, sampler);
          }
          resource = sampler;
          break;
        }
        default: continue;
      }
      entries.push({ binding: b.binding, resource });
    }
    const key = keyParts.join(",");
    let cached = frame.bindGroups.get(layout);
    if (!cached) frame.bindGroups.set(layout, (cached = new Map()));
    let group = cached.get(key);
    if (!group) {
      group = this.device.createBindGroup({ layout, entries });
      cached.set(key, group);
    }
    return group;
  }

  writeGrid(frame, grid) {
    const offset = frame.gridOffset;
    frame.gridOffset += 256;
    if (!this.gridArena || this.gridArena.size < frame.gridOffset) {
      const size = Math.max(frame.gridOffset * 2, 16 << 10);
      const old = this.gridArena;
      this.gridArena = this.device.createBuffer({ size, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
      if (old && offset > 0) this.warn("grid arena grew mid-stream");
    }
    this.queue.writeBuffer(this.gridArena, offset, new Uint32Array([grid[0], grid[1], grid[2], 0]));
    return offset;
  }

  generateMipmaps(encoder, texture) {
    const format = texture.texture.format;
    let pipeline = this.mipmapPipelines.get(format);
    if (!pipeline) {
      const module = this.device.createShaderModule({ code: MIPMAP_SHADER });
      pipeline = this.device.createRenderPipeline({
        layout: "auto", vertex: { module, entryPoint: "vs" }, fragment: { module, entryPoint: "fs", targets: [{ format }] },
        primitive: { topology: "triangle-list" },
      });
      this.mipmapPipelines.set(format, pipeline);
    }
    this.mipmapSampler ??= this.device.createSampler({ minFilter: "linear", magFilter: "linear" });
    const layers = texture.type === 7 ? 1 : texture.texture.depthOrArrayLayers;
    for (let layer = 0; layer < layers; layer++) {
      for (let level = 1; level < texture.texture.mipLevelCount; level++) {
        const view = (l) => texture.texture.createView({ dimension: "2d", baseMipLevel: l, mipLevelCount: 1, baseArrayLayer: layer, arrayLayerCount: 1 });
        const pass = encoder.beginRenderPass({ colorAttachments: [{ view: view(level), loadOp: "clear", storeOp: "store" }] });
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, this.device.createBindGroup({
          layout: pipeline.getBindGroupLayout(0),
          entries: [{ binding: 0, resource: view(level - 1) }, { binding: 1, resource: this.mipmapSampler }],
        }));
        pass.draw(3);
        pass.end();
      }
    }
  }

  // MARK: Readback

  encodeRead(encoder, read) {
    if (read.kind === 1) {
      const buffer = this.buffer(read.id);
      if (!buffer) return null;
      const staging = this.device.createBuffer({ size: buffer.size, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
      encoder.copyBufferToBuffer(buffer, 0, staging, 0, buffer.size);
      return { ...read, buffer: staging, length: this.objects.get(read.id).length };
    }
    const object = this.objects.get(read.id);
    const bpp = object && BYTES_PER_PIXEL[object.format];
    if (!object || !bpp || object.format >= 250) return null;
    const width = Math.max(object.width >> read.level, 1), height = Math.max(object.height >> read.level, 1);
    const rowBytes = width * bpp, paddedRow = (rowBytes + 255) & ~255;
    const staging = this.device.createBuffer({ size: paddedRow * height, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
    encoder.copyTextureToBuffer(
      { texture: object.texture, mipLevel: read.level, origin: { x: 0, y: 0, z: read.slice } },
      { buffer: staging, bytesPerRow: paddedRow, rowsPerImage: height }, { width, height, depthOrArrayLayers: 1 },
    );
    return { ...read, buffer: staging, rowBytes, paddedRow, height };
  }

  readbackBytes(results) {
    const parts = [];
    let total = 0;
    for (const s of results) {
      const mapped = new Uint8Array(s.buffer.getMappedRange());
      let bytes;
      if (s.kind === 1) {
        bytes = mapped.slice(0, s.length);
      } else {
        bytes = new Uint8Array(s.rowBytes * s.height);
        for (let row = 0; row < s.height; row++) bytes.set(mapped.subarray(row * s.paddedRow, row * s.paddedRow + s.rowBytes), row * s.rowBytes);
      }
      s.buffer.unmap();
      s.buffer.destroy();
      const header = new Int32Array([s.kind, s.id, s.slice || 0, s.level || 0, bytes.length]);
      parts.push(new Uint8Array(header.buffer), bytes);
      total += 20 + ((bytes.length + 3) & ~3);
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < parts.length; i += 2) {
      out.set(parts[i], offset);
      offset += 20;
      out.set(parts[i + 1], offset);
      offset += (parts[i + 1].length + 3) & ~3;
    }
    return out;
  }
}
