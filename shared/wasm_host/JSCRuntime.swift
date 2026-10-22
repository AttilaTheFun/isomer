// `JSCRuntime` — an EXPERIMENTAL `WasmRuntime` backed by JavaScriptCore's own
// WebAssembly engine: the reactor runs inside a `JSContext`, instantiated by
// a small JS bootstrap that carries the same WASI shim the web host uses.
// It exists to prove the engine seam ("a JS runtime *as* the wasm runtime")
// and to A/B against WasmKit; register it like any engine:
//
//     WasmRuntimeRegistry.register { JSCRuntime() }
//
// Import surface (mirrors WasmKitRuntime's): module `iso_hot` — render_tree /
// log / epoch_millis / schedule_render; WASI preview1 stubbed; any OTHER
// import module resolves to no-op zero-returning functions (enough for
// render-only reactors; the swift_ffi DI transport is NOT bridged here, so
// The swift_ffi DI transport is not bridged (features see an empty
// dependency dictionary); legacy flag/track stubs remain only for the
// simple iso_host ABI).
//
// Platform notes: on macOS JSC JIT-compiles wasm (BBQ/OMG tiers). On iOS,
// third-party processes get no JIT pages, so JSC executes wasm in its
// interpreter tier (LLInt) — expect interpreter-class performance
// there; measure before shipping anything on this path.

#if canImport(JavaScriptCore)

import Foundation
import JavaScriptCore
import SwiftFFIWasmHost
import IsomerWasmRuntime

public enum JSCRuntimeError: Error, CustomStringConvertible {
    case launchFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "JSCRuntime launch failed: \(message)"
        }
    }
}

@MainActor
public final class JSCRuntime: WasmRuntime {
    private let context: JSContext

