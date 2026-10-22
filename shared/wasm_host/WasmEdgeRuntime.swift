// `WasmEdgeRuntime` — an EXPERIMENTAL `WasmRuntime` backed by WasmEdge
// through its C API (interpreter mode; built-in WASI). Register it like any
// engine:
//
//     WasmRuntimeRegistry.register { WasmEdgeRuntime() }
//
// Import surface (mirrors WasmKitRuntime's): built-in WASI preview1 plus the
// `iso_hot` render imports. The swift_ffi DI transport is NOT bridged;
// The swift_ffi DI transport is not bridged (features see an empty
// dependency dictionary); legacy flag/track stubs remain only for the
// simple `iso_host` ABI. macOS-only (prebuilt SDK in MODULE.bazel).

#if canImport(CWasmEdge)

import CWasmEdge
import Foundation
import SwiftFFIWasmHost
import IsomerWasmRuntime

public enum WasmEdgeError: Error, CustomStringConvertible {
    case launchFailed(String)
    case callFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let m): return "WasmEdgeRuntime launch failed: \(m)"
        case .callFailed(let m): return "WasmEdgeRuntime call failed: \(m)"
        }
    }
}

@MainActor
public final class WasmEdgeRuntime: WasmRuntime {
    private final class Callbacks {
        var onRenderTree: ([UInt8]) -> Void = { _ in }
        var onLog: (String) -> Void = { _ in }
        var epochMillis: () -> Double = { 0 }
        var onScheduleRender: () -> Void = {}
        var onPlatformCommand: (String, String) -> Void = { _, _ in }
        var hostValue: (String) -> String? = { _ in nil }
    }

    private var vm: OpaquePointer?
    private var hostModule: OpaquePointer?
    private let callbacks = Callbacks()

    public init() {}

    deinit {
        if let vm { WasmEdge_VMDelete(vm) }
        if let hostModule { WasmEdge_ModuleInstanceDelete(hostModule) }
    }

    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        callbacks.onRenderTree = hostImports.onRenderTree
        callbacks.onLog = hostImports.onLog
        callbacks.epochMillis = hostImports.epochMillis
        callbacks.onScheduleRender = hostImports.onScheduleRender
        callbacks.onPlatformCommand = hostImports.onPlatformCommand
        callbacks.hostValue = hostImports.hostValue

        let config = WasmEdge_ConfigureCreate()
        defer { WasmEdge_ConfigureDelete(config) }
        WasmEdge_ConfigureAddHostRegistration(config, WasmEdge_HostRegistration_Wasi)

        let vm = WasmEdge_VMCreate(config, nil)
        self.vm = vm

        try registerHostModule(vm: vm)

        var result = wasm.withUnsafeBufferPointer { buf in
            WasmEdge_VMLoadWasmFromBuffer(vm, buf.baseAddress, UInt32(buf.count))
        }
        try check(result, "load")
        result = WasmEdge_VMValidate(vm)
        try check(result, "validate")
        result = WasmEdge_VMInstantiate(vm)
        try check(result, "instantiate")

