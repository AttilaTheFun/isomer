# Isomer's Maven dependencies on Android

Isomer's Android runtime (`dev.isomer.runtime`, the activities its app
macros make) is Kotlin over Jetpack Compose and AndroidX. Those artifacts come
from **isomer's own Maven repository, `@isomer_maven`**, pinned by isomer's lock
file (`isomer_maven_install.json`), behind a label flag an app can point at its
own instead.

## An app with no AndroidX of its own: nothing to do

An app on Isomer declares no Maven for Isomer and keeps no lock file for it.
rules_jvm_external honours a dependency's lock file for a repository the
dependency names, so isomer's pins `@isomer_maven` in the app's build too.

isomer also pins rules_android's own Maven graph (`@rules_android_maven`, its
tools: r8, bundletool, desugaring), which rules_android declares without a
lock file, with `rules_android_maven_install.json`. An app that declared
`rules_android_maven` itself only to repeat Isomer's artifacts can delete that
`maven.install` and its lock file.

## An app with AndroidX of its own: point the flags at it

An app whose Kotlin uses Compose, CameraX, or anything else of AndroidX's has
its own Maven repository. Two copies of AndroidX in one APK fail at dexing
(duplicate classes), so Isomer then uses the app's: the app makes a set of
its own exporting what Isomer's set exports, and points the flag at it.

```python
# third_party/BUILD.bazel
load("@rules_android//rules:rules.bzl", "android_library")

android_library(
    name = "androidx_for_isomer",
    exports = [
        "@maven//:androidx_activity_activity_compose",
        "@maven//:androidx_browser_browser",
        "@maven//:androidx_compose_foundation_foundation",
        "@maven//:androidx_compose_material3_material3",
        "@maven//:androidx_compose_runtime_runtime",
        "@maven//:androidx_compose_ui_ui",
        "@maven//:androidx_fragment_fragment",
        "@maven//:androidx_lifecycle_lifecycle_common",
        "@maven//:androidx_profileinstaller_profileinstaller",
        "@maven//:org_jetbrains_kotlinx_kotlinx_coroutines_android",
        "@maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core",
    ],
    visibility = ["//visibility:public"],
)
```

```
# .bazelrc
build --@isomer//android/maven:androidx=//third_party:androidx_for_isomer
```

`@isomer_maven` is then never referenced, so it is never fetched. The app's
versions must be at least Isomer's (MODULE.bazel's `isomer_maven` list:
Compose 1.7, activity-compose 1.9, material3 1.3).

The app's own Kotlin depends on the same set (`@isomer//android/maven:androidx`
when it uses Isomer's, its own otherwise), never on single artifacts of
another repository.

### Why one flag for the whole set

Artifacts of one Maven repository depend on each other: Isomer's
`foundation` brings Isomer's `androidx.core`. A set mixed from two
repositories would carry two copies of what they share, so the set is
replaced whole. (rules_jvm_external's `maven.override` redirects one
coordinate, but what that coordinate depends on still comes from its own
repository: the same problem.)

## The Compose compiler

The Compose compiler plugin must match the app's kotlinc, which its
rules_kotlin fixes. Isomer's matches rules_kotlin 2.2.2 (kotlinc 2.2.21); an
app on another release gives its own:

```
build --@isomer//android/maven:compose_compiler=@maven//:org_jetbrains_kotlin_kotlin_compose_compiler_plugin_embeddable
```

## In this repository

- `MODULE.bazel`: `isomer_maven` (Isomer's set) and `rules_android_maven`
  (rules_android's), with their lock files at the root. Repin with
  `REPIN=1 bazel run @isomer_maven//:pin` (and `@rules_android_maven//:pin`).
- `android/maven/BUILD.bazel`: the two flags and Isomer's set.
- `examples/MODULE.bazel`: the examples consume isomer as an app does; their
  own repository, `examples_maven`, holds only the Android benchmark's harness
  and its tests (the benchmark's instrumentation APK, not an app's).
