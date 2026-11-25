"""`kt_swift_library`: Kotlin (Android) consuming a bridged Swift module
through JNI: `kt_jvm_library > kt_swift_library > swift_library` (the
annotated library, whose SwiftFFI macro expansions carry the whole C ABI)."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_kotlin//kotlin:jvm.bzl", "kt_jvm_library")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load("@isomer//swift_ffi/rules:shared_platform.bzl", "swift_shared_library", "swift_shared_platform")
load("@isomer//swift_ffi/rules:utils.bzl", "REACTOR_STUB", "ffi_generate", "transition_binary")

_SWIFT_ABI = Label("@isomer//swift_ffi/runtime/swift_abi")
_RUNTIME_KOTLIN = Label("//swift_ffi:kotlin")

# The C++ runtime (libcxx.bzl): a library's `libcxx`, or without one
# --//swift_ffi/rules:libcxx. Shared: the NDK toolchain's static libc++ left
# out of the link (its `static_link_cpp_runtimes` feature off) and the NDK's
# libc++_shared.so named first among the link flags, ahead of the
# toolchain's own (rules_swift's `-lc++` for C++ interoperability, which it
# resolves to the static pair): lld takes each libc++ symbol from it, the
# library needs it, and none of libc++ is linked in. Static: as the
# toolchain links, libc++ inside.
_LIBCXX_SHARED = Label("@isomer//swift_ffi/rules:libcxx_shared")
_NDK_LIBCXX_SHARED = Label("@isomer//swift_ffi/rules:ndk_libcxx_shared")

def _libcxx(libcxx, shared, static):
    """`shared` or `static`, as `libcxx` says, or the flag without it."""
    if libcxx == None:
        return select({
            _LIBCXX_SHARED: shared,
            "//conditions:default": static,
        })
    if libcxx not in ("shared", "static"):
        fail("libcxx is \"shared\" or \"static\" (or None, for --@isomer//swift_ffi/rules:libcxx), not %r" % libcxx)
    return shared if libcxx == "shared" else static

def _libcxx_features(libcxx):
    return _libcxx(libcxx, ["-static_link_cpp_runtimes"], [])

def _libcxx_inputs(libcxx):
    return _libcxx(libcxx, [_NDK_LIBCXX_SHARED], [])

def _libcxx_linkopts(libcxx):
    return _libcxx(libcxx, ["$(location %s)" % _NDK_LIBCXX_SHARED], [])

def kt_swift_library(
        name,
        swift,
        java_package,
        deps = [],
        java_class = None,
        module_name = None,
        linkopts = [],
        link_deps = [],
        bound_libraries = [],
        shared_platform = None,
        shared_platform_when = None,
        platform = Label("@isomer//swift_ffi/rules:android-aarch64"),
        libcxx = None,
        visibility = None,
        testonly = False,
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
    consumer's to choose. `testonly` applies to every target it makes.

    `link_deps` are linked into the `.so` beside `swift`. `bound_libraries`
    are annotated Swift libraries bound in the same `.so`: each linked in,
    with a JNI adapter and a Kotlin facade of its own (`<Module>Bridge`, in
    `java_package`) that loads this library rather than one of its own, so
    a module an app's library uses (WasmView's engine, `WasmEngine`) adds no
    second Swift runtime to the process. `shared_platform`
    (a `kt_swift_platform`) links it against that shared library instead
    of its own copy of what the platform holds (the Swift runtime, the
    standard library, the libraries in common); the Kotlin object loads
    the platform first. Without one the `.so` is whole, as before.
    With `shared_platform_when` (a config_setting) too, both links are
    declared and the setting picks one: the same sources either way.

    `libcxx` is the C++ runtime: `"static"`, libc++ linked in, or
    `"shared"`, the NDK's `libc++_shared.so` needed, which the APK then
    ships (`//swift_ffi/rules:cxx_runtime_shared` among the android_binary's
    deps beside the library's). Without one, `--//swift_ffi/rules:libcxx`
    says (`static` by default; `//swift_ffi/rules:cxx_runtime` follows it).
    """
    ffi_generate(
        name = name + "_header_src",
        testonly = testonly,
        dep = swift,
        platform = platform,
        kind = "c-header",
        output_name = name + "_bridge.h",
        module_name = module_name,
    )
    ffi_generate(
        name = name + "_adapter_src",
        testonly = testonly,
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
        testonly = testonly,
        srcs = [
            ":" + name + "_adapter_src",
            ":" + name + "_header_src",
        ],
        deps = [_SWIFT_ABI],
        # The Java_* symbols live in this archive; keep them in the .so.
        alwayslink = True,
        tags = ["manual"],
    )

    # Each bound library's header, adapter and facade, as `swift`'s above:
    # its adapter's helpers are static and its Java_* names its own class's,
    # so the adapters link side by side.
    bound_adapters = []
    bound_kotlin = []
    for index, bound in enumerate(bound_libraries):
        prefix = "%s_bound%d" % (name, index)
        ffi_generate(
            name = prefix + "_header_src",
            testonly = testonly,
            dep = bound,
            platform = platform,
            kind = "c-header",
            output_name = prefix + "_bridge.h",
        )
        ffi_generate(
            name = prefix + "_adapter_src",
            testonly = testonly,
            dep = bound,
            platform = platform,
            kind = "jni-adapter",
            output_name = prefix + "_adapter.c",
            java_package = java_package,
            header_name = prefix + "_bridge.h",
        )
        cc_library(
            name = prefix + "_adapter",
            testonly = testonly,
            srcs = [
                ":" + prefix + "_adapter_src",
                ":" + prefix + "_header_src",
            ],
            deps = [_SWIFT_ABI],
            alwayslink = True,
            tags = ["manual"],
        )
        ffi_generate(
            name = prefix + "_gen_kt",
            testonly = testonly,
            dep = bound,
            platform = platform,
            kind = "kotlin",
            output_name = prefix + ".kt",
            java_package = java_package,
            library_name = name,
            preload_libraries = _pick(
                shared_platform,
                shared_platform_when,
                [_platform_name(shared_platform)] if shared_platform else [],
                [],
            ),
        )
        bound_adapters += [bound, ":" + prefix + "_adapter"]
        bound_kotlin.append(":" + prefix + "_gen_kt")

    # `swift_binary(linkshared = True)` named `<name>` produces `lib<name>.so`,
    # which is exactly what `System.loadLibrary("<name>")` looks up.
    # (Swift Concurrency's dispatch libraries are linked by the rules_swift
    # Android toolchain itself since bazelbuild/rules_swift#1830.)
    # The JNI entry points alone exported, the rest local: what the library
    # links statically (the Swift runtime, Foundation, and libc++ unless
    # `libcxx` is shared) is its own, never another library's in the
    # process (a host app's libc++_shared.so among them). Shipped
    # (--//swift_ffi/rules:jni_exports_only) too:
    # --gc-sections drops what the entry points don't reach, and the symbol
    # tables are stripped.
    jni_linkopts = _libcxx_linkopts(libcxx) + linkopts + [
        "-Wl,--version-script=$(location %s)" % Label("@isomer//swift_ffi/rules:jni_exports.lds"),
        # The script names JNI_OnLoad, which a library may not have.
        "-Wl,--undefined-version",
    ] + select({
        Label("@isomer//swift_ffi/rules:jni_exports_only_on"): [
            "-Wl,--gc-sections",
            "-Wl,--strip-all",
        ],
        "//conditions:default": [],
    })
    if shared_platform:
        swift_shared_library(
            name = name + "_shared_native",
            testonly = testonly,
            deps = [swift, ":" + name + "_adapter"] + bound_adapters + link_deps,
            platform = _platform_link(shared_platform),
            additional_linker_inputs = [Label("@isomer//swift_ffi/rules:jni_exports.lds")] + _libcxx_inputs(libcxx),
            features = _libcxx_features(libcxx),
            linkopts = jni_linkopts,
            tags = ["manual"],
        )
    if not shared_platform or shared_platform_when:
        swift_binary(
            name = name + "_native",
            testonly = testonly,
            srcs = [REACTOR_STUB],
            module_name = name + "_native",
            deps = [swift, ":" + name + "_adapter"] + bound_adapters + link_deps,
            additional_linker_inputs = [Label("@isomer//swift_ffi/rules:jni_exports.lds")] + _libcxx_inputs(libcxx),
            features = _libcxx_features(libcxx),
            linkopts = jni_linkopts,
            linkshared = True,
            tags = ["manual"],
        )
    whole = ":" + name + "_native"
    shared = ":" + name + "_shared_native"
    transition_binary(
        name = "lib" + name + ".so",
        testonly = testonly,
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
        testonly = testonly,
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
        testonly = testonly,
        srcs = [":" + name + "_gen_kt"] + bound_kotlin,
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
        platform = Label("@isomer//swift_ffi/rules:android-aarch64"),
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
        # Its libc++ (linked statically, as in every JNI library) stays its
        # own: exported, it would meet a host app's libc++_shared.so. With
        # --//swift_ffi/rules:libcxx=shared it links that libc++_shared.so
        # instead, as the JNI libraries do.
        linkopts = _libcxx_linkopts(None) + [
            "-Wl,-soname,lib%s.so" % name,
            "-Wl,--exclude-libs,libc++_static.a:libc++abi.a",
        ] + linkopts + select({
            Label("@isomer//swift_ffi/rules:jni_exports_only_on"): ["-Wl,--strip-all"],
            "//conditions:default": [],
        }),
        additional_linker_inputs = _libcxx_inputs(None),
        features = _libcxx_features(None),
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

def swift_platform_library(
        name,
        deps,
        shared_platform,
        linkopts = [],
        platform = Label("@isomer//swift_ffi/rules:android-aarch64"),
        testonly = False,
        visibility = None):
    """A shared library (`:lib<name>.so`) of Swift libraries linked against
    a `kt_swift_platform`, as a `kt_swift_library`'s JNI library is, but
    exporting what it links from `deps` (each an alwayslink `swift_library`,
    or nothing of it is linked: nothing in the library refers to it) rather
    than JNI entry points: a library that other libraries link against
    beside the platform, built once and shipped as a file (a prebuilt
    library; Isomer's README, "Prebuilt Swift libraries").

    It needs the platform by name (DT_NEEDED `lib<platform>.so`) and holds
    none of what the platform holds; `-z defs` fails its link on a symbol
    neither defines. Named `lib<name>.so` (its soname), as the app ships it.
    """
    swift_shared_library(
        name = name + "_link",
        testonly = testonly,
        deps = deps,
        platform = _platform_link(shared_platform),
        exported = True,
        # libc++ as the platform takes it (the flag decides).
        linkopts = _libcxx_linkopts(None) + ["-Wl,-soname,lib%s.so" % name] + linkopts + select({
            Label("@isomer//swift_ffi/rules:jni_exports_only_on"): ["-Wl,--strip-all"],
            "//conditions:default": [],
        }),
        additional_linker_inputs = _libcxx_inputs(None),
        features = _libcxx_features(None),
        tags = ["manual"],
    )
    transition_binary(
        name = "lib" + name + ".so",
        testonly = testonly,
        binary = ":" + name + "_link",
        platform = platform,
        tags = ["manual"],
        visibility = visibility,
    )
