import Foundation
import SwiftFFIIRLibrary

// Whole-module validation: the macros can only see one file at a time, so the
// cross-file rules run here, over the merged IR, before emission.
extension Generator {
    public func validate() throws {
        // Whole-module validation: handle-typed parameters/returns must name an
        // exported interface or struct (the macros can only see one file at a
        // time).
        let known = module.interfaceNames
        let values: Set<String> = [
            "Int", "Int32", "Double", "Bool", "String", "[UInt8]", "Void", "()",
            // Arrays of scalars/strings cross as LIST blobs.
            "[Int]", "[Int32]", "[Double]", "[Bool]", "[String]",
        ]
        if let collision = known.first(where: { structIndex[$0] != nil }) {
            throw GeneratorError("'\(collision)' is exported as both an interface and a struct.")
        }
        for structure in module.structs {
            for field in structure.fields where !values.contains(field.type) || isVoid(field.type) {
                throw GeneratorError(
                    "@ExportedStruct \(structure.name).\(field.name) has type '\(field.type)'; "
                        + "struct fields must be bridgeable value types.")
            }
        }
        for function in module.functions where function.isAsync {
            for type in function.parameters.map(\.type) + [function.returnType] where structIndex[type] != nil {
                throw GeneratorError(
                    "async @ExportedFunction \(function.name) uses struct '\(type)'; "
                        + "structs are not bridged through async completions yet.")
            }
        }
        func validate(_ type: String, in context: String) throws {
            guard values.contains(type) || known.contains(type) || structIndex[type] != nil
                || module.enumNames.contains(type) else {
                throw GeneratorError(
                    "\(context) references type '\(type)', which is neither a bridgeable "
                        + "value type nor an @ExportedInterface/@ExportedStruct in this module.")
            }
        }
        for function in module.functions {
            let generics = Set(function.genericParameters)
            func validateValue(_ type: String, in context: String) throws {
                if generics.contains(type) { return }
                if type.hasPrefix("Result<") {
                    // The success type is validated via resultSuccess below.
                    return
                }
                try validate(type, in: context)
            }
            for parameter in function.parameters {
                if let closure = parameter.closure {
                    for element in closure.parameters {
                        try validateValue(element, in: "@ExportedFunction \(function.name) closure parameter")
                    }
                    if !isVoid(closure.returnType) {
                        try validateValue(closure.returnType, in: "@ExportedFunction \(function.name) closure return")
                    }
                    continue
                }
                if let success = parameter.resultSuccess {
                    try validateValue(success, in: "@ExportedFunction \(function.name) Result parameter")
                    continue
                }
                try validateValue(parameter.type, in: "@ExportedFunction \(function.name)")
            }
            try validateValue(function.returnType, in: "@ExportedFunction \(function.name)")
        }
        for interface in module.interfaces {
            for method in interface.methods {
                for parameter in method.parameters {
                    try validate(parameter.type, in: "@ExportedInterface \(interface.name).\(method.name)")
                }
                try validate(method.returnType, in: "@ExportedInterface \(interface.name).\(method.name)")
            }
        }

        // Consumer-implemented interfaces call back out over the flat C ABI.
        // Interface-typed *parameters* are fine (Swift boxes the instance +1
        // and the consumer receives a Swift<Proto> wrapper), but returning an
        // interface from consumer code back to Swift is not supported yet.
        for interface in module.interfaces where foreignInterfaces(module).contains(interface.name) {
            for method in interface.methods where known.contains(method.returnType) {
                throw GeneratorError(
                    "@ExportedInterface \(interface.name) is passed into Swift as a parameter, "
                        + "so consumers can implement it; its method '\(method.name)' may therefore "
                        + "not *return* the interface type '\(method.returnType)'.")
            }
        }
    }
}
