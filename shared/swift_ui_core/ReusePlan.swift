// How two values of a view's type compare for reuse, worked out once per
// type from its field records (FieldRecords.swift) and then run on the two
// values in place: `==` for a field whose type is Equatable, identity for an
// `@Observable` model, nothing for `@State` / `@Environment` (their changes
// reach the reuse check another way), a nested struct's own fields, and the
// general comparison (`reuseEqual`) for a field of any other kind. It does
// what `reuseEqual` did through `Mirror` on every view of every frame — the
// largest single part of a frame's build once the casts and the state
// connection had gone — as OpenSwiftUI compares values by a layout made
// per type.

#if canImport(Observation)
import Observation
#endif

final class _ReusePlan {
    enum Step {
        /// The field's `==`.
        case equatable((UnsafeRawPointer, UnsafeRawPointer) -> Bool)
        /// The same instance (a model, compared by identity).
        case identity(offset: Int)
        /// The field's values, compared as `reuseEqual` compares any value.
        case general((UnsafeRawPointer) -> Any)
        /// Never the same (a closure): such a view is rebuilt.
        case never
    }

    let steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    /// Whether every value of the type can be compared, whatever it holds:
    /// true when no step needs the values to say (nil: ask of the value).
    var comparableByType: Bool? {
        var general = false
        for step in steps {
            switch step {
            case .never: return false
            case .general: general = true
            case .equatable, .identity: break
            }
        }
        return general ? nil : true
    }

    func equal(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, depth: Int) -> Bool {
        for step in steps {
            switch step {
            case .equatable(let same):
                if !same(a, b) { return false }
            case .identity(let offset):
                if a.load(fromByteOffset: offset, as: UInt.self) != b.load(fromByteOffset: offset, as: UInt.self) {
                    return false
                }
            case .general(let load):
                if !reuseEqual(load(a), load(b), depth: depth + 1) { return false }
            case .never:
                return false
            }
        }
        return true
    }
}

/// `type`'s plan, or nil when it is not a struct (compared as before).
func _reusePlan(of type: Any.Type) -> _ReusePlan? {
    let id = ObjectIdentifier(type)
    if let known = _reusePlans[id] { return known }
    return _frameLogTypeFact("plan", type) { _makeReusePlan(of: type, id: id) }
}

private func _makeReusePlan(of type: Any.Type, id: ObjectIdentifier) -> _ReusePlan? {
    let plan: _ReusePlan?
    if _isBindingType(type) {
        // A binding compares by the state it projects (reuseEqual), not by
        // its closures.
        plan = nil
    } else if let steps = _reuseSteps(for: type, offset: 0, depth: 0) {
        plan = _ReusePlan(steps: steps)
    } else {
        plan = nil
    }
    _reusePlans[id] = .some(plan)
    return plan
}

/// How a value of `type` at `offset` compares: `==` when it is Equatable,
/// else its fields' steps (a struct); nil when neither. For a type of the
/// app's own (or of a module other than the standard ones), its fields are
/// tried first and `==` is asked for only when they cannot all be compared
/// cheaply (a closure, a value of unknown type): each type the runtime is
/// asked about that is not Equatable costs a scan of every conformance in
/// the program, and most views, and the values they hold, compare field by
/// field anyway. A standard type (a string, an array) is compared by `==`:
/// its fields are its storage.
private func _reuseSteps(for type: Any.Type, offset: Int, depth: Int) -> [_ReusePlan.Step]? {
    if _isStruct(type), !_isSystemType(type) {
        var steps: [_ReusePlan.Step] = []
        guard _appendReuseSteps(for: type, offset: offset, depth: depth, into: &steps) else { return nil }
        if steps.allSatisfy(\.isCheap) { return steps }
        if _mayConform(type, .equatable), let equatable = type as? any Equatable.Type {
            return [.equatable(_equatableStep(equatable, offset: offset))]
        }
        return steps
    }
    if _mayConform(type, .equatable), let equatable = type as? any Equatable.Type {
        return [.equatable(_equatableStep(equatable, offset: offset))]
    }
    var steps: [_ReusePlan.Step] = []
    return _appendReuseSteps(for: type, offset: offset, depth: depth, into: &steps) ? steps : nil
}

