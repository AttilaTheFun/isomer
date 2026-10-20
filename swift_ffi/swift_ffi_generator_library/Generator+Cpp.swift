import Foundation
import SwiftFFIIRLibrary

// The C++ backend: an idiomatic header-only binding over the shared C ABI
// (docs/bridge_v2.md). Swift Int → int64_t, String → std::string, [UInt8] →
// std::vector<uint8_t>, @ExportedStruct → a plain C++ struct with a
// swiftffi::traits specialization, Result<T, Error> → swiftffi::Result<T>,
// Lazy<T> → swiftffi::Lazy<T>, closures → std::function, interfaces → an
// abstract class (Swift-owned instances as RAII wrappers, consumer
// implementations passed as std::shared_ptr), generics → real templates.
extension Generator {
    /// The C++ spelling of a bridged type (with `generics` naming template
    /// parameters).
    func cppType(_ swift: String, generics: Set<String> = []) -> String {
        switch swift {
        case "Int": return "int64_t"
        case "Int32": return "int32_t"
        case "Double": return "double"
        case "Bool": return "bool"
        case "String": return "std::string"
        case "[UInt8]": return "std::vector<uint8_t>"
        case "Void", "()": return "void"
        default:
            if generics.contains(swift) { return swift }
            if isStruct(swift) || isEnum(swift) { return swift }
            if let success = resultSuccess(swift) {
                return "swiftffi::Result<\(cppType(success, generics: generics))>"
            }
            if module.interfaceNames.contains(swift) { return "std::shared_ptr<\(swift)>" }
            return swift
        }
    }