    public init() {
        context = JSContext()!
        context.name = "Isomer JSCRuntime"
    }

    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        // Surface JS exceptions as Swift errors instead of silent nils.
        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "unknown JS exception"
        }

        // The Swift half of the iso_hot imports. render_tree copies out of
        // guest memory on the JS side (a Uint8Array slice) and hands the
        // bytes over as a JSValue-typed array we drain via toArray — fine
        // for patch-sized buffers; the bulk read path below uses the
        // ArrayBuffer base pointer instead.
        let onRenderTree = hostImports.onRenderTree
        let renderTree: @convention(block) (JSValue) -> Void = { bytes in
            guard let numbers = bytes.toArray() as? [NSNumber] else { return }
            onRenderTree(numbers.map { UInt8(truncating: $0) })
        }
        let onLog = hostImports.onLog
        let log: @convention(block) (String) -> Void = { onLog($0) }
        let epochMillis = hostImports.epochMillis
        let epoch: @convention(block) () -> Double = { epochMillis() }
        let onScheduleRender = hostImports.onScheduleRender
        let scheduleRender: @convention(block) () -> Void = { onScheduleRender() }
        // The platform channel: bytes in (UTF-8, decoded here), and a host
        // value out as a byte array (null for none).
        func utf8(_ value: JSValue) -> String {
            String(decoding: (value.toArray() as? [NSNumber] ?? []).map { UInt8(truncating: $0) }, as: UTF8.self)
        }
        let onPlatformCommand = hostImports.onPlatformCommand
        let platformCommand: @convention(block) (JSValue, JSValue) -> Void = { key, value in
            onPlatformCommand(utf8(key), utf8(value))
        }
        let hostValueOf = hostImports.hostValue
        let hostValue: @convention(block) (JSValue) -> [NSNumber]? = { key in
            hostValueOf(utf8(key)).map { Array($0.utf8).map { NSNumber(value: $0) } }
        }
        let flag: @convention(block) (String) -> Int32 = { [weak self] name in
            Int32(0)
        }
        let track: @convention(block) (String) -> Void = { [weak self] event in
            _ = event
        }
        context.setObject(renderTree, forKeyedSubscript: "__isoRenderTree" as NSString)
        context.setObject(log, forKeyedSubscript: "__isoLog" as NSString)
        context.setObject(epoch, forKeyedSubscript: "__isoEpochMillis" as NSString)
        context.setObject(scheduleRender, forKeyedSubscript: "__isoScheduleRender" as NSString)
        context.setObject(platformCommand, forKeyedSubscript: "__isoPlatformCommand" as NSString)
        context.setObject(hostValue, forKeyedSubscript: "__isoHostValue" as NSString)
        context.setObject(flag, forKeyedSubscript: "__isoFlag" as NSString)
        context.setObject(track, forKeyedSubscript: "__isoTrack" as NSString)

        context.evaluateScript(Self.bootstrap)
        if let jsError { throw JSCRuntimeError.launchFailed(jsError) }

        // Hand the module bytes over as a real ArrayBuffer (constructed from
        // a base64 string — the portable JSValue-safe path; module bytes
        // cross once per launch).
        let base64 = Data(wasm).base64EncodedString()
        context.setObject(base64, forKeyedSubscript: "__isoWasmBase64" as NSString)
        context.evaluateScript("__iso.launch(__isoDecodeBase64(__isoWasmBase64));")
        if let jsError { throw JSCRuntimeError.launchFailed(jsError) }
    }

    @discardableResult
    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        let jsArgs: [Any] = args.map { scalar in
            switch scalar {
            case .i32(let x): return NSNumber(value: x)
            case .i64(let x): return NSNumber(value: x)
            case .f32(let x): return NSNumber(value: x)
            case .f64(let x): return NSNumber(value: x)
            }
        }
        guard let iso = context.objectForKeyedSubscript("__iso"),
            let result = iso.invokeMethod("call", withArguments: [name, jsArgs])
        else { return nil }
        return result.isUndefined || result.isNull ? nil : .i32(result.toInt32())
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard len > 0 else { return [] }
        if let base = memoryBase() {
            return Array(UnsafeRawBufferPointer(start: base + Int(ptr), count: Int(len)))
        }
        // JS fallback (wasm-backed ArrayBuffers may not expose a bytes ptr
        // through the C API): base64 through the context.
        guard let b64 = context.evaluateScript("__iso.readBase64(\(ptr), \(len))")?.toString(),
            let data = Data(base64Encoded: b64)
        else { return [] }
        return [UInt8](data)
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if let base = memoryBase() {
            bytes.withUnsafeBytes { raw in
                UnsafeMutableRawPointer(mutating: base + Int(ptr))
                    .copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            return
        }
        let b64 = Data(bytes).base64EncodedString()
        context.setObject(b64, forKeyedSubscript: "__isoWriteB64" as NSString)
        context.evaluateScript("__iso.writeBase64(\(ptr), __isoWriteB64)")
    }

    /// The live linear memory's base pointer, via the JSC C API (zero-copy).
    /// Re-fetched per call: the ArrayBuffer detaches when guest memory grows.
    private func memoryBase() -> UnsafeRawPointer? {
        guard let buffer = context.evaluateScript("__iso.memoryBuffer()"),
            !buffer.isUndefined
        else { return nil }
        let ctxRef = context.jsGlobalContextRef
        let objRef = JSValueToObject(ctxRef, buffer.jsValueRef, nil)
        return JSObjectGetArrayBufferBytesPtr(ctxRef, objRef, nil).map { UnsafeRawPointer($0) }
    }

    // MARK: - JS bootstrap

    /// The in-context runtime: base64 decode, the WASI preview1 shim (the
    /// same minimal surface as swift_ffi's TS runtime — the reactor performs
    /// no I/O of its own), the iso_hot import bridge, and a no-op Proxy for
    /// any other import module (render-only reactors resolve everything).
    private static let bootstrap = """
        globalThis.__isoDecodeBase64 = function (s) {
            const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            const lookup = new Uint8Array(128);
            for (let i = 0; i < table.length; i++) lookup[table.charCodeAt(i)] = i;
            let pad = 0;
            for (let i = s.length - 1; s[i] === "="; i--) pad++;
            const out = new Uint8Array(((s.length / 4) * 3) - pad);
            let o = 0;
            for (let i = 0; i < s.length; i += 4) {
                const n = (lookup[s.charCodeAt(i)] << 18) | (lookup[s.charCodeAt(i + 1)] << 12)
                    | (lookup[s.charCodeAt(i + 2)] << 6) | lookup[s.charCodeAt(i + 3)];
                out[o++] = (n >> 16) & 0xff;
                if (o < out.length) out[o++] = (n >> 8) & 0xff;
                if (o < out.length) out[o++] = n & 0xff;
            }
            return out;
        };

        globalThis.__iso = (function () {
            let instance = null;
            let memory = null;
            const WASI_SUCCESS = 0, WASI_EBADF = 8, WASI_ENOSYS = 52;
            const view = () => new DataView(memory.buffer);
            const wasiKnown = {
                args_sizes_get: (argc, argvBufSize) => {
                    view().setUint32(argc, 0, true);
                    view().setUint32(argvBufSize, 0, true);
                    return WASI_SUCCESS;
                },
                args_get: () => WASI_SUCCESS,
                environ_sizes_get: (count, bufSize) => {
                    view().setUint32(count, 0, true);
                    view().setUint32(bufSize, 0, true);
                    return WASI_SUCCESS;
                },
                environ_get: () => WASI_SUCCESS,
                fd_fdstat_get: (_fd, stat) => {
                    for (let i = 0; i < 24; i++) view().setUint8(stat + i, 0);
                    return WASI_SUCCESS;
                },
                fd_prestat_get: () => WASI_EBADF,
                fd_prestat_dir_name: () => WASI_EBADF,
                fd_close: () => WASI_SUCCESS,
                fd_read: (_fd, _iovs, _n, nread) => {
                    view().setUint32(nread, 0, true);
                    return WASI_SUCCESS;
                },
                fd_seek: (_fd, _offset, _whence, newOffset) => {
                    view().setUint32(newOffset, 0, true);
                    return WASI_SUCCESS;
                },
                fd_write: (_fd, iovs, n, nwritten) => {
                    let written = 0;
                    for (let i = 0; i < n; i++) written += view().getUint32(iovs + i * 8 + 4, true);
                    view().setUint32(nwritten, written, true);
                    return WASI_SUCCESS;
                },
                path_open: () => WASI_EBADF,
                proc_exit: (code) => { throw new Error("proc_exit(" + code + ")"); },
                random_get: (ptr, len) => {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    for (let i = 0; i < len; i++) bytes[i] = Math.floor(Math.random() * 256);
                    return WASI_SUCCESS;
                },
                sched_yield: () => WASI_SUCCESS,
                clock_time_get: (_id, _precision, timePtr) => {
                    const ns = BigInt(Math.round(__isoEpochMillis() * 1e6));
                    view().setBigUint64(timePtr, ns, true);
                    return WASI_SUCCESS;
                },
            };
            const wasi = new Proxy(wasiKnown, {
                get: (target, name) => target[name] ?? (() => WASI_ENOSYS),
            });
            const isoHot = {
                render_tree: (ptr, len) => {
                    __isoRenderTree(new Uint8Array(memory.buffer, ptr, len));
                },
                log: (ptr, len) => {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    let s = "";
                    for (let i = 0; i < len; i++) s += String.fromCharCode(bytes[i]);
                    __isoLog(s);
                },
                epoch_millis: () => __isoEpochMillis(),
                schedule_render: () => __isoScheduleRender(),
                platform_command: (kp, kl, vp, vl) => {
                    __isoPlatformCommand(Array.from(new Uint8Array(memory.buffer, kp, kl)),
                                         Array.from(new Uint8Array(memory.buffer, vp, vl)));
                },
                host_value: (kp, kl, out, cap) => {
                    const value = __isoHostValue(Array.from(new Uint8Array(memory.buffer, kp, kl)));
                    if (value === null || value === undefined) return -1;
                    if (value.length <= cap) new Uint8Array(memory.buffer, out, value.length).set(value);
                    return value.length;
                },
            };
            // The simple iso_host DI surface (flag/track); anything else a
            // reactor imports resolves to a zero-returning no-op — enough for
            // render-only reactors (the swift_ffi transport is not bridged).
            const isoHost = {
                flag: (ptr, len) => {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    let s = "";
                    for (let i = 0; i < len; i++) s += String.fromCharCode(bytes[i]);
                    return __isoFlag(s);
                },
                track: (ptr, len) => {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    let s = "";
                    for (let i = 0; i < len; i++) s += String.fromCharCode(bytes[i]);
                    __isoTrack(s);
                },
            };
            const noopModule = new Proxy({}, { get: () => (() => 0) });
            const imports = new Proxy(
                { wasi_snapshot_preview1: wasi, iso_hot: isoHot, iso_host: isoHost },
                { get: (target, name) => target[name] ?? noopModule }
            );
            return {
                launch(bytes) {
                    const module = new WebAssembly.Module(bytes);
                    instance = new WebAssembly.Instance(module, imports);
                    memory = instance.exports.memory;
                    if (instance.exports._initialize) instance.exports._initialize();
                },
                call(name, args) {
                    return instance.exports[name](...args);
                },
                memoryBuffer() {
                    return memory ? memory.buffer : undefined;
                },
                readBase64(ptr, len) {
                    const bytes = new Uint8Array(memory.buffer, ptr, len);
                    const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
                    let out = "";
                    for (let i = 0; i < len; i += 3) {
                        const b0 = bytes[i], b1 = i + 1 < len ? bytes[i + 1] : 0, b2 = i + 2 < len ? bytes[i + 2] : 0;
                        out += table[b0 >> 2] + table[((b0 & 3) << 4) | (b1 >> 4)]
                            + (i + 1 < len ? table[((b1 & 15) << 2) | (b2 >> 6)] : "=")
                            + (i + 2 < len ? table[b2 & 63] : "=");
                    }
                    return out;
                },
                writeBase64(ptr, b64) {
                    const decoded = __isoDecodeBase64(b64);
                    new Uint8Array(memory.buffer, ptr, decoded.length).set(decoded);
                },
            };
        })();
        """
}

#endif
