// The Direct3D 11 half of the Windows SwiftGPU backend. The Swift side
// (DirectXGPUDevice.swift) declares these flat C entry points via
// @_extern(c) and calls them 1:1 from the GPUDevice/GPURenderPass methods;
// ALL D3D calls in the ecosystem live in this translation unit.
//
// D3D11 at feature level 10_0 — flat 2D pipelines, no explicit residency or
// queues. The three pipelines mirror the Metal/GLES backends exactly:
// premultiplied-alpha textured triangles, straight-alpha per-vertex-color
// triangles, and the SDF rounded-rect shader over expandRectInstances'
// stride-12 vertices (expansion happens in Swift core, shared by every
// backend).
//
// Ownership contract (see the implementation guide): the HOST owns the HWND
// and sizing; this backend owns device, swapchain, pipelines, textures, and
// draws. `sgpu_d3d_init_offscreen` swaps the swapchain for a readable
// render target so the pixel test runs without a window.

#include <d3d11.h>
#include <d3dcompiler.h>

#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

// --- Shaders ---------------------------------------------------------------
// HLSL translations of the Metal/GLES shaders. The cbuffer matrix is
// column-major (HLSL's default packing), so the column-major floats the
// Swift side uploads are used as-is and `mul(transform, v)` is M * v — the
// same math as glUniformMatrix4fv(transpose = 0) and Metal's `transform *`.
// Positions go through as float4 SV_Position; the rasterizer's default
// perspective-correct interpolation handles UVs (never divide on the CPU).
const char* kShaderSource = R"hlsl(
cbuffer Transform : register(b0) { float4x4 transform; };

struct TexVSIn  { float2 pos : POSITION; float2 uv : TEXCOORD0; };
struct TexVSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

TexVSOut tex_vs(TexVSIn i) {
  TexVSOut o;
  o.pos = mul(transform, float4(i.pos, 0.0, 1.0));
  o.uv = i.uv;
  return o;
}

Texture2D tex : register(t0);
SamplerState samp : register(s0);

float4 tex_ps(TexVSOut i) : SV_Target { return tex.Sample(samp, i.uv); }

struct ColVSIn  { float2 pos : POSITION; float4 color : COLOR0; };
struct ColVSOut { float4 pos : SV_Position; float4 color : COLOR0; };

ColVSOut color_vs(ColVSIn i) {
  ColVSOut o;
  o.pos = mul(transform, float4(i.pos, 0.0, 1.0));
  o.color = i.color;
  return o;
}

float4 color_ps(ColVSOut i) : SV_Target { return i.color; }

struct RectVSIn {
  float2 pos : POSITION;
  float2 local : TEXCOORD0;
  float2 halfSize : TEXCOORD1;
  float2 radiusBorder : TEXCOORD2;
  float4 color : COLOR0;
};
struct RectVSOut {
  float4 pos : SV_Position;
  float2 local : TEXCOORD0;
  float2 halfSize : TEXCOORD1;
  float2 radiusBorder : TEXCOORD2;
  float4 color : COLOR0;
};

RectVSOut rect_vs(RectVSIn i) {
  RectVSOut o;
  o.pos = mul(transform, float4(i.pos, 0.0, 1.0));
  o.local = i.local;
  o.halfSize = i.halfSize;
  o.radiusBorder = i.radiusBorder;
  o.color = i.color;
  return o;
}