    /// The `T` of a `Result<T, ...>` spelling.
    func resultSuccess(_ type: String) -> String? {
        guard type.hasPrefix("Result<") else { return nil }
        // The success type is the first top-level generic argument.
        let inner = String(type.dropFirst("Result<".count).dropLast())
        var depth = 0
        for (offset, character) in inner.enumerated() {
            if character == "<" { depth += 1 }
            if character == ">" { depth -= 1 }
            if character == "," && depth == 0 {
                return String(inner.prefix(offset)).trimmingCharacters(in: .whitespaces)
            }
        }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    /// The C++ parameter declaration for a bridged parameter.
    func cppParamDecl(_ parameter: FFIParameter, index: Int, generics: Set<String>) -> String {
        let name = cppParamName(parameter, index)
        if let closure = parameter.closure {
            let elements = closure.parameters.map { cppType($0, generics: generics) }
            let ret = cppType(closure.returnType, generics: generics)
            return "std::function<\(ret)(\(elements.joined(separator: ", ")))> \(name)"
        }
        switch parameter.type {
        case "Int", "Int32", "Double", "Bool":
            return "\(cppType(parameter.type)) \(name)"
        default:
            if generics.contains(parameter.type) {
                return "const \(parameter.type) &\(name)"
            }
            return "const \(cppType(parameter.type, generics: generics)) &\(name)"
        }
    }

    /// C++ keywords and alternative tokens that cannot name a parameter.
    static let cppKeywords: Set<String> = [
        "alignas", "alignof", "and", "asm", "auto", "bitand", "bitor", "bool",
        "break", "case", "catch", "char", "class", "compl", "concept", "const",
        "continue", "decltype", "default", "delete", "do", "double", "else",
        "enum", "explicit", "export", "extern", "false", "float", "for",
        "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace",
        "new", "noexcept", "not", "nullptr", "operator", "or", "private",
        "protected", "public", "register", "requires", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "template", "this",
        "throw", "true", "try", "typedef", "typeid", "typename", "union",
        "unsigned", "using", "virtual", "void", "volatile", "while", "xor",
    ]

    func cppParamName(_ parameter: FFIParameter, _ index: Int) -> String {
        if parameter.label == "_" { return "arg\(index)" }
        return Self.cppKeywords.contains(parameter.label) ? parameter.label + "_" : parameter.label
    }

    /// The expression(s) + prelude marshaling one C++ argument to the C ABI.
    func cppMarshal(
        _ parameter: FFIParameter, index: Int, generics: Set<String>
    ) -> (prelude: [String], args: [String]) {
        let name = cppParamName(parameter, index)
        if parameter.closure != nil {
            let closure = parameter.closure!
            var lines: [String] = []
            var body: [String] = []
            body.append("swiftffi::blob::Reader reader(args);")
            var callArgs: [String] = []
            for (ei, element) in closure.parameters.enumerated() {
                body.append(
                    "auto a\(ei) = swiftffi::traits<\(cppType(element, generics: generics))>::decode(reader);")
                callArgs.append("a\(ei)")
            }
            if isVoid(closure.returnType) {
                body.append("\(name)(\(callArgs.joined(separator: ", ")));")
                body.append("return std::vector<uint8_t>{};")
            } else {
                body.append(
                    "return swiftffi::encode<\(cppType(closure.returnType, generics: generics))>(\(name)(\(callArgs.joined(separator: ", "))));")
            }
            lines.append(
                "swiftffi::Closure closure\(index)([\(name)](const std::vector<uint8_t> &args) -> std::vector<uint8_t> {")
            lines.append(contentsOf: body.map { "    \($0)" })
            lines.append("});")
            return (lines, ["closure\(index).get()"])
        }
        switch parameter.type {
        case "Int": return ([], ["(intptr_t)\(name)"])
        case "Int32", "Double": return ([], [name])
        case "Bool": return ([], [name])
        case "String":
            return ([], ["\(name).data()", "(int32_t)\(name).size()"])
        case "[UInt8]":
            return ([], ["\(name).data()", "(int32_t)\(name).size()"])
        default:
            if isBlob(parameter.type, generics: generics) {
                let type = generics.contains(parameter.type)
                    ? parameter.type : cppType(parameter.type, generics: generics)
                return (
                    ["auto blob\(index) = swiftffi::encode<\(type)>(\(name));"],
                    ["blob\(index).data()", "(int32_t)blob\(index).size()"]
                )
            }
            if module.interfaceNames.contains(parameter.type) {
                let proto = parameter.type
                return (
                    [
                        "void *handle\(index) = nullptr;",
                        "const bridge_closure *foreign\(index) = nullptr;",
                        "std::optional<swiftffi::Closure> fc\(index);",
                        "if (auto *swiftOwned = dynamic_cast<Swift\(proto) *>(\(name).get())) {",
                        "    handle\(index) = swiftOwned->borrow_handle();",
                        "} else {",
                        "    fc\(index).emplace(detail::foreign_\(proto)(\(name)));",
                        "    foreign\(index) = fc\(index)->get();",
                        "}",
                    ],
                    ["handle\(index)", "foreign\(index)"]
                )
            }
            return ([], [name])
        }
    }

    /// The C++ expression converting a raw C return into the idiomatic value.
    func cppUnmarshalReturn(
        _ type: String, _ raw: String, generics: Set<String>
    ) -> String {
        switch type {
        case "Int": return "(int64_t)\(raw)"
        case "Int32", "Double", "Bool": return raw
        case "String": return "detail::take_string(\(raw))"
        case "[UInt8]": return "detail::take(\(raw))"
        default:
            if isBlob(type, generics: generics) {
                let cpp = generics.contains(type) ? type : cppType(type, generics: generics)
                return "swiftffi::decode<\(cpp)>(detail::take(\(raw)))"
            }
            if module.interfaceNames.contains(type) {
                return "std::shared_ptr<Swift\(type)>(new Swift\(type)(\(raw)))"
            }
            return raw
        }
    }

    /// One Swift-owned wrapper method: an ordinal-led blob dispatch through
    /// the interface's `_invoke` entry.
    func cppInvokeMethod(
        _ interface: FFIInterface, _ method: FFIMethod, ordinal: Int, params: String, ret: String
    ) -> String {
        var body: [String] = []
        body.append("swiftffi::blob::Writer w;")
        for (index, parameter) in method.parameters.enumerated() {
            let name = cppParamName(parameter, index)
            if module.interfaceNames.contains(parameter.type) {
                // Borrowed for the call: a Swift wrapper crosses by handle, any
                // other implementation as a bridge_closure kept alive below.
                body.append("std::optional<swiftffi::Closure> fc\(index);")
                body.append("if (auto *swiftOwned\(index) = dynamic_cast<Swift\(parameter.type) *>(\(name).get())) {")
                body.append("    w.type_header(swiftffi::blob::kHandle, \"\(parameter.type)\");")
                body.append("    w.i64((int64_t)(intptr_t)swiftOwned\(index)->borrow_handle());")
                body.append("} else {")
                body.append("    fc\(index).emplace(detail::foreign_\(parameter.type)(\(name)));")
                body.append("    w.type_header(swiftffi::blob::kForeign, \"\(parameter.type)\");")
                body.append("    w.i64((int64_t)(intptr_t)fc\(index)->get());")
                body.append("}")
            } else {
                body.append("swiftffi::traits<\(cppType(parameter.type))>::encode(w, \(name));")
            }
        }
        body.append("auto staged = w.take();")
        body.append(
            "void *box = \(invokeSymbol(interface))(handle_, \(ordinal), staged.data(), (int32_t)staged.size());")
        body.append("auto result = detail::take(box);")
        body.append("std::string failure;")
        body.append("if (swiftffi::error_message(result, failure)) throw swiftffi::SwiftError(failure);")
        if isVoid(method.returnType) {
            body.append("(void)result;")
        } else if module.interfaceNames.contains(method.returnType) {
            body.append("swiftffi::blob::Reader r(result);")
            body.append("(void)swiftffi::blob::skip_header(r);")
            body.append("return std::shared_ptr<Swift\(method.returnType)>(new Swift\(method.returnType)((void *)(intptr_t)r.i64()));")
        } else {
            body.append("return swiftffi::decode<\(cppType(method.returnType))>(result);")
        }
        return "    \(ret) \(method.name)(\(params)) override {\n"
            + body.map { "        \($0)\n" }.joined() + "    }"
    }

    func emitCpp(_ module: FFIModule, moduleName: String, headerName: String) -> String {
        let ns = moduleName.lowercased()
        let interfaces = module.interfaceNames
        let foreign = foreignInterfaces(module)

        var out = """
            // Generated by swift_ffi. Do not edit.
            //
            // C++ bindings for the `\(moduleName)` Swift module, over its shared C ABI.
            #pragma once

            #include <cstdint>
            #include <functional>
            #include <memory>
            #include <optional>
            #include <string>
            #include <utility>
            #include <vector>

            #include "swiftffi.hpp"
            #include "\(headerName)"

            namespace \(ns) {

            namespace detail {

            inline const swiftffi::BoxOps &box_ops() {
                static const swiftffi::BoxOps ops{swift_ffi_string_len, swift_ffi_string_copy, swift_ffi_string_release};
                return ops;
            }

            inline std::vector<uint8_t> take(void *box) { return swiftffi::take_box(box, box_ops()); }
            inline std::string take_string(void *box) { return swiftffi::take_string_box(box, box_ops()); }

            }  // namespace detail

            """

        // Structs (plain values) …
        for structure in module.structs {
            let fields = structure.fields
                .map { "    \(cppType($0.type)) \($0.name);" }
                .joined(separator: "\n")
            out += """

                /// A field-wise copy of the Swift `\(structure.name)` value.
                struct \(structure.name) {
                \(fields)
                };

                """
        }
        // Exported enums: raw-value copies.
        for enumeration in module.enums {
            if enumeration.rawType == "String" {
                out += "\n/// A raw-value copy of the Swift `\(enumeration.name)` enum (string raw values).\nusing \(enumeration.name) = std::string;\n"
            } else {
                let cases = enumeration.cases.enumerated().map { index, c -> String in
                    let raw = c.rawValue.isEmpty ? "\(index)" : c.rawValue
                    return "    \(c.name) = \(raw),"
                }.joined(separator: "\n")
                out += """

                    /// A raw-value copy of the Swift `\(enumeration.name)` enum.
                    enum class \(enumeration.name) : int64_t {
                    \(cases)
                    };

                    """
            }
        }
        out += "\n}  // namespace \(ns)\n"

        // … with their traits specializations (in the swiftffi namespace).
        if !module.structs.isEmpty || module.enums.contains(where: { $0.rawType != "String" }) {
            out += "\nnamespace swiftffi {\n"
            for structure in module.structs {
                let qualified = "\(ns)::\(structure.name)"
                let encodes = structure.fields
                    .map {
                        "        traits<\(cppType($0.type))>::encode(w, v.\($0.name));"
                    }
                    .joined(separator: "\n")
                let decodes = structure.fields
                    .map {
                        "        v.\($0.name) = traits<\(cppType($0.type))>::decode(r);"
                    }
                    .joined(separator: "\n")
                out += """

                    template <>
                    struct traits<\(qualified)> {
                        static void encode(blob::Writer &w, const \(qualified) &v) {
                            w.type_header(blob::kStruct, "\(structure.name)");
                            w.i64(\(structure.fields.count));
                    \(encodes)
                        }
                        static \(qualified) decode(blob::Reader &r) {
                            auto header = blob::skip_header(r);
                            if (header.first != blob::kStruct) throw SwiftError("expected \(structure.name)");
                            (void)r.i64();
                            \(qualified) v{};
                    \(decodes)
                            return v;
                        }
                    };

                    """
            }
            for enumeration in module.enums where enumeration.rawType != "String" {
                let qualified = "\(ns)::\(enumeration.name)"
                out += """

                    template <>
                    struct traits<\(qualified)> {
                        static void encode(blob::Writer &w, const \(qualified) &v) {
                            traits<int64_t>::encode(w, (int64_t)v);
                        }
                        static \(qualified) decode(blob::Reader &r) {
                            return (\(qualified))traits<int64_t>::decode(r);
                        }
                    };

                    """
            }
            out += "}  // namespace swiftffi\n"
        }

        out += "\nnamespace \(ns) {\n"

        // Interfaces: contract + Swift-owned RAII wrapper (+ foreign dispatcher).
        for interface in module.interfaces {
            var contractMethods: [String] = []
            var wrapperMethods: [String] = []
            for (ordinal, method) in interface.methods.enumerated() {
                // Async interface methods are not bridged to C++ yet.
                if method.isAsync { continue }
                let params = method.parameters.enumerated()
                    .map { cppParamDecl($0.element, index: $0.offset, generics: []) }
                    .joined(separator: ", ")
                let ret = cppType(method.returnType)
                contractMethods.append("    virtual \(ret) \(method.name)(\(params)) = 0;")
                wrapperMethods.append(
                    cppInvokeMethod(interface, method, ordinal: ordinal, params: params, ret: ret))
            }

            out += """

                /// The `\(interface.name)` contract. Implement it and pass a
                /// std::shared_ptr into Swift, or receive Swift-owned instances as
                /// `Swift\(interface.name)` wrappers.
                class \(interface.name) {
                public:
                    virtual ~\(interface.name)() = default;
                \(contractMethods.joined(separator: "\n"))
                };

                /// Wraps a Swift-owned `\(interface.name)` (+1 handle, released once).
                class Swift\(interface.name) final : public \(interface.name) {
                public:
                    explicit Swift\(interface.name)(void *handle) : handle_(handle) {}
                    ~Swift\(interface.name)() override { close(); }
                    Swift\(interface.name)(const Swift\(interface.name) &) = delete;
                    Swift\(interface.name) &operator=(const Swift\(interface.name) &) = delete;

                    /// Releases the underlying Swift instance. Idempotent.
                    void close() {
                        if (handle_) {
                            \(releaseSymbol(interface))(handle_);
                            handle_ = nullptr;
                        }
                    }

                    void *borrow_handle() const { return handle_; }

                \(wrapperMethods.joined(separator: "\n\n"))

                private:
                    void *handle_;
                };

                """

            if foreign.contains(interface.name) {
                var cases: [String] = []
                for (ordinal, method) in interface.methods.enumerated() {
                    if method.isAsync { continue }
                    var caseBody: [String] = []
                    var callArgs: [String] = []
                    for (index, parameter) in method.parameters.enumerated() {
                        if interfaces.contains(parameter.type) {
                            caseBody.append("auto header\(index) = swiftffi::blob::skip_header(reader);")
                            caseBody.append("(void)header\(index);")
                            caseBody.append(
                                "auto a\(index) = std::shared_ptr<Swift\(parameter.type)>(new Swift\(parameter.type)((void *)(intptr_t)reader.i64()));")
                        } else {
                            caseBody.append(
                                "auto a\(index) = swiftffi::traits<\(cppType(parameter.type))>::decode(reader);")
                        }
                        callArgs.append("a\(index)")
                    }
                    let call = "impl->\(method.name)(\(callArgs.joined(separator: ", ")))"
                    if isVoid(method.returnType) {
                        caseBody.append("\(call);")
                        caseBody.append("return std::vector<uint8_t>{};")
                    } else {
                        caseBody.append(
                            "return swiftffi::encode<\(cppType(method.returnType))>(\(call));")
                    }
                    cases.append(
                        "        case \(ordinal): {\n"
                            + caseBody.map { "            \($0)\n" }.joined()
                            + "        }")
                }
                out += """

                    namespace detail {

                    /// Dispatches Swift's calls into a consumer-implemented
                    /// `\(interface.name)` (method ordinal leads the arguments).
                    inline swiftffi::Dispatcher foreign_\(interface.name)(std::shared_ptr<\(interface.name)> impl) {
                        return [impl](const std::vector<uint8_t> &args) -> std::vector<uint8_t> {
                            swiftffi::blob::Reader reader(args);
                            int32_t ordinal = swiftffi::traits<int32_t>::decode(reader);
                            switch (ordinal) {
                    \(cases.joined(separator: "\n"))
                            }
                            throw swiftffi::SwiftError("unknown method ordinal");
                        };
                    }

                    }  // namespace detail

                    """
            }
        }

        // Free functions.
        for function in module.functions {
            let generics = Set(function.genericParameters)
            let template = function.genericParameters.isEmpty
                ? "" : "template <\(function.genericParameters.map { "typename \($0)" }.joined(separator: ", "))>\n"

            var prelude: [String] = []
            var args: [String] = []
            for (index, parameter) in function.parameters.enumerated() {
                let m = cppMarshal(parameter, index: index, generics: generics)
                prelude.append(contentsOf: m.prelude)
                args.append(contentsOf: m.args)
            }

            var params = function.parameters.enumerated()
                .map { cppParamDecl($0.element, index: $0.offset, generics: generics) }

            if function.isAsync {
                // Completion receives swiftffi::Result<T> (async may fail in flight).
                let valueType = isVoid(function.returnType) ? "void" : cppType(function.returnType, generics: generics)
                params.append("std::function<void(swiftffi::Result<\(valueType)>)> completion")
                var dispatcher: [String] = []
                dispatcher.append("std::string message;")
                dispatcher.append("if (swiftffi::error_message(args, message)) {")
                dispatcher.append("    completion(swiftffi::Result<\(valueType)>::failure(message));")
                if isVoid(function.returnType) {
                    dispatcher.append("} else {")
                    dispatcher.append("    completion(swiftffi::Result<void>::success());")
                    dispatcher.append("}")
                } else {
                    dispatcher.append("} else {")
                    dispatcher.append(
                        "    completion(swiftffi::Result<\(valueType)>::success(swiftffi::decode<\(valueType)>(args)));")
                    dispatcher.append("}")
                }
                dispatcher.append("return std::vector<uint8_t>{};")
                prelude.append(
                    "swiftffi::Closure completion_closure([completion](const std::vector<uint8_t> &args) -> std::vector<uint8_t> {")
                prelude.append(contentsOf: dispatcher.map { "    \($0)" })
                prelude.append("});")
                args.append("completion_closure.get()")
                let body = prelude + ["\(symbol(function))(\(args.joined(separator: ", ")));"]
                out += """

                    \(template)inline void \(function.name)(\(params.joined(separator: ", "))) {
                    \(body.map { "    \($0)\n" }.joined())}

                    """
                continue
            }

            // Return type.
            let returnCpp: String
            if function.returnsLazy {
                returnCpp = "swiftffi::Lazy<\(cppType(function.returnType, generics: generics))>"
            } else if function.isThrowing {
                returnCpp = isVoid(function.returnType)
                    ? "swiftffi::Result<void>"
                    : "swiftffi::Result<\(cppType(function.returnType, generics: generics))>"
            } else {
                returnCpp = cppType(function.returnType, generics: generics)
            }

            var body = prelude
            if function.isThrowing {
                body.append("void *error_box = nullptr;")
                args.append("&error_box")
            }
            let call = "\(symbol(function))(\(args.joined(separator: ", ")))"
            let valueType = cppType(function.returnType, generics: generics)
            if function.returnsLazy {
                body.append("void *lazy_handle = \(call);")
                body.append(
                    "return swiftffi::Lazy<\(valueType)>(lazy_handle, [](void *h) { return detail::take(swift_ffi_lazy_get(h)); }, swift_ffi_lazy_release);")
            } else if function.isThrowing {
                if isVoid(function.returnType) {
                    body.append("\(call);")
                    body.append("if (error_box) return swiftffi::Result<void>::failure(detail::take_string(error_box));")
                    body.append("return swiftffi::Result<void>::success();")
                } else {
                    body.append("auto raw = \(call);")
                    body.append("if (error_box) return swiftffi::Result<\(valueType)>::failure(detail::take_string(error_box));")
                    body.append(
                        "return swiftffi::Result<\(valueType)>::success(\(cppUnmarshalReturn(function.returnType, "raw", generics: generics)));")
                }
            } else if isVoid(function.returnType) {
                body.append("\(call);")
            } else {
                body.append("auto raw = \(call);")
                body.append("return \(cppUnmarshalReturn(function.returnType, "raw", generics: generics));")
            }

            let inlinePrefix = function.genericParameters.isEmpty ? "inline " : ""
            out += """

                \(template)\(inlinePrefix)\(returnCpp) \(function.name)(\(params.joined(separator: ", "))) {
                \(body.map { "    \($0)\n" }.joined())}

                """
        }

        out += "\n}  // namespace \(ns)\n"
        return out
    }
}
