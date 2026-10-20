// A struct type's stored fields — name, type and offset — read from the
// runtime's field records: what the standard library's own `_forEachField`
// reads (that function is SPI, and an SPI import of Swift finds nothing
// where the module is read from its public interface). For the caches that
// handle a view type's fields in place once worked out per type
// (DynamicPropertyLayout, ReusePlan) instead of reflecting with `Mirror`
// on every build.

typealias _NameFree = @convention(c) (UnsafePointer<CChar>?) -> Void

struct _FieldMetadata {
    var name: UnsafePointer<CChar>? = nil
    var freeFunc: _NameFree? = nil
    var isStrong: Bool = true
    var isVar: Bool = false
}

@_silgen_name("swift_reflectionMirror_recursiveCount")
func _fieldCount(_ type: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
func _fieldType(_ type: Any.Type, index: Int, fieldMetadata: UnsafeMutablePointer<_FieldMetadata>) -> Any.Type

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
func _fieldOffset(_ type: Any.Type, index: Int) -> Int

/// Whether `type` is a struct (its metadata's kind word, 0x200 on every
/// platform), whose fields lie inline at their offsets.
func _isStruct(_ type: Any.Type) -> Bool {
    _metadataKind(type) == 0x200
}

struct _FieldRecord {
    let name: String
    let type: Any.Type
    let offset: Int
}

/// `type`'s stored fields, in declaration order; nil unless it is a struct.
func _fieldRecords(of type: Any.Type) -> [_FieldRecord]? {
    guard _isStruct(type) else { return nil }
    return (0..<_fieldCount(type)).map { index in
        var metadata = _FieldMetadata()
        let fieldType = _fieldType(type, index: index, fieldMetadata: &metadata)
        let name = metadata.name.map { String(cString: $0) } ?? String(index)
        metadata.freeFunc?(metadata.name)
        return _FieldRecord(name: name, type: fieldType, offset: _fieldOffset(type, index: index))
    }
}

/// `type`'s metadata kind word (0x200 a struct, 0x302 a function, …).
func _metadataKind(_ type: Any.Type) -> UInt {
    unsafeBitCast(type, to: UnsafePointer<UInt>.self).pointee
}


/// The module a struct type is declared in: its context descriptor's
/// outermost parent (a module's descriptor, compared by address). Nil for
/// a type that is not a struct (an enum, `Optional`, a class, a tuple, a
/// function).
func _structModule(_ type: Any.Type) -> UnsafeRawPointer? {
    guard _isStruct(type) else { return nil }
    // A struct's metadata: its kind word, then its descriptor's address.
    var context = unsafeBitCast(type, to: UnsafeRawPointer.self)
        .load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
    for _ in 0..<32 {
        // A context descriptor: flags (the low five bits its kind, 0 a
        // module), then its parent as a relative pointer (the low bit set:
        // to a slot holding the address).
        if context.load(as: UInt32.self) & 0x1F == 0 { return context }
        let field = context + 4
        let offset = Int(field.load(as: Int32.self))
        guard offset != 0 else { return nil }
        let target = field + (offset & ~1)
        context = offset & 1 == 0 ? target : target.load(as: UnsafeRawPointer.self)
    }
    return nil
}

/// Whether `type` could conform to one of this module's internal protocols
/// (`_PrimitiveView`, `_DynamicProperty`, …): only a type declared here can,
/// or one that is not a struct (`Optional` is a `_MultiView`). Asked before
/// a dynamic check against one, since for a type not seen before the
/// runtime answers no by scanning every conformance the app has; interpreted,
/// those scans were the larger part of building a screen the first time.
/// Modules compare by name: a module's descriptor is not one per module
/// everywhere (on Android each object file has its own copy).
func _mayConformInternally(_ type: Any.Type) -> Bool {
    guard let module = _structModule(type) else { return true }
    guard let own = _ownModuleName else { return true }
    return _moduleNameEquals(module, own)
}

/// A module descriptor's name: flags, parent, then the name as a relative
/// pointer to a C string.
private func _moduleName(_ module: UnsafeRawPointer) -> UnsafePointer<UInt8>? {
    let field = module + 8
    let offset = Int(field.load(as: Int32.self))
    guard offset != 0 else { return nil }
    return (field + offset).assumingMemoryBound(to: UInt8.self)
}

/// Whether the module descriptor is the module named `name` (UTF-8).
func _moduleNameIs(_ module: UnsafeRawPointer, _ name: [UInt8]) -> Bool {
    _moduleNameEquals(module, name)
}

private func _moduleNameEquals(_ module: UnsafeRawPointer, _ name: [UInt8]) -> Bool {
    guard let theirs = _moduleName(module) else { return false }
    for (i, byte) in name.enumerated() where theirs[i] != byte { return false }
    return theirs[name.count] == 0
}

nonisolated(unsafe) private let _ownModuleName: [UInt8]? = _structModule(Text.self).flatMap { module in
    _moduleName(module).map { name in
        var bytes: [UInt8] = []
        var i = 0
        while name[i] != 0 { bytes.append(name[i]); i += 1 }
        return bytes
    }
}

/// A struct's or enum's name as declared (no module, no generic arguments)
/// and whether it is generic, from its type descriptor; nil for any other
/// kind of type.
func _nominalName(_ type: Any.Type) -> (name: String, generic: Bool)? {
    // Struct, enum and Optional metadata: the kind word, then the descriptor.
    let kind = _metadataKind(type)
    guard kind == 0x200 || kind == 0x201 || kind == 0x202 else { return nil }
    let descriptor = unsafeBitCast(type, to: UnsafeRawPointer.self)
        .load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
    // A type descriptor: flags (0x80 generic), its parent, then its name as
    // a relative pointer to a C string.
    let flags = descriptor.load(as: UInt32.self)
    let field = descriptor + 8
    let offset = Int(field.load(as: Int32.self))
    guard offset != 0 else { return nil }
    return (String(cString: (field + offset).assumingMemoryBound(to: CChar.self)), flags & 0x80 != 0)
}
