# Isomer's Maven dependencies on Android

Isomer's Android runtime (`dev.isomer.runtime`, the activities its app
macros make) is Kotlin over Jetpack Compose and AndroidX. Which AndroidX it
compiles and links against is a pair of label flags,
`@isomer//android/maven:androidx` (the set) and
`@isomer//android/maven:compose_compiler` (the Compose compiler plugin).
By default they are Isomer's own set, from a module of its own,
**`isomer_android_maven`**; an app with AndroidX of its own points them at
its own instead.

isomer itself declares no Maven for its consumers (since 0.54). A module
extension reads every module's tags, so a `maven.install` in isomer was
evaluated in every build on Isomer, Android or not, by the build's own
rules_jvm_external: one older than isomer's couldn't read isomer's lock
files, or rejected attributes it didn't know, even in an app that had
pointed both flags at its own AndroidX.

## An app with no AndroidX of its own: depend on isomer_android_maven

Add Isomer's set beside isomer, at isomer's version (each isomer release
is in the project's registry with it):

```starlark
bazel_dep(name = "isomer", version = "0.54.1")
bazel_dep(name = "isomer_android_maven", version = "0.54.1")
```

That is all: the flags' defaults find the module's set, pinned by the
module's lock file (`isomer_maven_install.json`, which rules_jvm_external
honours for the repository the module names), so the app declares no Maven
for Isomer and keeps no lock file. The module asks for rules_jvm_external
7.1 and rules_android 0.7.3.

An app on a `git_override` of isomer overrides the module from the same
commit, its directory in isomer's tree:

```starlark
git_override(
    module_name = "isomer_android_maven",
    remote = "https://github.com/AttilaTheFun/isomer.git",
    commit = "<the same commit as isomer's>",
    strip_prefix = "android/maven_module",
)
```

## An app with AndroidX of its own: point the flags at it

An app whose Kotlin uses Compose, CameraX, or anything else of AndroidX's has
its own Maven repository. Two copies of AndroidX in one APK fail at dexing
(duplicate classes), so Isomer then uses the app's: the app makes a set of
its own exporting what Isomer's set exports, and points the flags at it.

```python
# third_party/BUILD.bazel
load("@rules_android//rules:rules.bzl", "android_library")

android_library(
    name = "androidx_for_isomer",
    exports = [
        "@maven//:androidx_activity_activity_compose",
        "@maven//:androidx_browser_browser",
        "@maven//:androidx_compose_foundation_foundation",
        "@maven//:androidx_compose_material_material_icons_core",
        "@maven//:androidx_compose_material3_material3",
        "@maven//:androidx_compose_runtime_runtime",
        "@maven//:androidx_compose_ui_ui",
        "@maven//:androidx_concurrent_concurrent_futures",
        "@maven//:androidx_fragment_fragment",
        "@maven//:androidx_lifecycle_lifecycle_common",
        "@maven//:androidx_profileinstaller_profileinstaller",
        "@maven//:com_google_guava_listenablefuture",
        "@maven//:org_jetbrains_kotlinx_kotlinx_coroutines_android",
        "@maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core",
    ],
    visibility = ["//visibility:public"],
)
```

```
# .bazelrc
build --@isomer//android/maven:androidx=//third_party:androidx_for_isomer
build --@isomer//android/maven:compose_compiler=@maven//:org_jetbrains_kotlin_kotlin_compose_compiler_plugin_embeddable
```

Such an app does not depend on `isomer_android_maven`, so nothing of
Isomer's Maven is in its build: its rules_jvm_external and rules_android may
be its own. The app's versions must be at least Isomer's
(android/maven_module/MODULE.bazel's list: Compose 1.7, activity-compose
1.9, material3 1.3).

