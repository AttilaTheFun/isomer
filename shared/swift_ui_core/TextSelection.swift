// What of a text is selected, or where its caret is (SwiftUI's
// TextSelection, iOS 18), and the text field that reports it
// (`TextField(_:text:selection:)`).
//
// Hosts that report a field's selection (the web's, Android's, the Apple
// tree view's on iOS 18 and macOS 15) set the binding as the person moves
// the caret or selects, and show a selection the app sets (a completion
// that puts the insertion point after what it inserted). Where a host
// reports none, the binding follows the end of the text as it is typed
// into. Selections cross to the host as UTF-16 offsets.
//
// In a feature compiled against Isomer's frameworks on an Apple platform
// (ISOMER_COMPILED_FEATURE) it is there on every OS the app supports; the
// standard library's RangeSet needs iOS 18, so a selection's ranges there are
// IsomerCompiledBackports' (apple/libraries/compiled_backports).

#if ISOMER_COMPILED_FEATURE
import IsomerCompiledBackports
#endif

#if !ISOMER_COMPILED_FEATURE
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
#endif
public struct TextSelection: Equatable, Hashable {
    public enum Indices: Equatable, Hashable {
        case selection(Range<String.Index>)
        #if ISOMER_COMPILED_FEATURE
        case multiSelection(IsomerCompiledBackports.RangeSet<String.Index>)
        #else
        case multiSelection(RangeSet<String.Index>)
        #endif
    }

    public var indices: Indices

    /// Which side of a line break the caret belongs to: always the system's
    /// choice here.
    public var affinity: TextSelectionAffinity { .automatic }

    public init(range: Range<String.Index>) {
        indices = .selection(range)
    }

    #if ISOMER_COMPILED_FEATURE
    public init(ranges: IsomerCompiledBackports.RangeSet<String.Index>) {
        indices = .multiSelection(ranges)
    }
    #else
    public init(ranges: RangeSet<String.Index>) {
        indices = .multiSelection(ranges)
    }
    #endif

    public init(insertionPoint: String.Index) {
        indices = .selection(insertionPoint ..< insertionPoint)
    }

    /// A caret rather than a range of text.
    public var isInsertion: Bool {
        if case .selection(let range) = indices { return range.isEmpty }
        return false
    }
}

#if !ISOMER_COMPILED_FEATURE
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
#endif
public enum TextSelectionAffinity: Equatable, Hashable, Sendable {
    case automatic
    case upstream
    case downstream
}

#if !ISOMER_COMPILED_FEATURE
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
#endif
extension TextField {
    /// A field that says where its caret is, and shows a selection the app
    /// sets (see the top of this file).
    public init<S: StringProtocol>(
        _ title: S, text: Binding<String>, selection: Binding<TextSelection?>, prompt: Text? = nil, axis: Axis? = nil
    ) {
        self.init(prompt?.content ?? String(title), text: text, axis: axis ?? .horizontal)
        self.selection = FieldSelectionBinding(
            get: {
                guard let value = selection.wrappedValue else { return nil }
                return value.utf16Offsets(in: text.wrappedValue)
            },
            set: { start, end in
                let string = text.wrappedValue
                selection.wrappedValue = TextSelection(range: string.utf16Index(start) ..< string.utf16Index(max(start, end)))
            }
        )
    }
}

#if !ISOMER_COMPILED_FEATURE
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
#endif
extension TextSelection {
    /// The selected range's bounds in `text`, as UTF-16 offsets (a
    /// multi-selection's whole span: hosts show one range).
    func utf16Offsets(in text: String) -> (Int, Int) {
        let range: Range<String.Index>
        switch indices {
        case .selection(let selected): range = selected
        case .multiSelection(let ranges): range = (ranges.ranges.first?.lowerBound ?? text.endIndex) ..< (ranges.ranges.last?.upperBound ?? text.endIndex)
        }
        let offset = { (index: String.Index) in min(index, text.endIndex).utf16Offset(in: text) }
        return (offset(range.lowerBound), offset(range.upperBound))
    }
}

extension String {
    /// The index `offset` UTF-16 units in (clamped to the string; inside a
    /// surrogate pair, the scalar's start).
    func utf16Index(_ offset: Int) -> String.Index {
        let clamped = Swift.min(Swift.max(0, offset), utf16.count)
        let index = utf16.index(utf16.startIndex, offsetBy: clamped)
        return index.samePosition(in: unicodeScalars) ?? unicodeScalars.index(before: index)
    }
}

/// A field's `selection` binding as UTF-16 offsets into its text, so that
/// TextField (on every OS) can hold it.
struct FieldSelectionBinding {
    let get: () -> (Int, Int)?
    let set: (Int, Int) -> Void
}

/// What a field's selection last was on each side, kept across frames by
/// the field's place in the tree: so that a selection the app sets is sent
/// to the host once (a numbered request), and the host's own reports, coming
/// back through the binding, are not sent back to it as requests (an old
/// one would move the caret back while the person types).
package final class FieldSelectionState {
    /// The selection the host last reported (or, before any report, the
    /// caret following the end of the text).
    var reported: [Int]?
    /// The selection the app last asked for, and how many it has asked for.
    var requested: [Int]?
    var request = 0
    /// A report came after the last request (asking for the same again is
    /// a new request).
    var reportedSinceRequest = false
    /// The host reports the selection.
    var hostReports = false
}

extension TextField {
    /// Connects `selection` to the field's node (`selectionGet`/`selectionSet`).
    func connect(_ selection: FieldSelectionBinding, to node: RenderNode, at path: String) {
        let state = Runtime.shared.fieldSelections[path] ?? FieldSelectionState()
        Runtime.shared.fieldSelections[path] = state
        node.selectionGet = {
            if let current = selection.get().map({ [$0.0, $0.1] }), current != state.reported,
               current != state.requested || state.reportedSinceRequest {
                state.request += 1
                state.requested = current
                state.reportedSinceRequest = false
            }
            guard state.request > 0, let requested = state.requested else { return nil }
            return (requested[0], requested[1], state.request)
        }
        node.selectionSet = { start, end in
            state.hostReports = true
            state.reported = [start, end]
            state.reportedSinceRequest = true
            selection.set(start, end)
        }
        // A host that reports nothing: the caret follows the end of the
        // text as it is typed into (not a request: the host's caret is there).
        let setText = node.textSet
        let text = self.text
        node.textSet = { value in
            setText?(value)
            guard !state.hostReports else { return }
            let end = text.wrappedValue.utf16.count
            state.reported = [end, end]
            selection.set(end, end)
        }
    }
}