extension _ReusePlan.Step {
    /// Compared without asking anything of the values at run time.
    var isCheap: Bool {
        switch self {
        case .equatable, .identity: return true
        case .general, .never: return false
        }
    }
}

/// A struct declared in the standard library or Foundation (its fields are
/// its storage: compared by `==`).
private func _isSystemType(_ type: Any.Type) -> Bool {
    guard let module = _structModule(type) else { return false }
    return _systemModuleNames.contains { _moduleNameIs(module, $0) }
}

private let _systemModuleNames: [[UInt8]] = ["Swift", "Foundation", "FoundationEssentials", "_Concurrency", "CoreFoundation", "CoreGraphics"]
    .map { Array($0.utf8) }

nonisolated(unsafe) private var _reusePlans: [ObjectIdentifier: _ReusePlan?] = [:]

/// The steps comparing a struct's fields at `offset`; false (and nothing
/// added) unless `type` is a struct whose fields can all be planned.
private func _appendReuseSteps(for type: Any.Type, offset: Int, depth: Int, into steps: inout [_ReusePlan.Step]) -> Bool {
    guard depth < 8, let records = _fieldRecords(of: type) else { return false }
    var own: [_ReusePlan.Step] = []
    for record in records {
        let at = offset + record.offset
        let fieldType = record.type
        let kind = _metadataKind(fieldType)
        // A closure: never the same.
        if kind == 0x302 {
            own.append(.never)
            continue
        }
        if _isReuseTransparentType(fieldType) { continue }
        // A view of any type (`AnyView`'s, a modifier's content): its value,
        // opened, compared as any value is. (Loaded as a generic `T`, the
        // value went into `Any` still in its existential box, which the
        // plan of the type inside was then run on.)
        if fieldType == (any View).self {
            own.append(.general({ $0.advanced(by: at).assumingMemoryBound(to: (any View).self).pointee as Any }))
            continue
        }
        // A tuple, another existential or a metatype conforms to nothing (an
        // existential's value may): compared as any value is, unasked.
        if kind == 0x301 || kind == 0x303 || kind == 0x304 || kind == 0x306 || kind == 0x307 {
            let load: (UnsafeRawPointer) -> Any = _openExistential(fieldType, do: _loadStep)
            own.append(.general({ load($0.advanced(by: at)) }))
            continue
        }
        if fieldType is AnyClass {
            if _isObservableClass(fieldType) {
                own.append(.identity(offset: at))
                continue
            }
        } else if !_isBindingType(fieldType), let nested = _reuseSteps(for: fieldType, offset: at, depth: depth + 1) {
            own += nested
            continue
        }
        if fieldType is AnyClass, let equatable = fieldType as? any Equatable.Type {
            own.append(.equatable(_equatableStep(equatable, offset: at)))
            continue
        }
        // (A metatype of `Any` cannot be opened implicitly.)
        let load: (UnsafeRawPointer) -> Any = _openExistential(fieldType, do: _loadStep)
        own.append(.general({ load($0.advanced(by: at)) }))
    }
    steps += own
    return true
}

private func _isObservableClass(_ type: Any.Type) -> Bool {
    #if ISOMER_COMPILED_FEATURE
    return type is AnyClass && type is any Observable.Type
    #else
    #if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
        return type is AnyClass && type is any Observable.Type
    }
    #endif
    return false
    #endif
}

private func _equatableStep<T: Equatable>(_: T.Type, offset: Int) -> (UnsafeRawPointer, UnsafeRawPointer) -> Bool {
    { a, b in
        a.advanced(by: offset).assumingMemoryBound(to: T.self).pointee
            == b.advanced(by: offset).assumingMemoryBound(to: T.self).pointee
    }
}

