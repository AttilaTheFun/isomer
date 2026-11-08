// `editActions:`: a List or ForEach over a binding whose rows the person may
// delete (a swipe, or the minus in edit mode) and move (the handles in edit
// mode), each written straight back to the collection, as Apple's: no
// `onDelete`/`onMove` handler of the app's own. Built on those
// (ForEach.swift, ListEditing.swift).

import Foundation

/// The edits a List or ForEach over a binding allows: deleting needs a
/// collection that can remove elements, moving one that can reorder them.
public struct EditActions<Data>: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    @available(*, unavailable, message: "Delete is available only for collections conforming to RangeReplaceableCollection.")
    public static var delete: EditActions<Data> { EditActions(rawValue: 1 << 0) }

    @available(*, unavailable, message: "Move is available only for collections conforming to MutableCollection.")
    public static var move: EditActions<Data> { EditActions(rawValue: 1 << 1) }

    public static var all: EditActions<Data> { EditActions(rawValue: 0) }

    var deletes: Bool { rawValue & 1 << 0 != 0 }
    var moves: Bool { rawValue & 1 << 1 != 0 }
}

extension EditActions where Data: RangeReplaceableCollection {
    public static var delete: EditActions<Data> { EditActions(rawValue: 1 << 0) }
    public static var all: EditActions<Data> { EditActions(rawValue: 1 << 0) }
}

extension EditActions where Data: MutableCollection {
    public static var move: EditActions<Data> { EditActions(rawValue: 1 << 1) }
    public static var all: EditActions<Data> { EditActions(rawValue: 1 << 1) }
}

extension EditActions where Data: MutableCollection, Data: RangeReplaceableCollection {
    public static var all: EditActions<Data> { EditActions(rawValue: 1 << 0 | 1 << 1) }
}

/// The rows of a ForEach with `editActions:`: each element of the collection
/// with its index and id.
public struct IndexedIdentifierCollection<Base: Collection, ID: Hashable>: Collection {
    public struct Element {
        let index: Base.Index
        let id: ID
    }

    public typealias Index = Base.Index

    let base: Base
    let identifier: KeyPath<Base.Element, ID>

    public var startIndex: Index { base.startIndex }
    public var endIndex: Index { base.endIndex }

    public subscript(position: Index) -> Element {
        Element(index: position, id: base[position][keyPath: identifier])
    }

    public func index(after i: Index) -> Index { base.index(after: i) }
}

extension IndexedIdentifierCollection: BidirectionalCollection where Base: BidirectionalCollection {
    public func index(before i: Index) -> Index { base.index(before: i) }
}

extension IndexedIdentifierCollection: RandomAccessCollection where Base: RandomAccessCollection {
    public func index(_ i: Index, offsetBy distance: Int) -> Index { base.index(i, offsetBy: distance) }
    public func distance(from start: Index, to end: Index) -> Int { base.distance(from: start, to: end) }
}

/// A row of a ForEach with `editActions:`: the app's row, its deletes and
/// moves the ForEach's.
public struct EditableCollectionContent<Content, Data> {
    let content: Content
}

extension EditableCollectionContent: View where Content: View {
    public var body: some View { content }
}

/// The collection less the elements at `offsets`, when it can remove them.
private func _removing<C>(_ value: C, at offsets: IndexSet) -> C {
    guard let removable = value as? any RangeReplaceableCollection else { return value }
    func remove<R: RangeReplaceableCollection>(_ collection: R) -> R {
        var collection = collection
        for offset in offsets.sorted(by: >) where offset < collection.count {
            collection.remove(at: collection.index(collection.startIndex, offsetBy: offset))
        }
        return collection
    }
    return remove(removable) as? C ?? value
}

extension ForEach {
    /// `ForEach($items, editActions: .all) { $item in … }`: rows with a
    /// binding each, which the person may delete and move, the collection
    /// written as they do.
    public init<C, R>(
        _ data: Binding<C>,
        editActions: EditActions<C>,
        @ViewBuilder content: @escaping (Binding<C.Element>) -> R
    ) where Data == IndexedIdentifierCollection<C, ID>, ID == C.Element.ID,
        Content == EditableCollectionContent<R, C>, C: MutableCollection, C: RandomAccessCollection,
        R: View, C.Element: Identifiable, C.Index: Hashable
    {
        self.init(data, id: \.id, editActions: editActions, content: content)
    }

