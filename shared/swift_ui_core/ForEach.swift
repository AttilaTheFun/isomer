public struct ForEach<Data, Content: View> {
    /// The rows, by position: how many, each one's id, and each one's view
    /// made only when asked for (a lazy List builds the rows it shows).
    let rows: () -> _ForEachRows
    /// The collection, as it is now (`DynamicViewContent.data`).
    let currentData: () -> Any

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

/// A ForEach's rows by position; `view` makes the row's view on demand.
struct _ForEachRows {
    let count: Int
    let id: (Int) -> String
    let view: (Int) -> any View
}

/// A ForEach seen through its rows, whatever its data and content.
protocol _IndexedRows {
    func indexedRows() -> _ForEachRows
}

extension ForEach: _IndexedRows {
    func indexedRows() -> _ForEachRows { rows() }
}

extension ForEach where Data == Range<Int> {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        currentData = { data }
        rows = {
            _ForEachRows(count: data.count, id: { String(data.lowerBound + $0) }, view: { content(data.lowerBound + $0) })
        }
    }
}

extension ForEach where Data: RandomAccessCollection, Data.Element: Identifiable {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        currentData = { data }
        rows = {
            let element = { (offset: Int) in data[data.index(data.startIndex, offsetBy: offset)] }
            return _ForEachRows(count: data.count, id: { "\(element($0).id)" }, view: { content(element($0)) })
        }
    }

    /// Rows tagged with their elements' ids, as a selectable List's are
    /// (`List(items, selection:)`): the row collector reads a row's tag.
    init(taggingRowsOf data: Data, content: @escaping (Data.Element) -> Content) {
        currentData = { data }
        rows = {
            let element = { (offset: Int) in data[data.index(data.startIndex, offsetBy: offset)] }
            return _ForEachRows(count: data.count, id: { "\(element($0).id)" }, view: {
                let row = element($0)
                return _TaggedView(value: row.id, inner: content(row))
            })
        }
    }
}

extension ForEach where Data: RandomAccessCollection {
    public init<ID: Hashable>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        currentData = { data }
        rows = {
            let element = { (offset: Int) in data[data.index(data.startIndex, offsetBy: offset)] }
            return _ForEachRows(count: data.count, id: { "\(element($0)[keyPath: id])" }, view: { content(element($0)) })
        }
    }
}

extension ForEach: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        let rows = self.rows()
        return (0..<rows.count).map { ("fe-" + rows.id($0), rows.view($0)) }
    }
}


/// A binding to the element of `data` at `offset` when the rows were made,
/// found by its id when read or written: a row edits the element it shows
/// even as others come and go around it.
func _elementBinding<C: MutableCollection & RandomAccessCollection, ID: Hashable>(
    _ data: Binding<C>, at offset: Int, id: KeyPath<C.Element, ID>
) -> Binding<C.Element> {
    let collection = data.wrappedValue
    let element = collection[collection.index(collection.startIndex, offsetBy: offset)]
    let key = element[keyPath: id]
    var binding = Binding<C.Element>(
        get: { data.wrappedValue.first { $0[keyPath: id] == key } ?? element },
        set: { new in
            var value = data.wrappedValue
            guard let index = value.firstIndex(where: { $0[keyPath: id] == key }) else { return }
            value[index] = new
            data.wrappedValue = value
        })
    // The same state as the collection's, the same element: equal from one
    // build to the next, and read where the collection is.
    binding._stateKey = data._stateKey
    binding._identity = data._identity.map { AnyHashable([$0, AnyHashable(key)]) }
    return binding
}

extension ForEach where Data: MutableCollection & RandomAccessCollection {
    /// `ForEach($items) { $item in … }`: each row with a binding to its
    /// element.
    public init(
        _ data: Binding<Data>,
        @ViewBuilder content: @escaping (Binding<Data.Element>) -> Content
    ) where Data.Element: Identifiable {
        self.init(data, id: \.id, content: content)
    }

    public init<ID: Hashable>(
        _ data: Binding<Data>,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Binding<Data.Element>) -> Content
    ) {
        currentData = { data.wrappedValue }
        rows = {
            let collection = data.wrappedValue
            let element = { (offset: Int) in collection[collection.index(collection.startIndex, offsetBy: offset)] }
            return _ForEachRows(count: collection.count, id: { "\(element($0)[keyPath: id])" },
                                view: { content(_elementBinding(data, at: $0, id: id)) })
        }
    }
}

/// A view made of a collection's elements, one view each (`ForEach`):
/// Apple's protocol, which `.onDelete` belongs to.
public protocol DynamicViewContent<Data>: View {
    associatedtype Data: Collection
    var data: Data { get }
}

extension ForEach: DynamicViewContent where Data: Collection {
    public var data: Data { currentData() as! Data }
}

extension DynamicViewContent {
    /// `.onDelete(perform:)`: each row can be deleted the platform's way,
    /// a trailing swipe (a full swipe deletes), handing the row's offset to
    /// `action`. `nil` turns it off.
    nonisolated public func onDelete(perform action: Optional<(IndexSet) -> Void>) -> some DynamicViewContent {
        _DeletableRows(base: self, action: action)
    }
}

/// A `ForEach` with `.onDelete`: its rows, each with the delete swipe.
struct _DeletableRows<Base: DynamicViewContent>: DynamicViewContent {
    let base: Base
    let action: ((IndexSet) -> Void)?

    var data: Base.Data { base.data }
    typealias Body = Never
}

extension _DeletableRows: _IndexedRows {
    func indexedRows() -> _ForEachRows {
        guard let indexed = base as? _IndexedRows else {
            return _ForEachRows(count: 1, id: { _ in "0" }, view: { _ in base })
        }
        let rows = indexed.indexedRows()
        guard let action else { return rows }
        return _ForEachRows(count: rows.count, id: rows.id, view: { offset in
            AnyView(rows.view(offset)).swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { action(IndexSet(integer: offset)) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        })
    }
}

extension _DeletableRows: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        let rows = indexedRows()
        return (0..<rows.count).map { ("fe-" + rows.id($0), rows.view($0)) }
    }
}

extension RangeReplaceableCollection where Self: MutableCollection {
    /// What an `.onDelete` handler calls: removes the elements at these
    /// offsets.
    public mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) where offset < count {
            remove(at: index(startIndex, offsetBy: offset))
        }
    }
}

extension MutableCollection {
    /// What an `.onMove` handler calls: moves the elements at `source` to
    /// before `destination`, the rest keeping their order.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let elements = Array(self)
        let moving = source.filter { $0 < elements.count }
        let kept = elements.indices.filter { !moving.contains($0) }
        let at = Swift.min(Swift.max(destination - moving.filter { $0 < destination }.count, 0), kept.count)
        let order = Array(kept[..<at]) + moving + Array(kept[at...])
        for (offset, from) in order.enumerated() {
            self[index(startIndex, offsetBy: offset)] = elements[from]
        }
    }
}



// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension ForEach: View {}
