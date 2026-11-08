// Editing a list: `EditMode` (`\.editMode`, `EditButton`) and rows that a
// person deletes and moves while editing (`.onDelete`, `.onMove`). Built in
// the core from what every renderer already draws: in edit mode a deletable
// row shows a red minus before it, and a movable row a handle after it
// whose drag moves the row (following the pointer, and dropped at the row
// it was dragged to, rows taken as the list's standard height).

import Foundation

/// Whether views are being edited.
public enum EditMode: Sendable {
    case inactive
    case transient
    case active

    public var isEditing: Bool { self != .inactive }
}

/// The window's own edit mode, which `\.editMode` binds to unless an
/// ancestor puts another binding in the environment.
@MainActor
final class _WindowEditMode {
    static let shared = _WindowEditMode()
    var mode: EditMode = .inactive {
        didSet {
            guard mode != oldValue else { return }
            // The views that read it (each read is noted, as a @State's)
            // build again: in a partial frame by the key's readers, in a
            // whole build by each reader's own key.
            let runtime = Runtime.shared
            runtime.stateKeys.insert(Self.key)
            runtime.stateDidChange(key: Self.key)
            for reader in runtime.stateReaders[Self.key] ?? [] {
                runtime.stateDidChange(key: reader + Self.key)
            }
            runtime.requestFrame()
        }
    }

    /// The key its reads and changes are noted under.
    static let key = "#editMode"
}

struct _EditModeKey: EnvironmentKey {
    static let defaultValue: Binding<EditMode>? = nil
}

extension EnvironmentValues {
    /// The edit mode the views below follow: the window's, or the binding an
    /// ancestor set (`.environment(\.editMode, $mode)`).
    public var editMode: Binding<EditMode>? {
        get {
            self[_EditModeKey.self] ?? MainActor.assumeIsolated {
                Binding(get: {
                    _noteStateRead(_WindowEditMode.key)
                    return _WindowEditMode.shared.mode
                }, set: { _WindowEditMode.shared.mode = $0 })
            }
        }
        set { self[_EditModeKey.self] = newValue }
    }
}

/// A button that turns editing on ("Edit") and off ("Done").
public struct EditButton: View {
    @Environment(\.editMode) private var editMode

    nonisolated public init() {}

    public var body: some View {
        let editing = editMode?.wrappedValue.isEditing ?? false
        return Button(editing ? "Done" : "Edit") {
            editMode?.wrappedValue = editing ? .inactive : .active
        }
    }
}

extension DynamicViewContent {
    /// `.onMove(perform:)`: while editing, each row has a handle whose drag
    /// moves it, handing `action` the row's offset and where it goes (an
    /// offset into the rows before the move, as `move(fromOffsets:toOffset:)`
    /// takes it). `nil` turns it off.
    nonisolated public func onMove(perform action: Optional<(IndexSet, Int) -> Void>) -> some DynamicViewContent {
        _MovableRows(base: self, action: action)
    }
}

/// A `ForEach` with `.onMove`: its rows, each with a move handle while editing.
struct _MovableRows<Base: DynamicViewContent>: DynamicViewContent {
    let base: Base
    let action: ((IndexSet, Int) -> Void)?

    var data: Base.Data { base.data }
    typealias Body = Never
}

extension _MovableRows: _IndexedRows {
    func indexedRows() -> _ForEachRows {
        guard let indexed = base as? _IndexedRows else {
            return _ForEachRows(count: 1, id: { _ in "0" }, view: { _ in base })
        }
        let rows = indexed.indexedRows()
        guard let action else { return rows }
        return _ForEachRows(count: rows.count, id: rows.id, view: { offset in
            _MovableRow(content: AnyView(rows.view(offset)), offset: offset, count: rows.count, move: action)
        })
    }
}

extension _MovableRows: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        let rows = indexedRows()
        return (0..<rows.count).map { ("fe-" + rows.id($0), rows.view($0)) }
    }
}

/// A row that moves while editing: its handle's drag carries it.
struct _MovableRow: View {
    let content: AnyView
    let offset: Int
    let count: Int
    let move: (IndexSet, Int) -> Void
    @Environment(\.editMode) private var editMode
    @State private var dragged: CGFloat = 0

    /// A list row's standard height, how far a drag goes per row.
    static let rowHeight: CGFloat = 44

    var body: some View {
        if editMode?.wrappedValue.isEditing ?? false {
            HStack {
                content
                Spacer(minLength: 8)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { dragged = $0.translation.height }
                        .onEnded { value in
                            let steps = Int((value.translation.height / Self.rowHeight).rounded())
                            dragged = 0
                            let target = min(max(offset + steps, 0), count - 1)
                            guard target != offset else { return }
                            // Past the rows below, the destination counts the
                            // row itself (move(fromOffsets:toOffset:)'s rule).
                            move(IndexSet(integer: offset), target > offset ? target + 1 : target)
                        })
            }
            .offset(y: dragged)
        } else {
            content
        }
    }
}

/// A deletable row while editing: a red minus before it, which deletes it.
struct _DeletableEditingRow: View {
    let content: AnyView
    let delete: () -> Void
    @Environment(\.editMode) private var editMode

    var body: some View {
        if editMode?.wrappedValue.isEditing ?? false {
            HStack(spacing: 12) {
                Button(action: delete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
                content
            }
        } else {
            content
        }
    }
}

/// A row wrapped for editing (its minus, its move handle): its tag is the
/// row's (`rowTag(of:)`).
protocol _EditingRow {
    var content: AnyView { get }
}

extension _MovableRow: _EditingRow {}
extension _DeletableEditingRow: _EditingRow {}
