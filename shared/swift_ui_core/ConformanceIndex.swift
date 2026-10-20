// Which types have a conformance to a protocol at all, read once from the
// program's conformance records. Asked whether a type conforms to a
// protocol, the runtime answers only after scanning every conformance record
// in the program, the first time each type is asked about (each
// instantiation of a generic type its own question), yes or no: Visor's
// reactor has 6,274 records, about 1 ms a scan interpreted, and entering a
// chat the first time spent 0.3 s of its 1.3 s in such questions, most of
// them Isomer's. Read once (8 ms), the records answer no at once: a struct
// or an enum with no record for the protocol cannot conform. A type that has
// one, conditionally or not, is asked of the runtime as before, and so is
// any other type (a class, whose superclasses' records count too; an
// Optional, which a cast looks through; a tuple, a function, an
// existential).
//
// The records are reached through `swift_enumerateAllMetadataSections`,
// which the runtime exports where it finds metadata by section (swift-testing
// reads its tests the same way), called as a C function (`@_extern(c)`, the
// module built with the `Extern` feature; declared `@_silgen_name`, wasm's
// linker made the mismatched call a trap). On wasm only, where the questions
// are interpreted: compiled, a scan costs little, and elsewhere every
// question goes to the runtime as before. With `ISO_VERIFY_CONFORMANCES` in
// the host's environment (or `_verifyConformanceIndex` set) each no is
// checked against the runtime, and a difference logged ("[conformance] …").

/// A protocol the index knows.
enum _IndexedProtocol: Int, CaseIterable {
    case equatable, primitiveView, multiView, shape

    /// The protocol's existential type, whose metadata names its descriptor.
    var existential: Any.Type {
        switch self {
        case .equatable: return (any Equatable).self
        case .primitiveView: return (any _PrimitiveView).self
        case .multiView: return (any _MultiView).self
        case .shape: return (any Shape).self
        }
    }
}

/// False when `type` cannot conform to `proto` (no conformance record says
/// it might); true when it might, which the caller asks of the runtime.
func _mayConform(_ type: Any.Type, _ proto: _IndexedProtocol) -> Bool {
    guard let index = _ConformanceIndex.shared, let descriptors = index.descriptors(of: type) else { return true }
    let conforming = index.conforming[proto.rawValue]
    for descriptor in descriptors where conforming.contains(descriptor) { return true }
    if _verifyConformanceIndex { _verifyNo(type, proto) }
    return false
}

/// Checks each answer of no against the runtime's (tests, and
/// `ISO_VERIFY_CONFORMANCES`).
nonisolated(unsafe) package var _verifyConformanceIndex = false
nonisolated(unsafe) package var _conformanceIndexMismatches: [String] = []

private func _verifyNo(_ type: Any.Type, _ proto: _IndexedProtocol) {
    let conforms: Bool
    switch proto {
    case .equatable: conforms = type is any Equatable.Type
    case .primitiveView: conforms = type is any _PrimitiveView.Type
    case .multiView: conforms = type is any _MultiView.Type
    case .shape: conforms = type is any Shape.Type
    }
    guard conforms else { return }
    let mismatch = "\(type) conforms to \(proto), and the index said it cannot"
    _conformanceIndexMismatches.append(mismatch)
    Runtime.shared.host?.log("[conformance] \(mismatch)")
}

final class _ConformanceIndex {
    /// For each indexed protocol, the descriptors of the types with a
    /// conformance record for it.
    private(set) var conforming: [Set<UnsafeRawPointer>] = []

    /// The program's, read the first time it is asked; nil where the
    /// records cannot be reached.
    nonisolated(unsafe) static let shared: _ConformanceIndex? = {
        #if hasFeature(Extern) && os(WASI)
        let host = Runtime.shared.host
        if host?.hostValue("env:ISO_VERIFY_CONFORMANCES") != nil { _verifyConformanceIndex = true }
        let started = host?.now() ?? 0
        let index = _ConformanceIndex()
        if _verifyConformanceIndex, let host {
            let counts = index?.conforming.map { "\($0.count)" }.joined(separator: " ") ?? "none"
            host.log("[conformance] index read in \(Int((host.now() - started) * 1000)) ms: \(counts) types")
        }
        return index
        #else
        return nil
        #endif
    }()