float sdRoundBox(float2 p, float2 b, float r) {
  float2 q = abs(p) - b + float2(r, r);
  return length(max(q, float2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float4 rect_ps(RectVSOut i) : SV_Target {
  float r = min(i.radiusBorder.x, min(i.halfSize.x, i.halfSize.y));
  float d = sdRoundBox(i.local, i.halfSize, r);
  float alpha;
  if (i.radiusBorder.y > 0.0) {
    alpha = 1.0 - smoothstep(-0.75, 0.75, abs(d) - i.radiusBorder.y * 0.5);
  } else {
    alpha = 1.0 - smoothstep(-0.75, 0.75, d);
  }
  return float4(i.color.rgb, i.color.a * alpha);
}
)hlsl";

struct Pipeline {
  ID3D11VertexShader* vs = nullptr;
  ID3D11PixelShader* ps = nullptr;
  ID3D11InputLayout* layout = nullptr;
  UINT stride = 0;
};

struct TextureEntry {
  ID3D11Texture2D* texture = nullptr;
  ID3D11ShaderResourceView* srv = nullptr;
};

struct Backend {
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  IDXGISwapChain* swapchain = nullptr;         // on-screen mode
  ID3D11Texture2D* offscreenTarget = nullptr;  // offscreen mode
  ID3D11RenderTargetView* rtv = nullptr;
  int targetWidth = 0;
  int targetHeight = 0;

  Pipeline textured;
  Pipeline color;
  Pipeline rect;
  ID3D11Buffer* transformBuffer = nullptr;
  ID3D11Buffer* vertexBuffer = nullptr;
  size_t vertexCapacityBytes = 0;
  ID3D11SamplerState* sampler = nullptr;
  ID3D11BlendState* premultipliedBlend = nullptr;
  ID3D11BlendState* straightBlend = nullptr;
  ID3D11RasterizerState* rasterizer = nullptr;  // scissor always enabled

  std::unordered_map<int, TextureEntry> textures;
  int nextTextureID = 1;
};

Backend g;

template <typename T>
void SafeRelease(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

bool CompilePipeline(const char* vsEntry, const char* psEntry,
                     const D3D11_INPUT_ELEMENT_DESC* elements, UINT elementCount,
                     UINT stride, Pipeline* out) {
  ID3DBlob* vsBlob = nullptr;
  ID3DBlob* psBlob = nullptr;
  ID3DBlob* errors = nullptr;
  if (FAILED(D3DCompile(kShaderSource, strlen(kShaderSource), nullptr, nullptr,
                        nullptr, vsEntry, "vs_4_0", 0, 0, &vsBlob, &errors))) {
    if (errors) {
      OutputDebugStringA(static_cast<const char*>(errors->GetBufferPointer()));
      errors->Release();
    }
    return false;
  }
  if (FAILED(D3DCompile(kShaderSource, strlen(kShaderSource), nullptr, nullptr,
                        nullptr, psEntry, "ps_4_0", 0, 0, &psBlob, &errors))) {
    if (errors) {
      OutputDebugStringA(static_cast<const char*>(errors->GetBufferPointer()));
      errors->Release();
    }
    vsBlob->Release();
    return false;
  }
  bool ok =
      SUCCEEDED(g.device->CreateVertexShader(vsBlob->GetBufferPointer(),
                                             vsBlob->GetBufferSize(), nullptr, &out->vs)) &&
      SUCCEEDED(g.device->CreatePixelShader(psBlob->GetBufferPointer(),
                                            psBlob->GetBufferSize(), nullptr, &out->ps)) &&
      SUCCEEDED(g.device->CreateInputLayout(elements, elementCount,
                                            vsBlob->GetBufferPointer(),
                                            vsBlob->GetBufferSize(), &out->layout));
  out->stride = stride;
  vsBlob->Release();
  psBlob->Release();
  return ok;
}

bool CreatePipelinesAndState() {
  const D3D11_INPUT_ELEMENT_DESC texturedElements[] = {
      {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
  };
  const D3D11_INPUT_ELEMENT_DESC colorElements[] = {
      {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
  };
  const D3D11_INPUT_ELEMENT_DESC rectElements[] = {
      {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"TEXCOORD", 1, DXGI_FORMAT_R32G32_FLOAT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"TEXCOORD", 2, DXGI_FORMAT_R32G32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 32, D3D11_INPUT_PER_VERTEX_DATA, 0},
  };
  if (!CompilePipeline("tex_vs", "tex_ps", texturedElements, 2, 16, &g.textured) ||
      !CompilePipeline("color_vs", "color_ps", colorElements, 2, 24, &g.color) ||
      !CompilePipeline("rect_vs", "rect_ps", rectElements, 5, 48, &g.rect)) {
    return false;
  }

  D3D11_BUFFER_DESC cb = {};
  cb.ByteWidth = 16 * sizeof(float);
  cb.Usage = D3D11_USAGE_DYNAMIC;
  cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  if (FAILED(g.device->CreateBuffer(&cb, nullptr, &g.transformBuffer))) return false;

  D3D11_SAMPLER_DESC sampler = {};
  sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
  sampler.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler.ComparisonFunc = D3D11_COMPARISON_NEVER;
  sampler.MaxLOD = D3D11_FLOAT32_MAX;
  if (FAILED(g.device->CreateSamplerState(&sampler, &g.sampler))) return false;

  // Premultiplied (drawTextured): src = ONE, dst = INV_SRC_ALPHA, color+alpha.
  D3D11_BLEND_DESC premultiplied = {};
  premultiplied.RenderTarget[0].BlendEnable = TRUE;
  premultiplied.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
  premultiplied.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  premultiplied.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  premultiplied.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  premultiplied.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  premultiplied.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  premultiplied.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  if (FAILED(g.device->CreateBlendState(&premultiplied, &g.premultipliedBlend))) return false;

  // Straight alpha (drawColor / drawRects): SRC_ALPHA / INV_SRC_ALPHA on
  // color, ONE / INV_SRC_ALPHA on alpha — the GLES blendFuncSeparate twin.
  D3D11_BLEND_DESC straight = premultiplied;
  straight.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
  if (FAILED(g.device->CreateBlendState(&straight, &g.straightBlend))) return false;

  // Scissor stays enabled permanently; clearScissor sets a full-target rect
  // (simplest way to make set/clear symmetric). Cull NONE: callers hand us
  // triangles in either winding, exactly like GL/Metal defaults.
  D3D11_RASTERIZER_DESC rasterizer = {};
  rasterizer.FillMode = D3D11_FILL_SOLID;
  rasterizer.CullMode = D3D11_CULL_NONE;
  rasterizer.ScissorEnable = TRUE;
  rasterizer.DepthClipEnable = TRUE;
  if (FAILED(g.device->CreateRasterizerState(&rasterizer, &g.rasterizer))) return false;

  return true;
}

bool CreateDevice(UINT flags) {
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
  return SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                     levels, 2, D3D11_SDK_VERSION, &g.device, nullptr,
                                     &g.context)) ||
         SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                                     levels, 2, D3D11_SDK_VERSION, &g.device, nullptr,
                                     &g.context));
}

bool CreateSwapchainTarget() {
  ID3D11Texture2D* backbuffer = nullptr;
  if (FAILED(g.swapchain->GetBuffer(0, __isodof(ID3D11Texture2D),
                                    reinterpret_cast<void**>(&backbuffer)))) {
    return false;
  }
  bool ok = SUCCEEDED(g.device->CreateRenderTargetView(backbuffer, nullptr, &g.rtv));
  backbuffer->Release();
  return ok;
}

void UploadVertices(const float* vertices, int floatCount) {
  size_t bytes = static_cast<size_t>(floatCount) * sizeof(float);
  if (bytes > g.vertexCapacityBytes) {
    SafeRelease(g.vertexBuffer);
    D3D11_BUFFER_DESC vb = {};
    g.vertexCapacityBytes = std::max<size_t>(bytes, 64 * 1024);
    vb.ByteWidth = static_cast<UINT>(g.vertexCapacityBytes);
    vb.Usage = D3D11_USAGE_DYNAMIC;
    vb.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    vb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(g.device->CreateBuffer(&vb, nullptr, &g.vertexBuffer))) {
      g.vertexCapacityBytes = 0;
      return;
    }
  }
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(g.context->Map(g.vertexBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return;
  memcpy(mapped.pData, vertices, bytes);
  g.context->Unmap(g.vertexBuffer, 0);
}

void Draw(const Pipeline& pipeline, ID3D11BlendState* blend, const float* vertices,
          int floatCount) {
  if (!g.context || floatCount <= 0) return;
  UploadVertices(vertices, floatCount);  // creates/grows the dynamic buffer
  if (!g.vertexBuffer) return;
  UINT stride = pipeline.stride;
  UINT offset = 0;
  const float blendFactor[4] = {0, 0, 0, 0};
  g.context->IASetInputLayout(pipeline.layout);
  g.context->IASetVertexBuffers(0, 1, &g.vertexBuffer, &stride, &offset);
  g.context->VSSetShader(pipeline.vs, nullptr, 0);
  g.context->PSSetShader(pipeline.ps, nullptr, 0);
  g.context->OMSetBlendState(blend, blendFactor, 0xffffffff);
  g.context->Draw(static_cast<UINT>(floatCount) / (stride / sizeof(float)), 0);
}

}  // namespace

extern "C" {

// Create the device + swapchain against the host's HWND. Returns 1 on
// success. The host owns the HWND; call sgpu_d3d_resize on WM_SIZE.
int sgpu_d3d_init_hwnd(void* hwnd, int widthPx, int heightPx) {
  if (g.device) return 1;
  if (!CreateDevice(D3D11_CREATE_DEVICE_BGRA_SUPPORT)) return 0;

  IDXGIDevice* dxgiDevice = nullptr;
  IDXGIAdapter* adapter = nullptr;
  IDXGIFactory* factory = nullptr;
  if (FAILED(g.device->QueryInterface(__isodof(IDXGIDevice),
                                      reinterpret_cast<void**>(&dxgiDevice))) ||
      FAILED(dxgiDevice->GetAdapter(&adapter)) ||
      FAILED(adapter->GetParent(__isodof(IDXGIFactory),
                                reinterpret_cast<void**>(&factory)))) {
    SafeRelease(adapter);
    SafeRelease(dxgiDevice);
    return 0;
  }

  DXGI_SWAP_CHAIN_DESC desc = {};
  desc.BufferDesc.Width = widthPx;
  desc.BufferDesc.Height = heightPx;
  desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.BufferCount = 2;
  desc.OutputWindow = static_cast<HWND>(hwnd);
  desc.Windowed = TRUE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  bool ok = SUCCEEDED(factory->CreateSwapChain(g.device, &desc, &g.swapchain));
  factory->Release();
  adapter->Release();
  dxgiDevice->Release();
  if (!ok || !CreateSwapchainTarget()) return 0;
  g.targetWidth = widthPx;
  g.targetHeight = heightPx;
  return CreatePipelinesAndState() ? 1 : 0;
}

// Create the device + a readable offscreen render target (no window) —
// the pixel test's entry point, mirroring MetalGPUDevice.renderOffscreen.
int sgpu_d3d_init_offscreen(int widthPx, int heightPx) {
  if (g.device) return 1;
  if (!CreateDevice(0)) return 0;
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = widthPx;
  desc.Height = heightPx;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  if (FAILED(g.device->CreateTexture2D(&desc, nullptr, &g.offscreenTarget)) ||
      FAILED(g.device->CreateRenderTargetView(g.offscreenTarget, nullptr, &g.rtv))) {
    return 0;
  }
  g.targetWidth = widthPx;
  g.targetHeight = heightPx;
  return CreatePipelinesAndState() ? 1 : 0;
}

// Resize the swapchain to the window's new client size (device pixels).
void sgpu_d3d_resize(int widthPx, int heightPx) {
  if (!g.swapchain || widthPx <= 0 || heightPx <= 0) return;
  if (widthPx == g.targetWidth && heightPx == g.targetHeight) return;
  g.context->OMSetRenderTargets(0, nullptr, nullptr);
  SafeRelease(g.rtv);
  g.swapchain->ResizeBuffers(0, widthPx, heightPx, DXGI_FORMAT_UNKNOWN, 0);
  CreateSwapchainTarget();
  g.targetWidth = widthPx;
  g.targetHeight = heightPx;
}

void sgpu_d3d_begin_frame(float r, float gg, float b, float a) {
  if (!g.context || !g.rtv) return;
  g.context->OMSetRenderTargets(1, &g.rtv, nullptr);
  D3D11_VIEWPORT viewport = {};
  viewport.Width = static_cast<float>(g.targetWidth);
  viewport.Height = static_cast<float>(g.targetHeight);
  viewport.MaxDepth = 1.0f;
  g.context->RSSetViewports(1, &viewport);
  g.context->RSSetState(g.rasterizer);
  D3D11_RECT full = {0, 0, g.targetWidth, g.targetHeight};
  g.context->RSSetScissorRects(1, &full);
  const float clear[4] = {r, gg, b, a};
  g.context->ClearRenderTargetView(g.rtv, clear);
  g.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g.context->VSSetConstantBuffers(0, 1, &g.transformBuffer);
  g.context->PSSetSamplers(0, 1, &g.sampler);
}

void sgpu_d3d_end_frame(void) {
  if (g.swapchain) g.swapchain->Present(1, 0);
}

// Offscreen only: read the target back as tightly packed RGBA (top-left
// origin). `out` must hold targetWidth * targetHeight * 4 bytes.
void sgpu_d3d_read_pixels(unsigned char* out) {
  if (!g.offscreenTarget || !out) return;
  D3D11_TEXTURE2D_DESC desc = {};
  g.offscreenTarget->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D* staging = nullptr;
  if (FAILED(g.device->CreateTexture2D(&desc, nullptr, &staging))) return;
  g.context->CopyResource(staging, g.offscreenTarget);
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (SUCCEEDED(g.context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
    for (UINT row = 0; row < desc.Height; ++row) {
      memcpy(out + row * desc.Width * 4,
             static_cast<const unsigned char*>(mapped.pData) + row * mapped.RowPitch,
             desc.Width * 4);
    }
    g.context->Unmap(staging, 0);
  }
  staging->Release();
}

void sgpu_d3d_set_transform(const float* matrix16) {
  if (!g.context || !g.transformBuffer) return;
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(g.context->Map(g.transformBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return;
  memcpy(mapped.pData, matrix16, 16 * sizeof(float));
  g.context->Unmap(g.transformBuffer, 0);
}

// RGBA8 texture from tightly packed bytes (premultiplied where translucent —
// see the core contract). Returns the texture id, 0 on failure.
int sgpu_d3d_make_texture(int width, int height, const unsigned char* rgba) {
  if (!g.device) return 0;
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_IMMUTABLE;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA initial = {};
  initial.pSysMem = rgba;
  initial.SysMemPitch = width * 4;
  TextureEntry entry;
  if (FAILED(g.device->CreateTexture2D(&desc, &initial, &entry.texture)) ||
      FAILED(g.device->CreateShaderResourceView(entry.texture, nullptr, &entry.srv))) {
    SafeRelease(entry.texture);
    return 0;
  }
  int id = g.nextTextureID++;
  g.textures[id] = entry;
  return id;
}

void sgpu_d3d_destroy_texture(int id) {
  auto it = g.textures.find(id);
  if (it == g.textures.end()) return;
  SafeRelease(it->second.srv);
  SafeRelease(it->second.texture);
  g.textures.erase(it);
}

// Stride-4 (x, y, u, v) triangles, premultiplied-alpha blended.
void sgpu_d3d_draw_textured(const float* vertices, int floatCount, int textureID) {
  auto it = g.textures.find(textureID);
  if (it == g.textures.end()) return;
  g.context->PSSetShaderResources(0, 1, &it->second.srv);
  Draw(g.textured, g.premultipliedBlend, vertices, floatCount);
}

// Stride-6 (x, y, r, g, b, a) triangles, straight-alpha blended.
void sgpu_d3d_draw_color(const float* vertices, int floatCount) {
  Draw(g.color, g.straightBlend, vertices, floatCount);
}

// Stride-12 expandRectInstances vertices (expansion happens in Swift core).
void sgpu_d3d_draw_rect_vertices(const float* vertices, int floatCount) {
  Draw(g.rect, g.straightBlend, vertices, floatCount);
}

// Device-pixel scissor, top-left origin (D3D11's native convention — no
// flip, unlike GL). Clamped to the target like the Metal backend.
void sgpu_d3d_set_scissor(int x, int y, int width, int height) {
  if (!g.context) return;
  int clampedX = std::max(0, std::min(x, g.targetWidth));
  int clampedY = std::max(0, std::min(y, g.targetHeight));
  int clampedW = std::max(0, std::min(width, g.targetWidth - clampedX));
  int clampedH = std::max(0, std::min(height, g.targetHeight - clampedY));
  D3D11_RECT rect = {clampedX, clampedY, clampedX + clampedW, clampedY + clampedH};
  g.context->RSSetScissorRects(1, &rect);
}

void sgpu_d3d_clear_scissor(void) {
  if (!g.context) return;
  D3D11_RECT full = {0, 0, g.targetWidth, g.targetHeight};
  g.context->RSSetScissorRects(1, &full);
}

}  // extern "C"
