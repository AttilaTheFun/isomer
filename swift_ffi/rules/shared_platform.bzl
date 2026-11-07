"""A shared platform library for Android JNI libraries: the Swift runtime, the
standard library and the Swift libraries several JNI libraries have in
common, linked once into `lib<name>.so`, which each of them links against
(`kt_swift_library(platform = ...)`) instead of linking its own copy.

The Swift Android toolchain links every shared object with
`-Wl,--exclude-libs,ALL` (its symbols from archives local, which a version
script can't undo), so a `swift_binary` can't export a runtime for another
library to use. These rules link through `cc_common.link` over the same
CcInfo a `swift_binary` would, the platform without that flag (everything
exported), a library against it without the archives the platform holds.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

SwiftSharedPlatformInfo = provider(
    doc = "A shared platform library and what is linked into it.",
    fields = {
        "library": "File: the platform's lib<name>.so.",
        "archives": "depset of File: the static libraries linked into it, which a library linking against it leaves out.",
    },
)

# The Swift Android toolchain's flag that keeps archives' symbols local.
_EXCLUDE_LIBS = "-Wl,--exclude-libs,ALL"

def _archive(library):
    return library.pic_static_library or library.static_library

def _relinked(owner_inputs, keep_library, keep_flag):
    """The linker inputs, less the libraries and flags not kept."""
    inputs = []
    for linker_input in owner_inputs:
        libraries = [library for library in linker_input.libraries if keep_library(library)]
        flags = [flag for flag in linker_input.user_link_flags if keep_flag(flag)]
        if not libraries and not flags and not linker_input.additional_inputs and not linker_input.linkstamps:
            continue
        inputs.append(cc_common.create_linker_input(
            owner = linker_input.owner,
            libraries = depset(libraries),
            user_link_flags = flags,
            additional_inputs = depset(linker_input.additional_inputs),
            linkstamps = depset(linker_input.linkstamps),
        ))
    return inputs

def _link(ctx, linker_inputs, user_link_flags, additional_inputs = []):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    user_link_flags = [
        ctx.expand_location(flag, ctx.attr.additional_linker_inputs)
        for flag in user_link_flags
    ]
    outputs = cc_common.link(
        actions = ctx.actions,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        name = ctx.label.name,
        linking_contexts = [cc_common.create_linking_context(linker_inputs = depset(linker_inputs))],
        link_deps_statically = True,
        output_type = "dynamic_library",
        user_link_flags = user_link_flags,
        additional_inputs = ctx.files.additional_linker_inputs + additional_inputs,
    )
    return outputs.library_to_link.resolved_symlink_dynamic_library or outputs.library_to_link.dynamic_library

def _swift_shared_platform_impl(ctx):
    merged = cc_common.merge_cc_infos(cc_infos = [dep[CcInfo] for dep in ctx.attr.deps])
    linker_inputs = merged.linking_context.linker_inputs.to_list()
    library = _link(
        ctx,
        _relinked(linker_inputs, lambda _: True, lambda flag: flag != _EXCLUDE_LIBS),
        ctx.attr.linkopts,
    )
    archives = [
        _archive(library_to_link)
        for linker_input in linker_inputs
        for library_to_link in linker_input.libraries
        if _archive(library_to_link)
    ]
    return [
        DefaultInfo(files = depset([library])),
        SwiftSharedPlatformInfo(library = library, archives = depset(archives)),
    ]

swift_shared_platform = rule(
    implementation = _swift_shared_platform_impl,
    attrs = {
        "additional_linker_inputs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo], mandatory = True),
        "linkopts": attr.string_list(),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
    doc = "Links `deps` (the Swift runtime with them) into one shared library that exports every symbol.",
)

def _swift_shared_library_impl(ctx):
    platform = ctx.attr.platform[SwiftSharedPlatformInfo]
    in_platform = {archive: True for archive in platform.archives.to_list()}
    merged = cc_common.merge_cc_infos(cc_infos = [dep[CcInfo] for dep in ctx.attr.deps])
    linker_inputs = _relinked(
        merged.linking_context.linker_inputs.to_list(),
        lambda library: not (_archive(library) and _archive(library) in in_platform),
        lambda _: True,
    )

    # The platform first, ahead of the toolchain's runtime archives: lld
    # takes a symbol from the first library on the line that defines it, so
    # the runtime comes from the platform, not from a second copy.
    # `-z defs`: a symbol neither here nor exported by the platform fails
    # the link, not the library's load.
    library = _link(
        ctx,
        linker_inputs,
        [platform.library.path, "-Wl,-z,defs"] + ctx.attr.linkopts,
        additional_inputs = [platform.library],
    )
    return [DefaultInfo(files = depset([library]))]

swift_shared_library = rule(
    implementation = _swift_shared_library_impl,
    attrs = {
        "additional_linker_inputs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo], mandatory = True),
        "linkopts": attr.string_list(),
        "platform": attr.label(providers = [SwiftSharedPlatformInfo], mandatory = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
    doc = "Links `deps` into a shared library against `platform`, leaving out what the platform holds.",
)