concurrent-futures (`androidx.concurrent:concurrent-futures`, its
`AbstractResolvableFuture`) and Guava's `ListenableFuture`
(`com.google.guava:listenablefuture`, or the whole of `com.google.guava:guava`)
are ProfileInstaller's dependencies, not Isomer's, but the set must carry
them: ProfileInstaller's install task loads them a few seconds after launch,
and an app whose graph excludes them (an `exclusions` entry, a Guava left out
of a large app's graph) crashes then with `NoClassDefFoundError`. Isomer's set
exports both by name for that reason. So it does material-icons-core
(`androidx.compose.material:material-icons-core`, the runtime's
`Icons.Filled`), which Material 3 brought with it until 1.4: a set on a later
Material 3 lists it itself.

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

## Neither: the build says which to do

An app that builds anything of Isomer's for Android with neither the module
nor the flags fails where the default is analyzed:

```
Error in fail:

Isomer's AndroidX set is not in this build (@isomer//android/maven:androidx is at its default).
Either:
  - depend on Isomer's set, the isomer_android_maven module, at isomer's version, in MODULE.bazel:
        bazel_dep(name = "isomer_android_maven", version = "<isomer's version>")
  - or point both of Isomer's flags at your own AndroidX (an app with AndroidX of its own), in .bazelrc:
        build --@isomer//android/maven:androidx=<your set, exporting what Isomer's does>
        build --@isomer//android/maven:compose_compiler=<the Compose compiler plugin for your kotlinc>
isomer's docs/android_maven.md has both.
```

A build that doesn't use the defaults (no Android, or both flags set) never
sees it.

How the defaults find the module: isomer depends on `isomer_android_maven`
only as a development dependency (for its own builds), so isomer's
packages can't name the module's repository in a consumer's build. Instead
the module tells an extension of isomer's where its set is
(`android/maven/extensions.bzl`, the module's `android_maven.set` tag), and
the flags default to the repository that extension makes,
`@isomer_android_maven_set`: aliases of the module's targets when a module
said where they are, targets that fail as above when none did. A flag's
default is analyzed only when the flag is left at it, so an app that sets
both never evaluates the extension. (The module depends on isomer for that
extension; the two name each other, which Bazel's module resolution
allows.)

## The Compose compiler

The Compose compiler plugin must match the app's kotlinc, which its
rules_kotlin fixes. Isomer's matches rules_kotlin 2.2.2 (kotlinc 2.2.21); an
app on another release gives its own:

```
build --@isomer//android/maven:compose_compiler=@maven//:org_jetbrains_kotlin_kotlin_compose_compiler_plugin_embeddable
```

## rules_android's own Maven

rules_android declares its tools' Maven repository (`@rules_android_maven`:
r8, bundletool, desugaring) itself, without a lock file, so rules_jvm_external
resolves it afresh wherever it isn't pinned. isomer pins it for its own
builds only (`rules_android_maven_install.json`, a development dependency);
an app on rules_jvm_external 7 that wants it pinned declares it with that
lock file, as the examples do:

```starlark
maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "rules_android_maven",
    aar_import_bzl_label = "@rules_android//rules:rules.bzl",
    known_contributing_modules = ["rules_android"],
    lock_file = "@isomer//:rules_android_maven_install.json",
    repositories = [
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
    use_starlark_android_rules = True,
)
```

(or a lock file of its own, pinned with `REPIN=1 bazel run
@rules_android_maven//:pin`).

Two more repositories an Android build takes are unpinned in their
modules: rules_android's `android_ide_common_30_1_3` and bazel_worker_java's
`bazel_worker_maven` (the Android tools' persistent workers). An unpinned
repository is resolved by coursier, which asks Maven Central itself at every
fetch, past Bazel's downloader (its mirrors, `--downloader_config`) and its
repository cache, so a build fails whenever Central does (it has answered
404 for artifacts it has). isomer pins both with lock files of its own,
`android_ide_common_30_1_3_install.json` and
`bazel_worker_maven_install.json`, as the examples do and an app may:

```starlark
maven.install(
    name = "android_ide_common_30_1_3",
    aar_import_bzl_label = "@rules_android//rules:rules.bzl",
    known_contributing_modules = ["rules_android"],
    lock_file = "@isomer//:android_ide_common_30_1_3_install.json",
    repositories = [
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
    use_starlark_android_rules = True,
)
maven.install(
    name = "bazel_worker_maven",
    known_contributing_modules = ["bazel_worker_java"],
    lock_file = "@isomer//:bazel_worker_maven_install.json",
)
```

Repinned from isomer's root by their canonical names (isomer doesn't
import them): `REPIN=1 bazel run
@@rules_jvm_external++maven+android_ide_common_30_1_3//:pin` and
`@@rules_jvm_external++maven+bazel_worker_maven//:pin`.

## In this repository

- `android/maven_module/`: the `isomer_android_maven` module: `MODULE.bazel`
  (the `isomer_maven` repository's artifacts and the `android_maven.set`
  tag), `BUILD.bazel` (Isomer's set, `:androidx`, and `:compose_compiler`)
  and the lock file, `isomer_maven_install.json`. Its version is isomer's
  (MAJOR.MINOR.0 committed, as MODULE.bazel's: the two move together), and
  it asks for the same version of isomer; the project's registry adds it
  from each isomer release's tag (`strip_prefix` this directory), stamped
  to the release's version, its dependency on isomer too. `.bazelignore`
  keeps it out of isomer's own packages.
- `MODULE.bazel`: the module as a development dependency, from this
  checkout (`local_path_override`), and `rules_android_maven` pinned for
  isomer's own builds. Repin either from isomer's root:
  `REPIN=1 bazel run @isomer_maven//:pin` (rules_jvm_external writes the
  lock file at the checkout's root, `isomer_maven_install.json`: move it
  over the module's, `android/maven_module/isomer_maven_install.json`)
  and `REPIN=1 bazel run @rules_android_maven//:pin`.
- `android/maven/BUILD.bazel`: the two flags; `android/maven/extensions.bzl`:
  the extension their defaults come from.
- `examples/MODULE.bazel`: the examples consume isomer as an app does, the
  module included (`local_path_override` on `../android/maven_module`), and
  pin `rules_android_maven`, `android_ide_common_30_1_3` and
  `bazel_worker_maven` with isomer's lock files; their own repository,
  `examples_maven`, holds only the Android benchmark's harness and its
  tests (the benchmark's instrumentation APK, not an app's).
