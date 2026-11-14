import Foundation

// `bridge`: the glue between the wasm2c-compiled native part and WasmKit.
// It replaced a Python script (gen_mixed.py) whose outputs it matched byte
// for byte, but for the generated files' first lines, which name it.
//
//   mixed_glue.c  the native part's imports (each calls iso_mixed_import_call),
//                 a call for every exported function (by index, through a
//                 per-signature caller), calls through a native table slot,
//                 trampolines for slots holding interpreted functions (each
//                 calls iso_mixed_slot_call), and wasm_rt_*_memory over the
//                 memory WasmKit owns.
//   mixed_glue.h  the C API the Swift side uses.
//   shim.wat      a WasmKit module that imports the shared memory and table
//                 and the host imports, and exports `imp_<i>` (calls import
//                 i: the host functions find memory through the calling
//                 instance) and `ci_<sig>` (call_indirect on the shared table,
//                 for native code calling an interpreted function).
//
// A signature is written `<params>:<results>`, a letter a value: i i32,
// I i64, f f32, F f64.

enum Bridge {
    struct Output {
        var glueC: String
        var glueH: String
        var shimWAT: String
        var summary: String
    }

    private struct Import {
        let module: String
        let name: String
        let cName: String
        let sig: String
        let ret: String
    }

    private struct Export {
        let name: String
        let cName: String
        let sig: String
    }

    private struct Global {
        let name: String
        let cName: String
    }

    /// A Python re pattern of the kind gen_mixed.py used (greedy groups,
    /// \w, literals), on one line of the header.
    private struct Pattern {
        let regex: NSRegularExpression

        init(_ pattern: String) {
            // `.` matches anything (Python's only refuses \n, and lines have none).
            regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        }

        /// re.match: anchored at the start, not the end. The groups, or nil.
        func match(_ s: String) -> [String]? { find(s, options: [.anchored]) }

        /// re.search.
        func search(_ s: String) -> [String]? { find(s, options: []) }

