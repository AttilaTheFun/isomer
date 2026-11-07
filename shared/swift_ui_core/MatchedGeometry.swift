// `@Namespace` and `matchedGeometryEffect`: a view in one place and a view
// in another that are "the same" (by an id in a namespace), so when one
// goes and the other comes, the newcomer starts where the other was and
// moves (and resizes) to its own frame. The node carries the pairing's key
// (param "match"); the hosts animate it, React by FLIP: the element that
// mounts with a key another element had starts at that element's last
// frame and transitions to its own. Compose draws the newcomer in place,
// without the move, for now.

/// `@Namespace`: a namespace of its own for each view that declares one,
/// kept while the view lives, for `matchedGeometryEffect`'s ids.
@propertyWrapper
public struct Namespace: _DynamicProperty, Sendable {
    let backing = _NamespaceBacking()

    public init() {}

    public var wrappedValue: Namespace.ID {
        Namespace.ID(id: backing.id ?? 0)
    }

    public struct ID: Hashable, Sendable {
        let id: Int
    }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        if let existing = storage.locations[key] as? _NamespaceBacking {
            backing.id = existing.id
        } else {
            _namespaceCount += 1
            backing.id = _namespaceCount
            let kept = _NamespaceBacking()
            kept.id = _namespaceCount
            storage.locations[key] = kept
        }
    }
}

/// The namespace's number, found in the view's storage when it connects.
final class _NamespaceBacking: @unchecked Sendable {
    var id: Int?
}

nonisolated(unsafe) var _namespaceCount = 0

/// Which of a matched view's geometry follows the other's.
public struct MatchedGeometryProperties: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let position = MatchedGeometryProperties(rawValue: 1 << 0)
    public static let size = MatchedGeometryProperties(rawValue: 1 << 1)
    public static let frame: MatchedGeometryProperties = [.position, .size]
}

extension View {
    /// Pairs this view with the others of the same `id` in `namespace`: when
    /// one is removed and another inserted (in one change, `withAnimation`),
    /// the new one starts at the old one's frame and moves to its own.
    nonisolated public func matchedGeometryEffect<ID>(
        id: ID, in namespace: Namespace.ID, properties: MatchedGeometryProperties = .frame,
        anchor: UnitPoint = .center, isSource: Bool = true
    ) -> some View where ID: Hashable {
        let key = "\(namespace.id):\(String(reflecting: ID.self)):\(id)"
        return _ModifiedView(child: self, descend: "matched", pure: true) { inner, _ in
            inner.matchedGeometry = (key: key, properties: properties.rawValue, isSource: isSource)
            return inner
        }
    }
}