    #if hasFeature(Extern) && os(WASI)
    private init?() {
        let wanted = _IndexedProtocol.allCases.compactMap { _protocolDescriptor(of: $0.existential) }
        guard wanted.count == _IndexedProtocol.allCases.count else { return nil }
        let reading = _ConformanceReading(wanted: wanted)
        _enumerateMetadataSections({ sections, context in
            let reading = Unmanaged<_ConformanceReading>.fromOpaque(context).takeUnretainedValue()
            // MetadataSections: version, base address, two unused words, the
            // protocols' range, then the conformances' (start, length).
            let word = MemoryLayout<UInt>.size
            let start = sections.load(fromByteOffset: word * 6, as: UInt.self)
            let length = sections.load(fromByteOffset: word * 7, as: UInt.self)
            if let records = UnsafeRawPointer(bitPattern: start) {
                reading.read(records, count: Int(length) / 4)
            }
            return true
        }, Unmanaged.passUnretained(reading).toOpaque())
        guard reading.readable else { return nil }
        conforming = reading.sets
    }
    #endif

    /// The descriptors whose records say whether `type` conforms: a struct's
    /// or an enum's own; nil for any other type (asked of the runtime). Not
    /// an Optional's: a cast looks through one to the value it holds.
    func descriptors(of type: Any.Type) -> [UnsafeRawPointer]? {
        let kind = _metadataKind(type)
        guard kind == 0x200 || kind == 0x201, let own = _typeDescriptor(type) else { return nil }
        return [own]
    }
}

#if hasFeature(Extern) && os(WASI)
@_extern(c, "swift_enumerateAllMetadataSections")
private func _enumerateMetadataSections(
    _ body: @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer) -> Bool,
    _ context: UnsafeMutableRawPointer)

/// The index being read from the sections, one after another.
private final class _ConformanceReading {
    let wanted: [UnsafeRawPointer]
    var sets: [Set<UnsafeRawPointer>]
    /// False once a record refers to its type in a way not read here.
    var readable = true

    init(wanted: [UnsafeRawPointer]) {
        self.wanted = wanted
        sets = Array(repeating: [], count: wanted.count)
    }

    /// Adds the types of the conformance records at `records` (relative
    /// pointers to conformance descriptors) to the sets of the protocols
    /// wanted.
    func read(_ records: UnsafeRawPointer, count: Int) {
        for i in 0..<count {
            let record = records + i * 4
            let descriptor = record + Int(record.load(as: Int32.self))
            // A conformance descriptor: the protocol (a relative pointer,
            // the low bit set: to a slot holding the address), the type,
            // the witness table, then the flags.
            guard let proto = _relativeIndirectable(descriptor),
                  let which = wanted.firstIndex(of: proto) else { continue }
            let flags = descriptor.load(fromByteOffset: 12, as: UInt32.self)
            let typeRef = descriptor + 4
            let offset = Int(typeRef.load(as: Int32.self))
            switch (flags >> 3) & 7 {
            case 0:
                // The type's descriptor.
                sets[which].insert(typeRef + offset)
            case 1:
                // A slot holding the type's descriptor.
                if let target = (typeRef + offset).load(as: UnsafeRawPointer?.self) { sets[which].insert(target) }
            default:
                // An Objective-C class: not read here.
                readable = false
            }
        }
    }
}

/// The target of a relative pointer whose low bit, set, says it points at
/// a slot holding the address.
private func _relativeIndirectable(_ field: UnsafeRawPointer) -> UnsafeRawPointer? {
    let offset = Int(field.load(as: Int32.self))
    guard offset != 0 else { return nil }
    let target = field + (offset & ~1)
    return offset & 1 == 0 ? target : target.load(as: UnsafeRawPointer?.self)
}

/// The descriptor of the protocol of an existential type of one protocol
/// (`(any P).self`): its metadata is its kind, its flags and its number of
/// protocols, then (without a superclass constraint) the protocols.
private func _protocolDescriptor(of existential: Any.Type) -> UnsafeRawPointer? {
    guard _metadataKind(existential) == 0x303 else { return nil }
    let metadata = unsafeBitCast(existential, to: UnsafeRawPointer.self)
    let word = MemoryLayout<UInt>.size
    let flags = metadata.load(fromByteOffset: word, as: UInt32.self)
    let count = metadata.load(fromByteOffset: word + 4, as: UInt32.self)
    guard count == 1, flags & 0x4000_0000 == 0 else { return nil }
    return metadata.load(fromByteOffset: word + 8, as: UnsafeRawPointer?.self)
}
#endif