        private func find(_ s: String, options: NSRegularExpression.MatchingOptions) -> [String]? {
            let ns = s as NSString
            guard let m = regex.firstMatch(in: s, options: options, range: NSRange(location: 0, length: ns.length)) else {
                return nil
            }
            return (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static let valueLetters: [UInt8: String] = [0x7F: "i", 0x7E: "I", 0x7D: "f", 0x7C: "F"]
    private static let letterOfC: [String: String] = ["u32": "i", "u64": "I", "f32": "f", "f64": "F"]
    private static let cType: [Character: String] = ["i": "u32", "I": "u64", "f": "f32", "F": "f64"]
    private static let watType: [String: String] = ["i": "i32", "I": "i64", "f": "f32", "F": "f64"]
    private static let rtType: [Character: String] = ["i": "WASM_RT_I32", "I": "WASM_RT_I64", "f": "WASM_RT_F32", "F": "WASM_RT_F64"]

    /// The module's type section as signatures.
    private static func types(_ b: [UInt8]) throws -> [String] {
        var types: [String] = []
        var r = WasmReader(b, at: 8)
        while !r.atEnd {
            let id = try r.byte()
            let size = try r.uleb()
            let start = r.position
            if id == 1 {
                for _ in 0..<max(try r.uleb(), 0) {
                    guard try r.byte() == 0x60 else { throw ToolError("a type that is not a function type") }
                    func values() throws -> String {
                        var out = ""
                        for k in 0..<max(try r.uleb(), 0) {
                            let v = try r.byte()
                            guard let letter = valueLetters[v] else {
                                throw ToolError("type \(types.count + 1)'s value \(k) is \(Wasm.hex(v)), not i32, i64, f32 or f64")
                            }
                            out += letter
                        }
                        return out
                    }
                    let params = try values()
                    let results = try values()
                    types.append(params + ":" + results)
                }
            }
            r.position = start + size
        }
        return types
    }

    private static func cTypeName(_ t: Character) -> String { cType[t]! }

    private static func watTypeName(_ results: String) throws -> String {
        guard let t = watType[results] else {
            throw ToolError("signature results \"\(results)\": the shim takes one value at most")
        }
        return t
    }

    /// A C declaration's signature: its return type and its arguments' types.
    private static func signature(ret: String, args: [String]) throws -> String {
        var params = ""
        for a in args {
            let t = PythonText.strip(a)
            guard let letter = letterOfC[t] else { throw ToolError("argument type \(t) is not u32, u64, f32 or f64") }
            params += letter
        }
        if ret == "void" { return params + ":" }
        guard let letter = letterOfC[ret] else { throw ToolError("return type \(ret) is not u32, u64, f32 or f64") }
        return params + ":" + letter
    }

    /// The arguments after the instance: `, u32, f64` → ["u32", "f64"].
    private static func arguments(_ s: String) -> [String] {
        PythonText.split(s, on: ",").filter { !PythonText.strip($0).isEmpty }
    }

    private static func cArgs(_ params: String) -> String {
        params.enumerated().map { k, t in "\(cTypeName(t)) a\(k)" }.joined(separator: ", ")
    }

    private static func toSlots(_ params: String) -> String {
        params.enumerated().map { k, t in
            t == "i" || t == "I"
                ? "  s[\(k)] = (uint64_t)a\(k);"
                : "  memcpy(&s[\(k)], &a\(k), sizeof(a\(k)));"
        }.joined(separator: "\n")
    }

    private static func fromSlot(_ t: Character, _ expr: String) -> String {
        t == "i" || t == "I" ? "(\(cTypeName(t)))\(expr)" : "iso_mixed_\(cTypeName(t))_of(\(expr))"
    }

    private static func callWith(_ params: String) -> String {
        params.enumerated().map { k, t in fromSlot(t, "a[\(k)]") }.joined(separator: ", ")
    }

    private static func storeResult(_ results: String, _ call: String) -> String {
        guard let t = results.first else { return "  \(call);" }
        if t == "i" || t == "I" { return "  r[0] = (uint64_t)\(call);" }
        return "  { \(cTypeName(t)) v = \(call); r[0] = 0; memcpy(&r[0], &v, sizeof v); }"
    }

    private static func cString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func halves(_ sig: String) -> (params: String, results: String) {
        let fields = PythonText.split(sig, on: ":")
        return (fields[0], fields[1])
    }

    static func generate(hotWasm: String, hotHeader: String) throws -> Output {
        let types = try types(try FileIO.read(hotWasm))

        // What wasm2c declared: imports, exported functions and globals.
        let header = PythonText.split(try PythonText.readText(hotHeader), on: "\n")
        let importComment = Pattern(#"/\* import: '(.*)' '(.*)' \*/"#)
        let importDecl = Pattern(#"(\w+) (w2c_\w+)\(struct \w+\*(.*)\);"#)
        let exportComment = Pattern(#"/\* export: '(.*)' \*/"#)
        let globalDecl = Pattern(#"(u32|u64|f32|f64)\* (w2c_\w+)\(w2c_hot\* instance\);"#)
        let functionDecl = Pattern(#"(\w+) (w2c_hot_\w+)\(w2c_hot\*(.*)\);"#)
        let structType = Pattern(#"\((struct \w+)\*"#)
        var imports: [Import] = []
        var exports: [Export] = []
        var globals: [Global] = []
        for (i, line) in header.enumerated() {
            if let m = importComment.match(line) {
                guard i + 1 < header.count, let d = importDecl.match(header[i + 1]) else {
                    throw ToolError("\(hotHeader): no declaration after line \(i + 1)'s import comment")
                }
                imports.append(Import(
                    module: m[1], name: m[2], cName: d[2],
                    sig: try signature(ret: d[1], args: arguments(d[3])), ret: d[1]))
            }
            if let m = exportComment.match(line) {
                guard i + 1 < header.count else {
                    throw ToolError("\(hotHeader): no declaration after line \(i + 1)'s export comment")
                }
                let decl = header[i + 1]
                if let g = globalDecl.match(decl) {
                    globals.append(Global(name: m[1], cName: g[2]))
                    continue
                }
                if let d = functionDecl.match(decl), ["void", "u32", "u64", "f32", "f64"].contains(d[1]) {
                    exports.append(Export(name: m[1], cName: d[2], sig: try signature(ret: d[1], args: arguments(d[3]))))
                }
            }
        }

        // Every signature, sorted by code point (Python's sorted()).
        let sigs = Set(types).union(imports.map(\.sig)).union(exports.map(\.sig))
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
        let sigIndex = Dictionary(uniqueKeysWithValues: sigs.enumerated().map { ($1, $0) })

        var c: [String] = []
        c.append("""
            // Generated by tools/wasm_mixed: the bridge between the wasm2c-compiled hot
            // module and WasmKit. Values cross as 64-bit slots (an f32 or f64 by its bits).
            #include <stdint.h>
            #include <stdlib.h>
            #include <string.h>
            #include <stdio.h>
            #include "hot.h"
            #include "mixed_glue.h"

            static inline f32 iso_mixed_f32_of(uint64_t s) { f32 v; memcpy(&v, &s, sizeof v); return v; }
            static inline f64 iso_mixed_f64_of(uint64_t s) { f64 v; memcpy(&v, &s, sizeof v); return v; }

            static w2c_hot iso_mixed_instance;
            static wasm_rt_func_type_t iso_mixed_func_types[\(sigs.count)];

            """)

        // Signatures.
        c.append("const uint32_t iso_mixed_sig_count = \(sigs.count);")
        c.append("const char* const iso_mixed_sigs[] = {\(sigs.map { "\"\($0)\"" }.joined(separator: ", "))};")

        // Imports.
        c.append("const uint32_t iso_mixed_import_count = \(imports.count);")
        c.append("const char* const iso_mixed_import_modules[] = {\(imports.map { "\"\($0.module)\"" }.joined(separator: ", "))};")
        c.append("const char* const iso_mixed_import_names[] = {\(imports.map { "\"\($0.name)\"" }.joined(separator: ", "))};")
        c.append("const uint32_t iso_mixed_import_sigs[] = {\(imports.map { String(sigIndex[$0.sig]!) }.joined(separator: ", "))};")
        for (k, imp) in imports.enumerated() {
            let (params, results) = halves(imp.sig)
            // The instance struct type from the declaration itself.
            guard let decl = header.first(where: { $0.range(of: " \(imp.cName)(", options: .literal) != nil }),
                  let st = structType.search(decl) else {
                throw ToolError("\(hotHeader): no declaration of \(imp.cName) with its instance's struct")
            }
            c.append("\(imp.ret) \(imp.cName)(\(st[1])* self\(params.isEmpty ? "" : ", ")\(cArgs(params))) {")
            c.append("  uint64_t s[\(max(params.count, 1))] = {0}, r[1] = {0};")
            c.append(toSlots(params))
            c.append("  iso_mixed_import_call(\(k), s, r);")
            if let t = results.first { c.append("  return \(fromSlot(t, "r[0]"));") }
            c.append("}")
        }

        // Exports: functions by index; globals by index.
        c.append("const uint32_t iso_mixed_export_count = \(exports.count);")
        c.append("const char* const iso_mixed_export_names[] = {\(exports.map { cString($0.name) }.joined(separator: ", "))};")
        c.append("const uint32_t iso_mixed_export_sigs[] = {\(exports.map { String(sigIndex[$0.sig]!) }.joined(separator: ", "))};")
        c.append("static void* const iso_mixed_export_fns[] = {\(exports.map { "(void*)\($0.cName)" }.joined(separator: ", "))};")
        c.append("const uint32_t iso_mixed_global_count = \(globals.count);")
        c.append("const char* const iso_mixed_global_names[] = {\(globals.map { cString($0.name) }.joined(separator: ", "))};")
        c.append("uint64_t iso_mixed_global_value(uint32_t index) {\n  switch (index) {")
        for (k, g) in globals.enumerated() {
            c.append("  case \(k): return (uint64_t)*\(g.cName)(&iso_mixed_instance);")
        }
        c.append("  }\n  return 0;\n}")
        c.append("uint32_t* iso_mixed_stack_pointer(void) { return w2c_hot_0x5F_stack_pointer(&iso_mixed_instance); }")

        // Per-signature callers: an exported function (instance first) or a
        // funcref (its module_instance first).
        for (k, s) in sigs.enumerated() {
            let (params, results) = halves(s)
            let ret = results.first.map(cTypeName) ?? "void"
            let comma = params.isEmpty ? "" : ", "
            let fnType = "\(ret) (*)(void*\(comma)\(params.map(cTypeName).joined(separator: ", ")))"
            let call = "((\(fnType))fn)(self\(comma)\(callWith(params)))"
            c.append("static void iso_mixed_call_sig_\(k)(void* fn, void* self, const uint64_t* a, uint64_t* r) {\n\(storeResult(results, call))\n}")
            // The trampoline a native slot holds for an interpreted function:
            // its module_instance is the slot number.
            c.append("static \(ret) iso_mixed_tramp_\(k)(void* ctx\(comma)\(cArgs(params))) {")
            c.append("  uint64_t s[\(max(params.count, 1))] = {0}, r[1] = {0};")
            c.append(toSlots(params))
            c.append("  iso_mixed_slot_call((uint32_t)(uintptr_t)ctx, \(k), s, r);")
            if let t = results.first { c.append("  return \(fromSlot(t, "r[0]"));") }
            c.append("}")
        }
        c.append("typedef void (*iso_mixed_caller_t)(void*, void*, const uint64_t*, uint64_t*);")
        c.append("static const iso_mixed_caller_t iso_mixed_callers[] = {\(sigs.indices.map { "iso_mixed_call_sig_\($0)" }.joined(separator: ", "))};")
        c.append("static void* const iso_mixed_tramps[] = {\(sigs.indices.map { "(void*)iso_mixed_tramp_\($0)" }.joined(separator: ", "))};")
        c.append(glueRuntime)
        for (k, s) in sigs.enumerated() {
            let (params, results) = halves(s)
            let vals = (params.map { rtType[$0]! } + results.map { rtType[$0]! }).joined(separator: ", ")
            c.append("  iso_mixed_func_types[\(k)] = wasm2c_hot_get_func_type(\(params.count), \(results.count)\(vals.isEmpty ? "" : ", ")\(vals));")
        }
        c.append("""
              wasm2c_hot_instantiate(&iso_mixed_instance, &iso_mixed_env, &iso_mixed_iso_hot, &iso_mixed_swift_ffi, &iso_mixed_wasi);
            }

            """)

        // The WasmKit shim. Imports from `env` are resolved to side modules on
        // the Swift side.
        var w = ["(module"]
        func paramList(_ params: String) -> String {
            params.isEmpty ? "" : "(param " + params.map { watType[String($0)]! }.joined(separator: " ") + ")"
        }
        func resultList(_ results: String) throws -> String {
            results.isEmpty ? "" : "(result \(try watTypeName(results)))"
        }
        for (k, imp) in imports.enumerated() where imp.module != "env" {
            let (params, results) = halves(imp.sig)
            w.append("  (import \"\(imp.module)\" \"\(imp.name)\" (func $i\(k) \(paramList(params)) \(try resultList(results))))")
        }
        w.append("  (import \"env\" \"memory\" (memory 0))")
        w.append("  (import \"env\" \"table\" (table 0 funcref))")
        w.append("  (export \"memory\" (memory 0))")
        for (k, imp) in imports.enumerated() where imp.module != "env" {
            let (params, results) = halves(imp.sig)
            let ps = params.map { "(param \(watType[String($0)]!))" }.joined(separator: " ")
            let gets = (0..<params.count).map { "(local.get \($0))" }.joined(separator: " ")
            w.append("  (func (export \"imp_\(k)\") \(ps) \(try resultList(results)) (call $i\(k) \(gets)))")
        }
        for (k, s) in sigs.enumerated() {
            let (params, results) = halves(s)
            w.append("  (type $t\(k) (func \(paramList(params)) \(try resultList(results))))")
            let ps = params.map { "(param \(watType[String($0)]!))" }.joined(separator: " ")
            let gets = (0..<params.count).map { "(local.get \($0 + 1))" }.joined(separator: " ")
            w.append("  (func (export \"ci_\(k)\") (param i32) \(ps) \(try resultList(results)) (call_indirect (type $t\(k)) \(gets) (local.get 0)))")
        }
        w.append(")")

        return Output(
            glueC: c.joined(separator: "\n") + "\n",
            glueH: glueHeader,
            shimWAT: w.joined(separator: "\n") + "\n",
            summary: "\(sigs.count) signatures, \(imports.count) imports, \(exports.count) exported functions, \(globals.count) exported globals")
    }

    /// `wasm_mixed bridge <hot.wasm> <hot.h> <out dir>`: all three files there.
    static func run(hotWasm: String, hotHeader: String, outDir: String) throws {
        let output = try generate(hotWasm: hotWasm, hotHeader: hotHeader)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try FileIO.write(outDir + "/mixed_glue.c", output.glueC)
        try FileIO.write(outDir + "/mixed_glue.h", output.glueH)
        try FileIO.write(outDir + "/shim.wat", output.shimWAT)
        print(output.summary)
    }

    /// mixed_glue.c's fixed middle: lookups, the native table, memory over
    /// WasmKit's, the trap handler, and the start of iso_mixed_instantiate.
    private static let glueRuntime = #"""

        const char* iso_mixed_sig(uint32_t i) { return iso_mixed_sigs[i]; }
        const char* iso_mixed_import_module(uint32_t i) { return iso_mixed_import_modules[i]; }
        const char* iso_mixed_import_name(uint32_t i) { return iso_mixed_import_names[i]; }
        uint32_t iso_mixed_import_sig(uint32_t i) { return iso_mixed_import_sigs[i]; }
        const char* iso_mixed_export_name(uint32_t i) { return iso_mixed_export_names[i]; }
        uint32_t iso_mixed_export_sig(uint32_t i) { return iso_mixed_export_sigs[i]; }
        const char* iso_mixed_global_name(uint32_t i) { return iso_mixed_global_names[i]; }

        void iso_mixed_call_export(uint32_t index, const uint64_t* a, uint64_t* r) {
          iso_mixed_callers[iso_mixed_export_sigs[index]](iso_mixed_export_fns[index], &iso_mixed_instance, a, r);
        }

        // The native table.
        static wasm_rt_funcref_table_t* iso_mixed_table(void) { return w2c_hot_0x5F_indirect_function_table(&iso_mixed_instance); }
        uint32_t iso_mixed_table_size(void) { return iso_mixed_table()->size; }
        void iso_mixed_table_grow(uint32_t size) {
          wasm_rt_funcref_table_t* t = iso_mixed_table();
          if (size > t->size) wasm_rt_grow_funcref_table(t, size - t->size, wasm_rt_funcref_null_value);
        }
        // The signature of a native function in a slot: -1 for a null slot, -2 for
        // a trampoline (an interpreted function) or a type the bridge doesn't know.
        int32_t iso_mixed_table_native_sig(uint32_t slot) {
          wasm_rt_funcref_table_t* t = iso_mixed_table();
          if (slot >= t->size || t->data[slot].func == NULL) return -1;
          for (uint32_t k = 0; k < iso_mixed_sig_count; k++)
            if (t->data[slot].func == iso_mixed_tramps[k]) return -2;
          for (uint32_t k = 0; k < iso_mixed_sig_count; k++)
            if (iso_mixed_func_types[k] && t->data[slot].func_type &&
                (t->data[slot].func_type == iso_mixed_func_types[k] ||
                 memcmp(t->data[slot].func_type, iso_mixed_func_types[k], 32) == 0)) return (int32_t)k;
          return -2;
        }
        void iso_mixed_table_set_interpreted(uint32_t slot, uint32_t sig) {
          wasm_rt_funcref_table_t* t = iso_mixed_table();
          t->data[slot] = (wasm_rt_funcref_t){iso_mixed_func_types[sig], (wasm_rt_function_ptr_t)iso_mixed_tramps[sig], {NULL}, (void*)(uintptr_t)slot};
        }
        void iso_mixed_call_native_slot(uint32_t slot, uint32_t sig, const uint64_t* a, uint64_t* r) {
          wasm_rt_funcref_t f = iso_mixed_table()->data[slot];
          iso_mixed_callers[sig]((void*)f.func, f.module_instance, a, r);
        }

        // Memory: WasmKit's, in place (its base never moves: a reserved memory).
        void wasm_rt_allocate_memory(wasm_rt_memory_t* m, uint64_t initial_pages, uint64_t max_pages, bool is64, uint32_t page_size) {
          m->page_size = page_size;
          m->max_pages = max_pages;
          m->is64 = is64;
          iso_mixed_memory_attach(m, initial_pages);
        }
        uint64_t wasm_rt_grow_memory(wasm_rt_memory_t* m, uint64_t pages) {
          uint64_t old = iso_mixed_memory_grow(pages);
          iso_mixed_memory_sync(m);
          return old;
        }
        void wasm_rt_free_memory(wasm_rt_memory_t* m) {}
        wasm_rt_memory_t* iso_mixed_memory(void) { return w2c_hot_memory(&iso_mixed_instance); }
        void iso_mixed_memory_sync(wasm_rt_memory_t* m) {
          m->data = iso_mixed_memory_base();
          m->size = iso_mixed_memory_byte_count();
          m->pages = m->size / m->page_size;
        #ifdef ISO_MIXED_MEMORY_DATA_END
          // WABT 1.0.41's memory has an end its bounds checks read; 1.0.37's
          // (the pinned one) hasn't.
          m->data_end = m->data + m->size;
        #endif
        }

        void iso_mixed_trap_handler(wasm_rt_trap_t code) {
          fprintf(stderr, "[mixed] native trap: %s\n", wasm_rt_strerror(code));
          abort();
        }

        struct w2c_env { int unused; };
        struct w2c_iso__hot { int unused; };
        struct w2c_swift__ffi { int unused; };
        struct w2c_wasi__snapshot__preview1 { int unused; };
        static struct w2c_env iso_mixed_env;
        static struct w2c_iso__hot iso_mixed_iso_hot;
        static struct w2c_swift__ffi iso_mixed_swift_ffi;
        static struct w2c_wasi__snapshot__preview1 iso_mixed_wasi;

        void iso_mixed_instantiate(void) {
          wasm_rt_init();
        """#

    private static let glueHeader = """
        // Generated by tools/wasm_mixed.
        #pragma once
        #include <stdint.h>
        #include <stdbool.h>
        #include "wasm-rt.h"

        extern const uint32_t iso_mixed_sig_count;
        extern const char* const iso_mixed_sigs[];
        extern const uint32_t iso_mixed_import_count;
        extern const char* const iso_mixed_import_modules[];
        extern const char* const iso_mixed_import_names[];
        extern const uint32_t iso_mixed_import_sigs[];
        extern const uint32_t iso_mixed_export_count;
        extern const char* const iso_mixed_export_names[];
        extern const uint32_t iso_mixed_export_sigs[];
        extern const uint32_t iso_mixed_global_count;
        extern const char* const iso_mixed_global_names[];

        const char* iso_mixed_sig(uint32_t index);
        const char* iso_mixed_import_module(uint32_t index);
        const char* iso_mixed_import_name(uint32_t index);
        uint32_t iso_mixed_import_sig(uint32_t index);
        const char* iso_mixed_export_name(uint32_t index);
        uint32_t iso_mixed_export_sig(uint32_t index);
        const char* iso_mixed_global_name(uint32_t index);

        void iso_mixed_instantiate(void);
        void iso_mixed_call_export(uint32_t index, const uint64_t* args, uint64_t* results);
        uint64_t iso_mixed_global_value(uint32_t index);
        uint32_t* iso_mixed_stack_pointer(void);
        uint32_t iso_mixed_table_size(void);
        void iso_mixed_table_grow(uint32_t size);
        int32_t iso_mixed_table_native_sig(uint32_t slot);
        void iso_mixed_table_set_interpreted(uint32_t slot, uint32_t sig);
        void iso_mixed_call_native_slot(uint32_t slot, uint32_t sig, const uint64_t* args, uint64_t* results);
        wasm_rt_memory_t* iso_mixed_memory(void);
        void iso_mixed_memory_sync(wasm_rt_memory_t* memory);

        // The Swift side's (@_cdecl).
        void iso_mixed_import_call(uint32_t index, const uint64_t* args, uint64_t* results);
        void iso_mixed_slot_call(uint32_t slot, uint32_t sig, const uint64_t* args, uint64_t* results);
        void iso_mixed_memory_attach(wasm_rt_memory_t* memory, uint64_t initial_pages);
        uint64_t iso_mixed_memory_grow(uint64_t pages);
        uint8_t* iso_mixed_memory_base(void);
        uint64_t iso_mixed_memory_byte_count(void);

        """
}
