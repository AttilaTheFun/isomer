// A view type's dynamic properties (`@State`, `@Environment`, `@FocusState`,
// …), found once per type: where each lies in the view's memory and how to
// connect it. Connecting a view then connects its properties in place, in
// the view's own copy (a state's location written into it), instead of
// reflecting over it with `Mirror` on every build (a view with none, most of
// them, costs one dictionary lookup). As OpenSwiftUI's DynamicPropertyCache
// does, from the type's field records.
//
// A modifier's own properties (a `ViewModifier` stored in the view) are the
// view's, under "<label>." as with Mirror. Types whose fields this cannot
// read in place (a class, an enum) keep the Mirror path.
//
// The field records are FieldRecords.swift's.

final class _DynamicPropertyLayout {
    struct Field {
        /// The storage key's last part: the property's label, after its
        /// modifier's ("modifier._value").
        let key: String
        /// Connects the property at its offset in the view's copy (written
        /// there); true when it observes something the core cannot see
        /// change (no reuse around it).
        let connect: (UnsafeMutableRawPointer, StateStorage, String, EnvironmentValues) -> Bool
    }

    let fields: [Field]

    init(fields: [Field]) {
        self.fields = fields
    }
}

/// The layout of `type`, or nil when its properties must be found with Mirror.
func _dynamicPropertyLayout(of type: Any.Type) -> _DynamicPropertyLayout? {
    let id = ObjectIdentifier(type)
    if let known = _dynamicPropertyLayouts[id] { return known }
    var fields: [_DynamicPropertyLayout.Field] = []
    let layout = _frameLogTypeFact("properties", type) {
        _collectDynamicProperties(of: type, offset: 0, prefix: "", into: &fields) ? _DynamicPropertyLayout(fields: fields) : nil
    }
    _dynamicPropertyLayouts[id] = .some(layout)
    return layout
}

nonisolated(unsafe) private var _dynamicPropertyLayouts: [ObjectIdentifier: _DynamicPropertyLayout?] = [:]

/// The dynamic properties among `type`'s stored fields (a struct's; false
/// for anything whose fields are not inline), at `offset` in the view.
/// A `ViewModifier` in a field is a struct (a modifier is a value), or
/// Mirror connects the view.
private func _collectDynamicProperties(
    of type: Any.Type, offset: Int, prefix: String, into fields: inout [_DynamicPropertyLayout.Field]
) -> Bool {
    guard let records = _fieldRecords(of: type) else { return false }
    for record in records {
        let label = record.name, fieldType = record.type
        let fieldOffset = offset + record.offset
        if _isDynamicPropertyType(fieldType), let property = fieldType as? _DynamicProperty.Type {
            fields.append(property._layoutField(key: prefix + label, offset: fieldOffset))
        } else if _holdsDynamicProperties(fieldType), fieldType is any ViewModifier.Type {
            // (Asked only of a field that holds a property wrapper: asked of
            // every field, each one not a modifier scanned the conformances.)
            guard _collectDynamicProperties(of: fieldType, offset: fieldOffset, prefix: prefix + label + ".", into: &fields)
            else { return false }
        }
    }
    return true
}

/// Whether a struct holds a property wrapper anywhere in its fields (and so
/// might be a modifier whose properties are the view's); found by its
/// fields, once per type.
private func _holdsDynamicProperties(_ type: Any.Type, depth: Int = 0) -> Bool {
    guard _isStruct(type), depth < 8 else { return false }
    let id = ObjectIdentifier(type)
    if let known = _holdsDynamicPropertiesByType[id] { return known }
    let holds = (_fieldRecords(of: type) ?? []).contains {
        _isDynamicPropertyType($0.type) || _holdsDynamicProperties($0.type, depth: depth + 1)
    }
    _holdsDynamicPropertiesByType[id] = holds
    return holds
}

nonisolated(unsafe) private var _holdsDynamicPropertiesByType: [ObjectIdentifier: Bool] = [:]

/// The property wrappers (`_DynamicProperty`'s), known by descriptor: asked
/// as a cast of every type of field, each one not a wrapper scanned the
/// conformances. (With `_verifyViewKinds` on, checked against the cast.)
private let _dynamicPropertyDescriptors: [UnsafeRawPointer] = ([
    State<Int>.self, LazyState<Int>.self, Environment<Int>.self, FocusState<Int>.self, AppStorage<Int>.self,
    GestureState<Int>.self, Namespace.self,
] as [Any.Type] + _combineDynamicPropertyTypes).compactMap { _typeDescriptor($0) }

func _isDynamicPropertyType(_ type: Any.Type) -> Bool {
    let known = _typeDescriptor(type).map { _dynamicPropertyDescriptors.contains($0) } ?? false
    if _verifyViewKinds, _mayConformInternally(type), known != (type is _DynamicProperty.Type) {
        _viewKindMismatches.append("property wrapper \(type)")
    }
    return known
}

extension _DynamicProperty {
    static func _layoutField(key: String, offset: Int) -> _DynamicPropertyLayout.Field {
        _DynamicPropertyLayout.Field(key: key) { value, storage, prefix, env in
            let property = value.advanced(by: offset).assumingMemoryBound(to: Self.self)
            property.pointee._connect(storage: storage, key: prefix + key, env: env)
            return property.pointee._blocksSubtreeReuse
        }
    }
}

/// Connects `value`'s properties by its type's layout, writing them in
/// place; false when it has none to use (connect through Mirror instead).
func _connectByLayout<T>(of value: inout T, path: String, storage: StateStorage, env: EnvironmentValues) -> Bool {
    guard let layout = _dynamicPropertyLayout(of: T.self) else { return false }
    guard !layout.fields.isEmpty else { return true }
    let prefix = path + "#"
    withUnsafeMutablePointer(to: &value) { pointer in
        let bytes = UnsafeMutableRawPointer(pointer)
        for field in layout.fields where field.connect(bytes, storage, prefix, env) {
            Runtime.shared.markBuildVolatile()
        }
    }
    return true
}
