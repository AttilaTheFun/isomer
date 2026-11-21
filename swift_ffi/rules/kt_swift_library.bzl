"""kt_swift_library is the isomer_android module's since 0.59
(@isomer_android//swift_ffi:kt_swift_library.bzl): it loads rules_kotlin,
which isomer asks for no longer (docs/platform_modules.md). These say so."""

def _moved(name):
    fail(("%s is the isomer_android module's since 0.59: add bazel_dep(name = \"isomer_android\", " +
          "version = <isomer's>) and load it from @isomer_android//swift_ffi:kt_swift_library.bzl (docs/platform_modules.md)") % name)

def kt_swift_library(**_kwargs):
    _moved("kt_swift_library")

def kt_swift_platform(**_kwargs):
    _moved("kt_swift_platform")

def swift_platform_library(**_kwargs):
    _moved("swift_platform_library")
