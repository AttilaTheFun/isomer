"""`kt_swift_library`: Kotlin (Android) consuming a bridged Swift module
through JNI: `kt_jvm_library > kt_swift_library > swift_library` (the
annotated library, whose SwiftFFI macro expansions carry the whole C ABI)."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_kotlin//kotlin:jvm.bzl", "kt_jvm_library")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load(":shared_platform.bzl", "swift_shared_library", "swift_shared_platform")
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
        link_deps = [],
        shared_platform = None,
        shared_platform_when = None,
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

    `link_deps` are linked into the `.so` beside `swift`. `shared_platform`
    (a `kt_swift_platform`) links it against that shared library instead
    of its own copy of what the platform holds (the Swift runtime, the
    standard library, the libraries in common); the Kotlin object loads
    the platform first. Without one the `.so` is whole, as before.
    With `shared_platform_when` (a config_setting) too, both links are
    declared and the setting picks one: the same sources either way.
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
    # Shipped (--//swift_ffi/rules:jni_exports_only): the JNI entry points
    # alone exported, the rest local, so --gc-sections drops what they
    # don't reach, and the symbol tables stripped.
    jni_linkopts = linkopts + select({
            Label("//swift_ffi/rules:jni_exports_only_on"): [
                "-Wl,--version-script=$(location %s)" % Label("//swift_ffi/rules:jni_exports.lds"),
                # The script names JNI_OnLoad, which a library may not have.
                "-Wl,--undefined-version",
                "-Wl,--gc-sections",
                "-Wl,--strip-all",
            ],
            "//conditions:default": [],
        })
    if shared_platform:
        swift_shared_library(
            name = name + "_shared_native",
            deps = [swift, ":" + name + "_adapter"] + link_deps,
            platform = _platform_link(shared_platform),
            additional_linker_inputs = [Label("//swift_ffi/rules:jni_exports.lds")],
            linkopts = jni_linkopts,
            tags = ["manual"],
        )
    if not shared_platform or shared_platform_when:
        swift_binary(
            name = name + "_native",
            srcs = [REACTOR_STUB],
            module_name = name + "_native",
            deps = [swift, ":" + name + "_adapter"] + link_deps,
            additional_linker_inputs = [Label("//swift_ffi/rules:jni_exports.lds")],
            linkopts = jni_linkopts,
            linkshared = True,
            tags = ["manual"],
        )
    whole = ":" + name + "_native"
    shared = ":" + name + "_shared_native"
    transition_binary(
        name = "lib" + name + ".so",
        binary = _pick(shared_platform, shared_platform_when, shared, whole),
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
        preload_libraries = _pick(
            shared_platform,
            shared_platform_when,
            [_platform_name(shared_platform)] if shared_platform else [],
            [],
        ),
    )

    kt_jvm_library(
        name = name,
        srcs = [":" + name + "_gen_kt"],
        visibility = visibility,
        deps = [_RUNTIME_KOTLIN] + deps,
        **kwargs
    )

def _pick(shared_platform, when, shared, whole):
    """`shared` with a platform, `whole` without; chosen by `when` if given."""
    if not shared_platform:
        return whole
    if not when:
        return shared
    return select({when: shared, "//conditions:default": whole})

def _platform_label(platform):
    return native.package_relative_label(platform)

def _platform_link(platform):
    label = _platform_label(platform)
    return label.same_package_label(label.name + "_link")

def _platform_name(platform):
    return _platform_label(platform).name

def kt_swift_platform(
        name,
        deps,
        linkopts = [],
        platform = Label("//swift_ffi/rules:android-aarch64"),
        visibility = None):
    """A shared platform library (`:lib<name>.so`) for `kt_swift_library`'s
    `shared_platform`: `deps` and the Swift runtime and standard library
    linked once, every symbol exported, for the JNI libraries that link
    against it. The app ships it beside them; their Kotlin objects load it
    first (`swiftffi.NativeLibraries.load("<name>")`).
    """
    swift_shared_platform(
        name = name + "_link",
        deps = deps,
        # Named as the app ships it, so the libraries linked against it
        # need it by that name (DT_NEEDED), not by its path in the build.
        # Shipped (--//swift_ffi/rules:jni_exports_only), stripped as the
        # JNI libraries are: the dynamic symbol table, what they link
        # against, stays.
        linkopts = ["-Wl,-soname,lib%s.so" % name] + linkopts + select({
            Label("//swift_ffi/rules:jni_exports_only_on"): ["-Wl,--strip-all"],
            "//conditions:default": [],
        }),
        tags = ["manual"],
        visibility = visibility,
    )
    transition_binary(
        name = "lib" + name + ".so",
        binary = ":" + name + "_link",
        platform = platform,
        tags = ["manual"],
        visibility = visibility,
    )