private func _loadStep<T>(_: T.Type) -> (UnsafeRawPointer) -> Any {
    { field in field.assumingMemoryBound(to: T.self).pointee }
}

/// `a` and `b` compared by their type's plan; nil when the type has none.
func _plannedReuseEqual(_ a: Any, _ b: Any, depth: Int) -> Bool? {
    let valueType = type(of: a)
    guard valueType == type(of: b), let plan = _reusePlan(of: valueType) else { return nil }
    // Opened explicitly: an `Any` given to an unconstrained generic is not
    // opened (it is a T of its own), and its bytes would be the container's.
    // (A generic function, not a method: the compiler rejects a method
    // reference here. Its other inputs ride a variable it reads first, the
    // comparison nesting through general steps.)
    _plannedCompareInputs = (b, plan, depth, valueType)
    return _openExistential(a, do: _runPlannedCompare)
}

nonisolated(unsafe) private var _plannedCompareInputs: (other: Any, plan: _ReusePlan, depth: Int, type: Any.Type)?

private func _runPlannedCompare<T>(_ value: T) -> Bool {
    guard let (other, plan, depth, planned) = _plannedCompareInputs, let other = other as? T else { return false }
    _plannedCompareInputs = nil
    // The value opened is not the type planned (an existential inside the
    // `Any`): its bytes are the box's, not the value's. Not the same.
    guard T.self == planned else { return false }
    return withUnsafePointer(to: value) { a in
        withUnsafePointer(to: other) { b in
            plan.equal(UnsafeRawPointer(a), UnsafeRawPointer(b), depth: depth)
        }
    }
}

/// Whether `value` can be compared, by its type's plan (its fields of no
/// fixed type asked of their values); nil when its type has none.
func _plannedReuseComparable(_ value: Any, depth: Int) -> Bool? {
    guard let plan = _reusePlan(of: type(of: value)) else { return nil }
    if let byType = plan.comparableByType { return byType }
    _plannedComparableInputs = (plan, depth, type(of: value))
    return _openExistential(value, do: _runPlannedComparable)
}

nonisolated(unsafe) private var _plannedComparableInputs: (plan: _ReusePlan, depth: Int, type: Any.Type)?

private func _runPlannedComparable<T>(_ value: T) -> Bool {
    guard let (plan, depth, planned) = _plannedComparableInputs else { return false }
    _plannedComparableInputs = nil
    guard T.self == planned else { return false }
    return withUnsafePointer(to: value) { pointer in
        let bytes = UnsafeRawPointer(pointer)
        for step in plan.steps {
            switch step {
            case .never: return false
            case .general(let load): if !reuseComparable(load(bytes), depth: depth + 1) { return false }
            case .equatable, .identity: break
            }
        }
        return true
    }
}

// MARK: - Our own types, by descriptor

/// A struct's, enum's or Optional's type descriptor (shared by every
/// instantiation of a generic type); nil for other kinds.
func _typeDescriptor(_ type: Any.Type) -> UnsafeRawPointer? {
    let kind = _metadataKind(type)
    guard kind == 0x200 || kind == 0x201 || kind == 0x202 else { return nil }
    return unsafeBitCast(type, to: UnsafeRawPointer.self)
        .load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
}

/// The property wrappers whose changes reach reuse another way
/// (`_ReuseTransparentProperty`'s), known by descriptor: asking the cast of
/// every type of field (most of them not one) scanned the conformances.
private let _transparentDescriptors: [UnsafeRawPointer] = ([
    State<Int>.self, Environment<Int>.self,
] as [Any.Type]).compactMap { _typeDescriptor($0) }

private let _bindingDescriptor = _typeDescriptor(Binding<Int>.self)

func _isReuseTransparentType(_ type: Any.Type) -> Bool {
    guard let descriptor = _typeDescriptor(type) else { return false }
    return _transparentDescriptors.contains(descriptor)
}

func _isBindingType(_ type: Any.Type) -> Bool {
    guard let descriptor = _typeDescriptor(type) else { return false }
    return descriptor == _bindingDescriptor
}
