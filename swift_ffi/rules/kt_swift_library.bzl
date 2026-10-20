"""`kt_swift_library`: Kotlin (Android) consuming a bridged Swift module
through JNI: `kt_jvm_library > kt_swift_library > swift_library` (the
annotated library, whose SwiftFFI macro expansions carry the whole C ABI)."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_kotlin//kotlin:jvm.bzl", "kt_jvm_library")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load(":utils.bzl", "REACTOR_STUB", "ffi_generate", "transition_binary")

_SWIFT_ABI = Label("//swift_ffi/runtime/swift_abi")
_RUNTIME_KOTLIN = Label("//swift_ffi/runtime/kotlin")

def kt_swift_library(
        name,
        swift,
        java_package,
        deps = [],
        java_class = None,
        module_name = None,
        linkopts = [],
        platform = Label("//swift_ffi/rules:android-aarch64"),
        visibility = None,
        **kwargs):
    """Android bridge: a JNI shared library (`:lib<name>.so`) + a real
    `kt_jvm_library` named `:<name>` compiling the generated Kotlin bindings
    (pure JVM — no Android APIs — so it serves kt_android_library and
    android_binary consumers alike). The Kotlin object calls
    `System.loadLibrary("<name>")`.

    The `.so` layers the annotated library's macro-expanded C ABI under a
    generated C JNI adapter mapping `Java_*` symbols onto it — Kotlin calls
    Swift through the C ABI like every other language.

    `swift` is the annotated library (linked into the .so and feeding the
    generators); `deps`/`**kwargs` pass through to the kt_jvm_library (the
    shared `swiftffi` runtime is added automatically). `module_name` defaults
    to `swift`'s own Swift module name; `java_class` (the Kotlin facade
    object) defaults to `<Module>Bridge`. Only `java_package` is the
    consumer's to choose.
    """
    ffi_generate(
        name = name + "_header_src",
        dep = swift,
        platform = platform,
        kind = "c-header",
        output_name = name + "_bridge.h",
        module_name = module_name,
    )
    ffi_generate(
        name = name + "_adapter_src",
        dep = swift,
        platform = platform,
        kind = "jni-adapter",
        output_name = name + "_adapter.c",
        module_name = module_name,
        java_package = java_package,
        java_class = java_class,
        header_name = name + "_bridge.h",
    )
    cc_library(
        name = name + "_adapter",
        srcs = [
            ":" + name + "_adapter_src",
            ":" + name + "_header_src",
        ],
        deps = [_SWIFT_ABI],
        # The Java_* symbols live in this archive; keep them in the .so.
        alwayslink = True,
        tags = ["manual"],
    )

    # `swift_binary(linkshared = True)` named `<name>` produces `lib<name>.so`,
    # which is exactly what `System.loadLibrary("<name>")` looks up.
    # (Swift Concurrency's dispatch libraries are linked by the rules_swift
    # Android toolchain itself since bazelbuild/rules_swift#1830.)
    swift_binary(
        name = name + "_native",
        srcs = [REACTOR_STUB],
        module_name = name + "_native",
        deps = [swift, ":" + name + "_adapter"],
        linkopts = linkopts,
        linkshared = True,
        tags = ["manual"],
    )
    transition_binary(
        name = "lib" + name + ".so",
        binary = ":" + name + "_native",
        platform = platform,
        tags = ["manual"],
        visibility = visibility,
    )

    # The generated bindings source (a declared output, like any codegen);
    # the file is named after the target (Kotlin does not require file names
    # to match declarations) and the facade object inside is `java_class`.
    ffi_generate(
        name = name + "_gen_kt",
        dep = swift,
        platform = platform,
        kind = "kotlin",
        output_name = name + ".kt",
        module_name = module_name,
        java_package = java_package,
        java_class = java_class,
        library_name = name,
    )

    kt_jvm_library(
        name = name,
        srcs = [":" + name + "_gen_kt"],
        visibility = visibility,
        deps = [_RUNTIME_KOTLIN] + deps,
        **kwargs
    )