    public init<C, R>(
        _ data: Binding<C>,
        id: KeyPath<C.Element, ID>,
        editActions: EditActions<C>,
        @ViewBuilder content: @escaping (Binding<C.Element>) -> R
    ) where Data == IndexedIdentifierCollection<C, ID>, Content == EditableCollectionContent<R, C>,
        C: MutableCollection, C: RandomAccessCollection, R: View, C.Index: Hashable
    {
        self.init(editing: data, id: id, editActions: editActions, taggingRows: false, content: content)
    }

    /// The rows tagged with their elements' ids when `taggingRows`, as a
    /// selectable List's are.
    init<C, R>(
        editing data: Binding<C>,
        id: KeyPath<C.Element, ID>,
        editActions: EditActions<C>,
        taggingRows: Bool,
        content: @escaping (Binding<C.Element>) -> R
    ) where Data == IndexedIdentifierCollection<C, ID>, Content == EditableCollectionContent<R, C>,
        C: MutableCollection, C: RandomAccessCollection, R: View
    {
        var editable: any DynamicViewContent = taggingRows
            ? ForEach<C, ID, _TaggedView<ID, R>>(data, id: id) { _TaggedView(value: $0.wrappedValue[keyPath: id], inner: content($0)) }
            : ForEach<C, ID, R>(data, id: id, content: content)
        if editActions.deletes {
            editable = editable.onDelete { offsets in
                data.wrappedValue = _removing(data.wrappedValue, at: offsets)
            }
        }
        if editActions.moves {
            editable = editable.onMove { source, destination in
                data.wrappedValue.move(fromOffsets: source, toOffset: destination)
            }
        }
        let indexed = editable as! _IndexedRows
        self.rows = { indexed.indexedRows() }
        self.currentData = { IndexedIdentifierCollection(base: data.wrappedValue, identifier: id) }
    }
}

extension List {
    /// `List($items, editActions: .all) { $item in … }`.
    public init<Data, RowContent>(
        _ data: Binding<Data>,
        editActions: EditActions<Data>,
        @ViewBuilder rowContent: @escaping (Binding<Data.Element>) -> RowContent
    ) where Content == ForEach<IndexedIdentifierCollection<Data, Data.Element.ID>, Data.Element.ID,
        EditableCollectionContent<RowContent, Data>>, Data: MutableCollection, Data: RandomAccessCollection,
        RowContent: View, Data.Element: Identifiable, Data.Index: Hashable
    {
        self.init { ForEach(data, editActions: editActions, content: rowContent) }
    }

    public init<Data, ID, RowContent>(
        _ data: Binding<Data>,
        id: KeyPath<Data.Element, ID>,
        editActions: EditActions<Data>,
        @ViewBuilder rowContent: @escaping (Binding<Data.Element>) -> RowContent
    ) where Content == ForEach<IndexedIdentifierCollection<Data, ID>, ID, EditableCollectionContent<RowContent, Data>>,
        Data: MutableCollection, Data: RandomAccessCollection, ID: Hashable, RowContent: View, Data.Index: Hashable
    {
        self.init { ForEach(data, id: id, editActions: editActions, content: rowContent) }
    }
}

extension List {
    /// `List($items, editActions: .all, selection: $selected) { $item in … }`:
    /// rows select by their elements' ids.
    public init<Data, RowContent, SelectionValue: Hashable>(
        _ data: Binding<Data>,
        editActions: EditActions<Data>,
        selection: Binding<SelectionValue?>?,
        @ViewBuilder rowContent: @escaping (Binding<Data.Element>) -> RowContent
    ) where Content == ForEach<IndexedIdentifierCollection<Data, Data.Element.ID>, Data.Element.ID,
        EditableCollectionContent<RowContent, Data>>, Data: MutableCollection, Data: RandomAccessCollection,
        RowContent: View, Data.Element: Identifiable, Data.Index: Hashable
    {
        self.init(selection: selection) {
            ForEach(editing: data, id: \.id, editActions: editActions, taggingRows: true, content: rowContent)
        }
    }
}
