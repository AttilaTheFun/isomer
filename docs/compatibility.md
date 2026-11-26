# What Isomer asks of a consumer's module graph

Every Bazel module isomer and its platform modules ask for, at what version,
and why. Bazel's Minimal Version Selection gives the whole build the highest
version any module asks for, so a consumer that pins an older version of one
of these (with a `single_version_override`) holds isomer below what it was
built and tested with. The versions here are the ones isomer is tested at;
lower ones aren't. A consumer that must stay lower on one of them can say
which and why: where a floor can come down, it will.

isomer is the core every app takes; isomer_android, isomer_android_maven and
isomer_apple are taken only by the apps that build those platforms
(docs/platform_modules.md). The tables are the 0.59 releases'.

## isomer

| Module | Version | Why | Lower? |
| --- | --- | --- | --- |
| rules_swift | 4.3.0.isomer.2 | Swift everywhere: upstream 4.3.0 and the pull requests isomer needs until a release has them, from the project's registry (MODULE.bazel lists them) | no: the patches are the reason |
| rules_swift_package_manager | 1.26.0 | Isomer's Swift package in the app's SwiftPM graph: 1.26.0 is the first release with #2639 (no Apple minimum OS versions off Apple), #2640 (cSettings' defines reach the Clang importer) and #2621 (Windows hosts) | no |
| apple_support | 2.9.1 | rules_swift's own floor; declared before rules_cc so its C toolchain ranks above rules_cc's on a Mac | rules_swift's |
| rules_cc | 0.2.18 | C in swift_ffi and the hosts' libraries | untested |
| protobuf | 27.0 | the wire protos (shared/wire); rules_swift asks for 34, which MVS gives | rules_swift's |
| swift_argument_parser | 1.7.0 | swift_ffi's bridge generator and analyzer | untested |
| wabt | 1.0.37 | mixed mode's wasm2c and wat2wasm, built from source | untested |
| rules_shell | 0.8.0 | the web's server and checks | untested |
| bazel_skylib, platforms | 1.9.0, 1.1.0 | every rule file | untested |

What these bring with them:

- **rules_swift 4.3.0 asks for bazel_features 1.54.0.** A root's override
  below it fails as `@rules_swift//swift` loads ("'struct' value has no field
  or method 'label_build_setting_has_scope'"): raise it, or drop it.
- **rules_swift_package_manager brings rules_go and gazelle**, and its
  `go_deps` use is not dev-only in 1.26.0: its go.mod joins the graph's
  `go_deps` resolution, which can ask a root that pins an older Go or gazelle
  for newer ones. (A fix is proposed upstream.)

## isomer_android

| Module | Version | Why |
| --- | --- | --- |
| rules_android | 0.7.3 | `android_binary` and the rest of Isomer's Android macros, whose APKs are tested with it. With 0.6.0 held at the root, CI's SDK smoke test builds the JNI library and a WASI command, not the APKs: 0.6 is not yet a floor |
| rules_kotlin | 2.2.2 | the Kotlin runtime and the activities Isomer's macros make; Isomer's Compose compiler plugin (2.2.21) matches its kotlinc |
| rules_java | 9.3.0 | rules_android's Java actions, with its `toolchains` extension |
| hermetic_android_toolchains | 0.5.0.isomer.3 | the NDK's C toolchains the Android Swift toolchain links through; .isomer.2's @androidsdk loads beside rules_android 0.6 as well as 0.7 (0.5.0's didn't), and runs on Linux hosts of any CPU; .isomer.3's fetches the SDK (142 MB) only for an Android target |

- **rules_android's tools take the root's protobuf-java**
  (`@com_google_protobuf//:protobuf_java`). A root on an older protobuf (27.x)
  has one without `GeneratedMessageV3`, which the tools' prebuilt aapt2-proto
  classes need, and ResourceProcessorBusyBox fails. Until rules_android takes
  them from Maven, such a root patches the three dependencies in
  `src/tools/java/com/google/devtools/build/android/BUILD` to
  `@rules_android_maven//:com_google_protobuf_protobuf_java`, or moves its
  protobuf up.

## isomer_android_maven

Only for an app that uses Isomer's AndroidX, not its own (docs/android_maven.md).

| Module | Version | Why |
| --- | --- | --- |
| rules_jvm_external | 7.1 | Isomer's AndroidX set, pinned by its lock file |
| rules_android | 0.7.3 | its `aar_import` |

## isomer_apple

Only for an app whose iPhone and Mac apps come from `isomer_application`.

| Module | Version | Why |
| --- | --- | --- |
| rules_apple | 5.3.1.applecross.7 | the iPhone's and the Mac's apps, built on a Mac or on Linux (rules_applecross's patches) |
| rules_applecross | 0.0.3.1f03f48 | Apple's SDKs and tools on Linux |
| apple_support | 2.11.0 | rules_applecross's |

## Pinning: the registry and the release tags

**The registry by commit.** isomer and its platform modules come from the
project's registry (AttilaTheFun/bazel_registry), which a consumer lists
before the BCR. A version's entry doesn't change once added (a fork's
change is a new entry, `.isomer.N+1`), but a registry read at
`main` follows whatever is added next. A consumer that wants its build to
read the same registry each time pins it by commit:

```
common --registry=https://raw.githubusercontent.com/AttilaTheFun/bazel_registry/<commit>
common --registry=https://bcr.bazel.build
```

and moves the commit forward when it takes a new isomer.

**A release tag's own `MODULE.bazel` says MAJOR.MINOR.0.** A release is
tagged vX.Y.N, but its `MODULE.bazel` files (the root, `android/module`,
`android/maven_module`, `apple/module`) commit X.Y.0: CI stamps each build's
version, and the registry's entry is the tag with one patch setting
`module()` to X.Y.N (its tools/add_version.py `--stamped`). A consumer that
takes isomer from the registry gets X.Y.N. One that takes the tag through a
`git_override` (a fork of its own, say) gets X.Y.0 unless its override
patches the versions too, as the registry's entry does: a `patches` of its
own setting each module's `version` to the tag's.

## Swift packages

Swift dependencies are SwiftPM's, through rules_swift_package_manager, never
Bazel modules of their own. Isomer's package depends on swift-protobuf
(1.38.1 or later: Isomer's SwiftUI reads the render tree with it) and
swift-collections. An app that uses SwiftProtobuf itself takes the same one,
`@swiftpkg_swift_protobuf//:SwiftProtobuf` from its graph, rather than a
module of its own: two would link two SwiftProtobufs into one app. With
`--@isomer//:library_evolution` that SwiftProtobuf is built resilient too
(docs/library_evolution.md), for generated modules built with library
evolution. An app whose SwiftProtobuf is a module of its own that several of
its binaries share points `--@isomer//:swift_protobuf` at it instead, and
Isomer links that one (BUILD.bazel).

One SwiftProtobuf across several root modules (an app built from two
Bazel roots that share libraries) is the case the package route doesn't
cover: each root's rules_swift_package_manager graph is its own, so each
would build its own copy. There, give swift-protobuf one Bazel module that
both roots depend on (its archive with a `MODULE.bazel` and a
`BUILD.bazel` added, built with library evolution if the roots' modules
are), and point `--@isomer//:swift_protobuf` at its library in each root.
Keep it at 1.38.1 or later, Isomer's floor.
