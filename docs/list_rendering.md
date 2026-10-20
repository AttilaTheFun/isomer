# How lists stay cheap: identity, keyed patches, reuse, lazy rows

A List on iOS costs what its changed and visible rows cost: SwiftUI keeps
each row's identity, re-evaluates only views whose inputs changed, and the
collection view underneath lays out only the rows on screen. Isomer
does the same on the component-system hosts (Compose, React), in four layers.

## 1. Identity

Every `RenderNode` records `buildPath`, the build path of the view it came
from (structural identity with `ForEach` ids in it). The encoder writes each
node's `key` (tree.fbs slot 49) relative to the nearest ancestor with a
path, and names handlers by a hash of the node's identity (`n<base36>.tap`),
so a row's handler ids and key hold while rows move around it.

## 2. Keyed patches

The diff matches children by key. A change in membership or order ships one
reorder op (`PatchOp.order` + `PatchOp.inserts`): the kept children by old
index, only the new ones inline. Ops apply in order and a node's ops precede
its children's, so later paths are positions after the reorder. Every
reader (flat_tree.js, FlatTree.kt, TreeDecoder, FlatPatchTree, the test
applier) keeps the retained child objects, and hosts key their components
on `key` (React keys, Compose `key {}` and LazyColumn item keys).

## 3. Subtree reuse (shared/swift_ui_core/Reuse.swift)

An app view (`struct: View`) whose stored properties compare equal to last
frame's, under the same environment and context stacks, with no `@State`
below it written since, hands back last frame's subtree without running its
body. The encoder then replays that subtree's flattened form and handlers,
and the diff skips it by its token.

What a subtree may contain is decided while it builds:

- Built-in views opt in with `_ReusableBuild` (or `_ModifiedView(pure:
  true)`) when their node depends only on their inputs, the environment and
  the context stacks. **A built-in view that reads or registers runtime
  state (navigation, tabs, presentations, tasks, `onChange`, remote images,
  geometry) must not opt in**: building it marks the build volatile, and no
  view around it is reused. When adding a built-in view, leave it out unless
  it is pure.
- `@ObservedObject`, `@StateObject`, `@EnvironmentObject`, `@AppStorage` and
  `@FocusState` block reuse of the view and everything around it (the core
  cannot see what such a body read).
- A view whose inputs can't be compared (closures, class references,
  bindings) rebuilds itself every frame; views inside it are still reused.
- The root view always rebuilds. A `@State` default is evaluated on every
  view init (as in SwiftUI), so make expensive defaults once.

`Runtime.shared.subtreeReuseEnabled = false` turns reuse off, for
comparisons and bisecting.

## 4. Lazy rows

On semantic hosts a List finds its rows without building them (`ForEach`
hands out ids by position and makes a row's view only when it is built),
builds the rows around the window the host reports (`window` param,
"first,last"; overscan 20; both ends before the first report), and sends the
rest as keyed placeholder cells, which hosts draw at the row's last height.
A scroll request builds its target row (a `ForEach` id, or the row last seen
holding that `.id`). Self-drawing hosts build every row.

## Measuring

`examples/shared/list_stress_application` is a chat-shaped List streaming 25
updates a second (Android: `//android/list_stress_android_application`, web:
`//web/list_stress_web_application`). On the Android emulator, 400 rows went
from 98% of a core at 14 frames/s to 20% at 32; 2000 rows from a saturated
main thread with no frames to 34% at 32 frames/s, and launch from 4.4 s to
0.66 s. On the web, 400 rows went from 40% main-thread time to 6%, and 2000
rows from 98% at 19 frames/s to 17% at 60.
