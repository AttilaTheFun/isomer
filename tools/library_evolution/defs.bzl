"""Isomer's modules built with library evolution, when the build asks.

`--@isomer//:library_evolution` (default false; docs/library_evolution.md)
adds `-enable-library-evolution` to every module of Isomer's that an
Android or web app links, so that an app's own library built resilient
(rules_swift's `library_evolution = True` or `swift.enable_library_evolution`)
can import them: Swift reports each public import of a module that isn't
resilient into one that is, "module 'SwiftUI' was not compiled with library
evolution support; using it means binary compatibility for 'X' can't be
guaranteed" (lib/Sema/ImportResolution.cpp). A warning in no diagnostic
group, which Swift 6.4's `-warnings-as-errors` leaves a warning; an error
in a library built for distribution (InternalImportsByDefault or
AccessLevelOnImport, at `-library-level api` or `spi`), which nothing
turns off. An `internal import` (or `@_implementationOnly`) of the module
avoids it otherwise, where the library's interface doesn't use the module.

Not the `swift.enable_library_evolution` feature: isomer's REPO.bazel turns
that off for its packages, and one_configuration drops it from the
package's modules' configuration (foundation/defs.bzl), so that a
consumer's `--features` never changes how Isomer is built; and it would
reach swift-foundation, its collections and SwiftProtobuf beneath Isomer's
package too, which an app doesn't import. Copts, for Isomer's modules only:

- isomer's own swift_library targets (the Isomer module, the hosts, os and
  OSLog, IsomerFFI, SwiftGPU, SwiftMap, Metal, ...) add
  `LIBRARY_EVOLUTION_COPTS` to their copts: a select on the flag, so the
  module is resilient in whatever configuration it is built;
- the modules of isomer's Swift package (Foundation, SwiftUI, Combine,
  CoreGraphics, PhotosUI, ...) are generated targets of
  rules_swift_package_manager's, whose copts nothing here writes. Every
  dependent reaches them through `one_configuration` (`@isomer//:foundation`,
  `@isomer//:swift_ui`, each platform's `libraries/swift_ui:core`), whose
  transition calls `package_library_evolution` below: with the flag on,
  rules_swift's per-module copts
  (`--@rules_swift//swift:per_module_swiftcopt=<label>=<copt>`, keyed by
  each target's canonical label) name the package's targets with
  `-enable-library-evolution`.

The module stays resilient through the copt alone: rules_swift doesn't
know of it, so no .swiftinterface is emitted (an app links Isomer from
source; nothing reads one).
"""

# The flag (the root BUILD.bazel) and the select on it.
_SETTING = str(Label("//:library_evolution"))
_PER_MODULE_SWIFTCOPT = str(Label("@rules_swift//swift:per_module_swiftcopt"))

LIBRARY_EVOLUTION_COPTS = select({
    Label("//:library_evolution_on"): ["-enable-library-evolution"],
    "//conditions:default": [],
})

# isomer's Swift package's Swift targets (Package.swift), every one an app
# may link (not the SwiftUIMacros plugin, the C target or the `iso` CLI).
# rules_swift_package_manager names a target's swift_library
# `<Target>.rspm.__impl` (`<Target>` is a group over it); rules_swift reads
# per-module copts by the compiling target's own label. A target added to
# the package goes here too, or it stays fragile under the flag (and an app
# importing it warns): tests/library_evolution in the examples imports the
# ones an app does.
_PACKAGE_TARGETS = [
    "Combine",
    "CoreGraphics",
    "CoreTransferable",
    "Foundation",
    "FoundationNetworking",
    "ImageIO",
    "Isomer",
    "IsomerDispatchTime",
    "IsomerDriver",
    "IsomerFoundation",
    "IsomerGRPCTransport",
    "IsomerProcessTransport",
    "IsomerRemote",
    "IsomerServing",
    "IsomerSwiftUI",
    "IsomerWebSocketTransport",
    "IsomerWire",
    "PhotosUI",
    "SwiftUI",
    "UniformTypeIdentifiers",
]

# `@swiftpkg_isomer` is visible to isomer (its MODULE.bazel's use_repo), and
# Label() turns it into the canonical name rules_swift compares with
# (`@@rules_swift_package_manager++swift_deps+swiftpkg_isomer//:...`).
_PACKAGE_COPTS = [
    "{}=-enable-library-evolution".format(Label("@swiftpkg_isomer//:{}.rspm.__impl".format(target)))
    for target in _PACKAGE_TARGETS
]

# For a transition that sets them: its inputs and outputs.
LIBRARY_EVOLUTION_INPUTS = [_SETTING, _PER_MODULE_SWIFTCOPT]
LIBRARY_EVOLUTION_OUTPUTS = [_PER_MODULE_SWIFTCOPT]

def package_library_evolution(settings):
    """The per-module copts the package's modules are built with.

    Args:
      settings: a transition's settings, `LIBRARY_EVOLUTION_INPUTS` among them.

    Returns:
      A dict for the transition's outputs: rules_swift's per-module copts as
      given, with the package's targets' `-enable-library-evolution` added
      when the flag is on. Added once: a dependent reached through two
      one_configuration wrappers (`@isomer//:foundation` inside
      `@isomer//:swift_ui`) is transitioned twice, and the second must give
      the configuration the first did, or the module is built twice and
      both linked.
    """
    copts = list(settings[_PER_MODULE_SWIFTCOPT])
    if settings[_SETTING]:
        for copt in _PACKAGE_COPTS:
            if copt not in copts:
                copts.append(copt)
    return {_PER_MODULE_SWIFTCOPT: copts}
