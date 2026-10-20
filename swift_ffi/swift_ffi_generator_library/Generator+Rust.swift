import Foundation
import SwiftFFIIRLibrary

// The Rust *consumer* backend (`rust` kind): idiomatic Rust bindings calling
// a bridged module across its C ABI — the Rust peer of the Swift/C++
// consumer backends (docs/bridge_v2.md). Self-contained: the blob codec is
// inlined, so the generated crate depends only on the bridge cc_library.
//
// v1 surface: scalars, String, Vec<u8>, @ExportedStruct values (blob), and
// throwing functions (Result<T, String>). Closures / Lazy / generics /
// interfaces / async are skipped with a comment.
extension Generator {
    func rustType(_ swift: String) -> String {
        switch swift {
        case "Int": return "i64"
        case "Int32": return "i32"
        case "Double": return "f64"
        case "Bool": return "bool"
        case "String": return "String"
        case "[UInt8]": return "Vec<u8>"
        case "Void", "()": return "()"
        default: return isStruct(swift) ? swift : "()"
        }
    }

    func rustParamType(_ swift: String) -> String {
        switch swift {
        case "String": return "&str"
        case "[UInt8]": return "&[u8]"
        default: return rustType(swift)
        }
    }

    /// Whether the function fits the v1 Rust consumer surface.
    func rustRepresentable(_ function: FFIFunction) -> Bool {
        if usesV2Features(function) || function.isAsync { return false }
        let types = function.parameters.map(\.type) + [function.returnType]
        for type in types {
            switch type {
            case "Int", "Int32", "Double", "Bool", "String", "[UInt8]", "Void", "()":
                continue
            default:
                if !isStruct(type) { return false }
            }
        }
        return true
    }

