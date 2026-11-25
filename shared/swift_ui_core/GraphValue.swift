// What `View`'s own requirements pass, under Apple's names (Apple's SwiftUI
// declares these types public, with nothing public inside them but
// `_GraphValue`'s subscript and equality). Each view says what it is
// through `_makeView` and `_makeViewList` (View.swift), statically, rather
// than the builder asking with casts (docs/frameworks_in_the_sdk.md, phase
// 1, step 1). Isomer's carry the build in progress.

/// A view's value as its `_makeView` sees it.
public struct _GraphValue<Value>: Equatable {
    let value: Value
    /// Which build made it: two are equal when they are the same value of
    /// the same build (Apple's compare the attribute they name).
    let token: UInt32

    init(_ value: Value) {
        self.value = value
        _graphValueTokens &+= 1
        token = _graphValueTokens
    }

    private init(value: Value, token: UInt32) {
        self.value = value
        self.token = token
    }

    public subscript<U>(keyPath: KeyPath<Value, U>) -> _GraphValue<U> {
        _GraphValue<U>(value: value[keyPath: keyPath], token: token)
    }

    public static func == (a: _GraphValue<Value>, b: _GraphValue<Value>) -> Bool {
        a.token == b.token
    }
}

nonisolated(unsafe) private var _graphValueTokens: UInt32 = 0

/// The build a view's `_makeView` takes part in.
public struct _ViewInputs {
    let context: UnsafeMutablePointer<BuildContext>
}

/// What a view's `_makeView` made: its node.
public struct _ViewOutputs {
    let node: RenderNode
}

/// The build a view's `_makeViewList` takes part in: its views go into
/// `nodes`, as a container's children.
public struct _ViewListInputs {
    let context: UnsafeMutablePointer<BuildContext>
    let nodes: UnsafeMutablePointer<[RenderNode]>
}

/// What a view's `_makeViewList` made (its nodes went into the inputs').
public struct _ViewListOutputs {}

/// What `_viewListCount` is asked with.
public struct _ViewListCountInputs {}