        // The reactor convention: run its initializer if exported.
        _ = try? call("_initialize", [])
    }


    @discardableResult
    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard let vm else { return nil }
        let fnName = WasmEdge_StringCreateByCString(name)
        defer { WasmEdge_StringDelete(fnName) }

        // Match the export's true arity (execute rejects mismatches).
        let type = WasmEdge_VMGetFunctionType(vm, fnName)
        let returnCount = type.map { Int(WasmEdge_FunctionTypeGetReturnsLength($0)) } ?? 0

        let params = args.map { scalar -> WasmEdge_Value in
            switch scalar {
            case .i32(let x): return WasmEdge_ValueGenI32(x)
            case .i64(let x): return WasmEdge_ValueGenI64(x)
            case .f32(let x): return WasmEdge_ValueGenF32(x)
            case .f64(let x): return WasmEdge_ValueGenF64(x)
            }
        }
        var returns = [WasmEdge_Value](repeating: WasmEdge_ValueGenI32(0), count: max(returnCount, 1))
        let result = params.withUnsafeBufferPointer { p in
            returns.withUnsafeMutableBufferPointer { r in
                WasmEdge_VMExecute(
                    vm, fnName, p.baseAddress, UInt32(p.count),
                    r.baseAddress, UInt32(returnCount))
            }
        }
        guard WasmEdge_ResultOK(result) else {
            throw WasmEdgeError.callFailed(
                "\(name): \(String(cString: WasmEdge_ResultGetMessage(result)))")
        }
        return returnCount > 0 ? .i32(WasmEdge_ValueGetI32(returns[0])) : nil
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard len > 0, let base = memoryPointer(ptr, len) else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: Int(len)))
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard !bytes.isEmpty, let base = memoryPointer(ptr, UInt32(bytes.count)) else { return }
        bytes.withUnsafeBufferPointer { buf in
            UnsafeMutablePointer(mutating: base).update(from: buf.baseAddress!, count: buf.count)
        }
    }

    private func memoryPointer(_ offset: UInt32, _ len: UInt32) -> UnsafeMutablePointer<UInt8>? {
        guard let vm, let active = WasmEdge_VMGetActiveModule(vm) else { return nil }
        let memName = WasmEdge_StringCreateByCString("memory")
        defer { WasmEdge_StringDelete(memName) }
        guard let memory = WasmEdge_ModuleInstanceFindMemory(active, memName) else { return nil }
        return WasmEdge_MemoryInstanceGetPointer(memory, UInt64(offset), UInt64(len))
    }

    // MARK: - Host module ("iso_hot" + "iso_host")

    private func registerHostModule(vm: OpaquePointer?) throws {
        let moduleName = WasmEdge_StringCreateByCString("iso_hot")
        let module = WasmEdge_ModuleInstanceCreate(moduleName)
        WasmEdge_StringDelete(moduleName)
        hostModule = module
        let env = Unmanaged.passUnretained(callbacks).toOpaque()

        let i32 = WasmEdge_ValTypeGenI32()
        let f64 = WasmEdge_ValTypeGenF64()

        func add(
            _ mod: OpaquePointer?, _ name: String,
            params: [WasmEdge_ValType], results: [WasmEdge_ValType],
            _ body: @escaping WasmEdge_HostFunc_t
        ) {
            let type = params.withUnsafeBufferPointer { p in
                results.withUnsafeBufferPointer { r in
                    WasmEdge_FunctionTypeCreate(
                        p.baseAddress, UInt32(p.count), r.baseAddress, UInt32(r.count))
                }
            }
            let function = WasmEdge_FunctionInstanceCreate(type, body, env, 0)
            WasmEdge_FunctionTypeDelete(type)
            let fnName = WasmEdge_StringCreateByCString(name)
            WasmEdge_ModuleInstanceAddFunction(mod, fnName, function)
            WasmEdge_StringDelete(fnName)
        }

        // SwiftWasm @_extern(wasm) imports carry two trailing swiftcc context
        // i32s — signatures as the reactor declares them: (iiii), (ii)F, etc.
        add(module, "render_tree", params: [i32, i32, i32, i32], results: []) { data, frame, input, _ in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            cbs.onRenderTree(WasmEdgeRuntime.frameBytes(frame, input![0], input![1]))
            return WasmEdge_Result(Code: 0)
        }
        add(module, "log", params: [i32, i32, i32, i32], results: []) { data, frame, input, _ in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            let bytes = WasmEdgeRuntime.frameBytes(frame, input![0], input![1])
            cbs.onLog(String(decoding: bytes, as: UTF8.self))
            return WasmEdge_Result(Code: 0)
        }
        add(module, "platform_command", params: [i32, i32, i32, i32, i32, i32], results: []) { data, frame, input, _ in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            let key = WasmEdgeRuntime.frameBytes(frame, input![0], input![1])
            let value = WasmEdgeRuntime.frameBytes(frame, input![2], input![3])
            cbs.onPlatformCommand(String(decoding: key, as: UTF8.self), String(decoding: value, as: UTF8.self))
            return WasmEdge_Result(Code: 0)
        }
        add(module, "host_value", params: [i32, i32, i32, i32, i32, i32], results: [i32]) { data, frame, input, output in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            let key = WasmEdgeRuntime.frameBytes(frame, input![0], input![1])
            var length: Int32 = -1
            if let value = cbs.hostValue(String(decoding: key, as: UTF8.self)) {
                let bytes = Array(value.utf8)
                length = Int32(bytes.count)
                let out = UInt32(bitPattern: WasmEdge_ValueGetI32(input![2]))
                let capacity = UInt32(bitPattern: WasmEdge_ValueGetI32(input![3]))
                if !bytes.isEmpty, bytes.count <= Int(capacity), let memory = WasmEdge_CallingFrameGetMemoryInstance(frame, 0),
                   let base = WasmEdge_MemoryInstanceGetPointer(memory, UInt64(out), UInt64(bytes.count)) {
                    bytes.withUnsafeBufferPointer { base.update(from: $0.baseAddress!, count: bytes.count) }
                }
            }
            output![0] = WasmEdge_ValueGenI32(length)
            return WasmEdge_Result(Code: 0)
        }
        add(module, "epoch_millis", params: [i32, i32], results: [f64]) { data, _, _, output in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            output![0] = WasmEdge_ValueGenF64(cbs.epochMillis())
            return WasmEdge_Result(Code: 0)
        }
        add(module, "schedule_render", params: [i32, i32], results: []) { data, _, _, _ in
            Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue().onScheduleRender()
            return WasmEdge_Result(Code: 0)
        }

        var result = WasmEdge_VMRegisterModuleFromImport(vm, module)
        try check(result, "register iso_hot")

        // The simple iso_host DI surface (flag/track).
        let hostName = WasmEdge_StringCreateByCString("iso_host")
        let isoHost = WasmEdge_ModuleInstanceCreate(hostName)
        WasmEdge_StringDelete(hostName)
        add(isoHost, "flag", params: [i32, i32, i32, i32], results: [i32]) { data, frame, input, output in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            let name = String(decoding: WasmEdgeRuntime.frameBytes(frame, input![0], input![1]), as: UTF8.self)
            output![0] = WasmEdge_ValueGenI32(0)
            return WasmEdge_Result(Code: 0)
        }
        add(isoHost, "track", params: [i32, i32, i32, i32], results: []) { data, frame, input, _ in
            let cbs = Unmanaged<Callbacks>.fromOpaque(data!).takeUnretainedValue()
            let event = String(decoding: WasmEdgeRuntime.frameBytes(frame, input![0], input![1]), as: UTF8.self)
            _ = event
            return WasmEdge_Result(Code: 0)
        }
        result = WasmEdge_VMRegisterModuleFromImport(vm, isoHost)
        try check(result, "register iso_host")
        // Ownership of both modules stays here (deinit deletes hostModule; the
        // second is intentionally leaked for the process-lifetime experiment).
    }

    /// Reads guest memory from inside a host callback via the calling frame.
    private static func frameBytes(
        _ frame: OpaquePointer?, _ ptrValue: WasmEdge_Value, _ lenValue: WasmEdge_Value
    ) -> [UInt8] {
        let ptr = UInt32(bitPattern: WasmEdge_ValueGetI32(ptrValue))
        let len = UInt32(bitPattern: WasmEdge_ValueGetI32(lenValue))
        guard len > 0, let memory = WasmEdge_CallingFrameGetMemoryInstance(frame, 0),
            let base = WasmEdge_MemoryInstanceGetPointer(memory, UInt64(ptr), UInt64(len))
        else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: Int(len)))
    }

    private func check(_ result: WasmEdge_Result, _ what: String) throws {
        guard !WasmEdge_ResultOK(result) else { return }
        throw WasmEdgeError.launchFailed(
            "\(what): \(String(cString: WasmEdge_ResultGetMessage(result)))")
    }
}

#endif