    func emitRust(_ module: FFIModule, moduleName: String) -> String {
        let usesStructs = !module.structs.isEmpty

        var externs: [String] = [
            "fn swift_ffi_string_len(b: *mut c_void) -> i32;",
            "fn swift_ffi_string_copy(b: *mut c_void, dest: *mut c_void);",
            "fn swift_ffi_string_release(b: *mut c_void);",
        ]
        var body = ""

        for function in module.functions {
            guard rustRepresentable(function) else {
                body += "\n// `\(function.name)` is outside the v1 Rust consumer surface (closures/Lazy/generics/interfaces/async).\n"
                continue
            }
            var cParams: [String] = []
            var callArgs: [String] = []
            var prelude: [String] = []
            for (index, parameter) in function.parameters.enumerated() {
                switch parameter.type {
                case "Int":
                    cParams.append("p\(index): isize")
                    callArgs.append("p\(index) as isize")
                case "Int32":
                    cParams.append("p\(index): i32")
                    callArgs.append("p\(index)")
                case "Double":
                    cParams.append("p\(index): f64")
                    callArgs.append("p\(index)")
                case "Bool":
                    cParams.append("p\(index): bool")
                    callArgs.append("p\(index)")
                case "String":
                    cParams.append("p\(index): *const c_void")
                    cParams.append("p\(index)_len: i32")
                    prelude.append("let bytes\(index) = p\(index).as_bytes();")
                    callArgs.append("bytes\(index).as_ptr() as *const c_void")
                    callArgs.append("bytes\(index).len() as i32")
                case "[UInt8]":
                    cParams.append("p\(index): *const c_void")
                    cParams.append("p\(index)_len: i32")
                    callArgs.append("p\(index).as_ptr() as *const c_void")
                    callArgs.append("p\(index).len() as i32")
                default:
                    // @ExportedStruct: a blob.
                    cParams.append("p\(index): *const c_void")
                    cParams.append("p\(index)_len: i32")
                    prelude.append("let blob\(index) = encode_\(parameter.type)(&p\(index));")
                    callArgs.append("blob\(index).as_ptr() as *const c_void")
                    callArgs.append("blob\(index).len() as i32")
                }
            }
            if function.isThrowing {
                cParams.append("error_out: *mut *mut c_void")
            }

            // The extern declaration.
            let cReturn: String
            switch function.returnType {
            case "Void", "()": cReturn = ""
            case "Int": cReturn = " -> isize"
            case "Int32": cReturn = " -> i32"
            case "Double": cReturn = " -> f64"
            case "Bool": cReturn = " -> bool"
            default: cReturn = " -> *mut c_void"
            }
            externs.append("fn \(symbol(function))(\(cParams.joined(separator: ", ")))\(cReturn);")

            // The safe wrapper.
            let params = function.parameters.enumerated()
                .map { index, parameter in "p\(index): \(rustParamType(parameter.type))" }
                .joined(separator: ", ")
            var lines = prelude
            var rawArgs = callArgs
            if function.isThrowing {
                lines.append("let mut error_box: *mut c_void = std::ptr::null_mut();")
                rawArgs.append("&mut error_box")
            }
            let call = "unsafe { \(symbol(function))(\(rawArgs.joined(separator: ", "))) }"
            let valueExpr: String
            switch function.returnType {
            case "Void", "()":
                lines.append("\(call);")
                valueExpr = "()"
            case "Int":
                lines.append("let raw = \(call);")
                valueExpr = "raw as i64"
            case "Int32", "Double", "Bool":
                lines.append("let raw = \(call);")
                valueExpr = "raw"
            case "String":
                lines.append("let raw = \(call);")
                valueExpr = "String::from_utf8(take_box(raw)).unwrap()"
            case "[UInt8]":
                lines.append("let raw = \(call);")
                valueExpr = "take_box(raw)"
            default:
                lines.append("let raw = \(call);")
                valueExpr = "decode_\(function.returnType)(&mut BlobReader::new(&take_box(raw)))"
            }
            let ret: String
            if function.isThrowing {
                ret = " -> Result<\(rustType(function.returnType)), String>"
                lines.append("if !error_box.is_null() {")
                lines.append("    return Err(String::from_utf8(take_box(error_box)).unwrap());")
                lines.append("}")
                lines.append("Ok(\(valueExpr))")
            } else if isVoid(function.returnType) {
                ret = ""
            } else {
                ret = " -> \(rustType(function.returnType))"
                lines.append(valueExpr)
            }
            body += """

                pub fn \(function.name)(\(params))\(ret) {
                \(lines.map { "    \($0)\n" }.joined())}

                """
        }

        // Structs + their blob codecs.
        var structsOut = ""
        for structure in module.structs {
            let fields = structure.fields
                .map { "    pub \($0.name): \(rustType($0.type))," }
                .joined(separator: "\n")
            var encodes: [String] = [
                "w.type_header(7, \"\(structure.name)\");",
                "w.i64(\(structure.fields.count));",
            ]
            var decodes: [String] = [
                "let (_tag, aux) = r.header();",
                "let _name = r.bytes(aux as usize);",
                "let _count = r.i64();",
            ]
            var inits: [String] = []
            for field in structure.fields {
                switch field.type {
                case "Int":
                    encodes.append("w.header(1, 0); w.i64(v.\(field.name));")
                    decodes.append("r.header(); let \(field.name) = r.i64();")
                case "Int32":
                    encodes.append("w.header(2, 0); w.i64(v.\(field.name) as i64);")
                    decodes.append("r.header(); let \(field.name) = r.i64() as i32;")
                case "Double":
                    encodes.append("w.header(3, 0); w.i64(v.\(field.name).to_bits() as i64);")
                    decodes.append("r.header(); let \(field.name) = f64::from_bits(r.i64() as u64);")
                case "Bool":
                    encodes.append("w.header(4, 0); w.i64(if v.\(field.name) { 1 } else { 0 });")
                    decodes.append("r.header(); let \(field.name) = r.i64() != 0;")
                case "String":
                    encodes.append("w.header(5, 0); w.bytes_with_len(v.\(field.name).as_bytes());")
                    decodes.append("r.header(); let n = r.i64() as usize; let \(field.name) = String::from_utf8(r.bytes(n)).unwrap();")
                default:  // [UInt8]
                    encodes.append("w.header(6, 0); w.bytes_with_len(&v.\(field.name));")
                    decodes.append("r.header(); let n = r.i64() as usize; let \(field.name) = r.bytes(n);")
                }
                inits.append(field.name)
            }
            structsOut += """

                /// A field-wise copy of the producer's `\(structure.name)` value.
                #[derive(Clone, Debug, PartialEq)]
                pub struct \(structure.name) {
                \(fields)
                }

                fn encode_\(structure.name)(v: &\(structure.name)) -> Vec<u8> {
                    let mut w = BlobWriter::new();
                \(encodes.map { "    \($0)\n" }.joined())    w.data
                }

                fn decode_\(structure.name)(r: &mut BlobReader) -> \(structure.name) {
                \(decodes.map { "    \($0)\n" }.joined())    \(structure.name) { \(inits.joined(separator: ", ")) }
                }

                """
        }

        let codec = usesStructs ? """

            // --- The blob wire encoding (see swift_abi.h) ---------------------------

            struct BlobWriter {
                data: Vec<u8>,
            }

            impl BlobWriter {
                fn new() -> Self {
                    BlobWriter { data: Vec::new() }
                }
                fn i32(&mut self, v: i32) {
                    self.data.extend_from_slice(&v.to_le_bytes());
                }
                fn i64(&mut self, v: i64) {
                    self.data.extend_from_slice(&v.to_le_bytes());
                }
                fn header(&mut self, tag: i32, aux: i32) {
                    self.i32(tag);
                    self.i32(aux);
                }
                fn bytes_with_len(&mut self, bytes: &[u8]) {
                    self.i64(bytes.len() as i64);
                    self.data.extend_from_slice(bytes);
                }
                /// A STRUCT header: types are identified on the wire by NAME.
                fn type_header(&mut self, tag: i32, name: &str) {
                    self.i32(tag);
                    self.i32(name.len() as i32);
                    self.data.extend_from_slice(name.as_bytes());
                }
            }

            struct BlobReader<'a> {
                data: &'a [u8],
                cursor: usize,
            }

            impl<'a> BlobReader<'a> {
                fn new(data: &'a [u8]) -> Self {
                    BlobReader { data, cursor: 0 }
                }
                fn i32(&mut self) -> i32 {
                    let v = i32::from_le_bytes(self.data[self.cursor..self.cursor + 4].try_into().unwrap());
                    self.cursor += 4;
                    v
                }
                fn i64(&mut self) -> i64 {
                    let v = i64::from_le_bytes(self.data[self.cursor..self.cursor + 8].try_into().unwrap());
                    self.cursor += 8;
                    v
                }
                fn header(&mut self) -> (i32, i32) {
                    (self.i32(), self.i32())
                }
                fn bytes(&mut self, count: usize) -> Vec<u8> {
                    let v = self.data[self.cursor..self.cursor + count].to_vec();
                    self.cursor += count;
                    v
                }
            }

            """ : ""

        return """
            // Generated by swift_ffi. Do not edit.
            //
            // Rust bindings *consuming* the `\(moduleName)` bridge across its C ABI.
            #![allow(non_snake_case)]
            #![allow(dead_code)]

            use std::os::raw::c_void;

            extern "C" {
            \(externs.map { "    \($0)\n" }.joined())}

            /// Drains a +1 byte box: copy the bytes out, release exactly once.
            fn take_box(b: *mut c_void) -> Vec<u8> {
                unsafe {
                    let n = swift_ffi_string_len(b);
                    let mut v = vec![0u8; n as usize];
                    if n > 0 {
                        swift_ffi_string_copy(b, v.as_mut_ptr() as *mut c_void);
                    }
                    swift_ffi_string_release(b);
                    v
                }
            }
            \(codec)\(structsOut)\(body)
            """
    }
}
