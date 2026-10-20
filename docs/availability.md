# Availability

Isomer's floor is **iOS 15 / macOS 12** (since 2026-10-01; it was iOS 16 /
macOS 13). Apps and standalone packages built on it may ask for more; the
framework itself may not. Where the framework's own Apple hosts use an API
newer than the floor — the wasm tree host's `NavigationStack` and
`NavigationSplitView` — they take it inside `#available` and fall back to
`NavigationView` below it (compiled at the floor; no iOS 15 simulator here
has run the fallback).

## The rule

An API that Apple shipped later than the floor carries Apple's own
availability, spelled exactly as Apple spells it:

```swift
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public func toolbarTitleDisplayMode(_ mode: ToolbarTitleDisplayMode) -> some View
```

This does two things at once, which is the whole reason it works.

On Apple the attribute names the real platforms, so the rules are Apple's —
and they are Apple's whichever renderer is drawing. An app at iOS 16 gets the
same error from our declaration in the GPU tier that it gets from Apple's
SwiftUI in the native tier. That is the promise: *behave identically to native
SwiftUI on the OS version you target*.

On the platforms we implement ourselves — web, Android, Linux, Windows — the
attribute names nothing, the trailing `*` applies, and the API is
unconditionally available. Our implementation has no OS behind it to be older
than, so there is no floor to honour and callers need no `#available`.

One source, ungated, proves it: `.toolbarTitleDisplayMode(.inline)` is an
error on Apple at iOS 16 and compiles free on wasm.

## Where the attribute goes

On the way in, not on the storage. `NavigationSplitView`'s
`preferredCompactColumn:` initialisers are gated; the stored property keeps
our own unannotated `NavigationSplitViewColumn`. A stored property's type
cannot be wrapped in `#available`, so gating the type instead of the
initialiser would make the whole view unusable below the floor.

## What this means for a consumer

Code targeting the floor gates the call as a native app would:

```swift
@ViewBuilder func inlineNavigationTitle() -> some View {
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
        toolbarTitleDisplayMode(.inline)
    } else {
        self
    }
}
```

`#available` is inert off Apple in the same way the attribute is, so the
gated helper is portable and compiles everywhere.

## Currently gated

`toolbarTitleDisplayMode`, `defaultScrollAnchor`, `inspector(isPresented:)`,
and `NavigationSplitView`'s `preferredCompactColumn:` initialisers — all
iOS 17 / macOS 14.
