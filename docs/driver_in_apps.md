# The driver in an app's builds

The owner's rule (2026-11-12): every app, native ones included, can be
driven by Isomer's driver in its debug and test builds, chosen by a Bazel
setting; its release builds carry no driver. This is the setting, what each
build has, and how an app embeds the driver.

## The setting

`--@isomer//drive:headful` (off by default). An app's `.bazelrc` names it
once, and its debug and test builds use the config:

```
build:drive --@isomer//drive:headful
```

```sh
bazel run //app:my_app_ios --config=drive        # a debug build to drive
bazel test //tests:proof_ios --config=drive      # the headful proof's app
bazel build //app:my_app_ios --config=release    # never with --config=drive
```

(Isomer's own `.bazelrc` and its examples' have `drive`, and `cli`, the same
thing under the name the iso CLI's docs use.)

## What each build has

- **Release** (no flag): no driver. An app on Isomer has the link it always
  has between its renderer and its Swift: the tree and the events as
  protobuf in the same process (a renderer on the app's own runtime; no
  gRPC, HTTP or WebSocket), and nothing more. An app on Apple's SwiftUI has
  nothing of the driver at all, so nothing App Review reads as private API
  (the driver turns on SwiftUI's accessibility elements on iOS with
  libAccessibility's `_AXSApplicationAccessibilitySetEnabled`) and nothing
  listening.
- **Debug and test** (`--config=drive`): the driver too. Launched with
  `ISO_DRIVER=<a hub's or a test's URL>` (simctl's `SIMCTL_CHILD_ISO_DRIVER`,
  Android's `-e ISO_DRIVER`, the web's `?ISO_DRIVER=`), the app dials out to
  it, so a test reaches an app in a simulator, an emulator or a browser tab
  that it couldn't reach into. It is then driven in its own process: an app
  on Isomer through its runtime, the same path its renderer's events take;
  an app on Apple's SwiftUI through its accessibility tree. Launched without
  ISO_DRIVER, it dials the iso CLI's hub on its machine, if one runs.
  ISO_DRIVER=none dials nowhere. Tests in the app itself (hosted, an
  `ios_unit_test` with the app as host) use the same driver without dialling
  (`HeadlessApp.hostedIfAny()`).

Headless builds (`--@isomer//headless`, docs/testing_on_linux.md) are
separate: the app runs with no renderer on the building machine, and the
test drives it there.

## Embedding the driver

- **An app on Isomer** (its SwiftUI built by Isomer's `isomer_android_app`,
  `isomer_web_app` or a Linux or Windows host): nothing to do. Each host
  links the driver when the flag is on (`@isomer//drive:headful_driver`).
- **An app on Apple's SwiftUI**: its app target depends on `@isomer//:isomer`
  (the Isomer module on Apple platforms; no `import` is needed). With the
  flag that brings the accessibility driver (`@isomer//drive/apple`), which
  starts itself as the app launches: the app's code calls nothing. Without
  the flag it brings nothing of the driver.

```starlark
ios_application(
    name = "my_app_ios",
    deps = [":app_lib", "@isomer//:isomer"],
    ...
)
```

## Driving it from a test

A test holds a hub of its own and starts the app through a launcher, which
passes the hub's URL as ISO_DRIVER (docs/drive.md, "Tests"):

```swift
let app = try HeadlessApp(launcher: launcher, environment: ["MYAPP_FIXTURE": "chat"])
try app.tap("New Issue")
try app.picture("chat")   // the proof's picture, from the launcher
```

The launchers are `@isomer//drive/launchers` (iOS's on a booted simulator,
the Mac's, Android's, the web's in Chrome, Linux's under Xvfb). The same test
source runs headless on Linux on every pull request and headful against the
`--config=drive` build for the proof (examples' headless/storybook_headless_application
does both).

## In CI

Release and alpha builds never take `--config=drive`. The proof's apps and
the headful tests' do: built in Shireworks' Linux containers, run on GitHub's
runners in a public repository or on Shireworks' primary VM slots in a private
one (docs/CI_POLICY.md in the private AttilaTheFun/reviews).
