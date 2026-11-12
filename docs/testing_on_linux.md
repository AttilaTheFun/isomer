# An app's UI tests on Linux

The owner's rule (2026-11-12): an app's unit, integration and headless UI
tests run as `swift_test` on Linux with Swift Testing, linked against
Isomer's frameworks; only the headful UI tests that also make the proof run
on their own platforms. This is how an app repository does that. The
examples' `headless/storybook_headless_application` is the worked example
(the Storybook's own tests, which CI's container runs on every pull request).

## What runs where

- **Headless, on Linux** (CI's container, every pull request): the app's
  SwiftUI built for Isomer's headless host (`--@isomer//headless`). Nothing
  is drawn; the UI is read and used through Isomer's runtime, with layout
  computed as the GPU renderer would (`app.layout()`). A test takes seconds.
- **Headful, on each platform** (by hand, for the proof): the same test
  source against the app built for the platform with its driver
  (`--@isomer//drive:headful`), started by a launcher (docs/drive.md,
  "Tests"). Only these take pictures.

## The setup

The app's MODULE.bazel takes isomer by version from the project's registry
and declares the Swift toolchains, as README's "Using Isomer" says
(examples/MODULE.bazel is the block to copy). Linux needs nothing more:
the headless host uses the toolchain's own Foundation there.

## The targets

The app's SwiftUI is a library that names Isomer's SwiftUI rather than
assuming the SDK's, so one source builds for every target:

```starlark
load("@rules_swift//swift:swift.bzl", "swift_binary", "swift_library", "swift_test")

# The app's views and models: Apple's SwiftUI on Apple platforms, Isomer's
# elsewhere (@isomer//:swift_ui picks; --@isomer//headless picks the
# headless host's).
swift_library(
    name = "app_lib",
    srcs = glob(["Sources/**/*.swift"]),
    module_name = "MyApp",
    deps = [
        "@isomer//:foundation",
        "@isomer//:swift_ui",
    ],
)

# The app headless: its `@main` App on the headless host. Its fixtures come
# from the environment (`MYAPP_FIXTURE=chat`), as a test launches it.
swift_binary(
    name = "my_app_headless",
    srcs = ["Headless/Main.swift"],
    deps = [
        ":app_lib",
        "@isomer//headless/libraries/swift_ui",
    ],
)

swift_test(
    name = "ui_test",
    srcs = ["Tests/ChatTests.swift"],
    data = [":my_app_headless"],
    deps = ["@isomer//headless/isomer_headless"],
)
```

Run them with the flag, in a Shireworks Linux container (never on a Mac's
own disk; AGENTS.md):

```sh
bazel test --@isomer//headless //:ui_test
```

(`build:headless --@isomer//headless` in the app's .bazelrc, and CI's
`bazel test --config=headless //...`, keep it to one word.)

## A test

```swift
import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct ChatTests {
    /// The app built headless, from the test's runfiles, with a fixture.
    func launch(_ fixture: String) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(executable: "\(root)/my_app_headless", environment: ["MYAPP_FIXTURE": fixture])
    }

    @Test func sendsAMessage() throws {
        let app = try launch("chat")
        try app.type("Message", "Hello")
        try app.tap("Send")
        try app.wait(for: "Hello")
        #expect(try app.screen().shows("Delivered"))
    }
}
```

`HeadlessApp` finds elements by name, label or accessibility identifier, and
has `tap`, `type`, `set`, `select`, `swipe`, `back`, `dismiss`, `wait(for:)`,
`inspect`, `screen()` and `layout()` (frames, as the GPU renderer lays them
out). To run the same source headful for the proof, its `launch` also takes
a launcher when the environment names one (`ISOMER_HEADFUL_LAUNCHER`), or the
app it runs inside (`HeadlessApp.hostedIfAny()`): StorybookHeadlessTests.swift's
`launch` does all three, and `app.picture(name)` takes the proof's pictures
there.

## A native SwiftUI app (not built on Isomer)

An app written for Apple's SwiftUI can take the same path, with these gaps:

- **It is built with Bazel.** The headless host and IsomerHeadless are Bazel
  targets, not products of Isomer's Swift package, so an app built only with
  SwiftPM or Xcode can't link them yet. Isomer would add them as package
  products (IsomerHeadlessHost, IsomerHeadless) for `swift test` on Linux;
  until then the app needs a BUILD file for its tests.
- **Its source compiles against Isomer's SwiftUI.** That is a strict subset
  of Apple's (docs/parity/SwiftUI.md; what is missing, by area, in
  docs/parity/missing/SwiftUI.md). An API Isomer lacks fails to compile.
  UIKit, AppKit and Apple-only frameworks (StoreKit, MapKit, AVKit…) go
  behind `#if canImport(…)`, and a view using them gets an Isomer-side
  stand-in or is left out of the headless build.
- **Its library depends on `@isomer//:swift_ui` and `@isomer//:foundation`**,
  so the flag can swap them; on Apple platforms they are Apple's frameworks,
  so its Apple builds don't change.
- **Its fixtures are reachable from the environment** (or launch
  arguments), since a headless test starts the app rather than reaching into
  it.
- **Keyboard behaviour is out of reach:** `type` sets text, so
  autocorrection, dictation and the system keyboard stay with XCUITest on a
  simulator.
