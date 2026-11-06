"""`@build_bazel_rules_swift`, rules_swift's old name, for the package
repositories rules_swift_package_manager generates from isomer's graph.

They load `@build_bazel_rules_swift//swift:swift.bzl`, and see the apparent
names of the module whose extension made them: isomer's, where rules_swift is
`@rules_swift`. A root module would `inject_repo` it; isomer is usually a
dependency, whose inject_repo is ignored, so this repository re-exports
rules_swift's rules under that name instead.
"""

_SWIFT_BZL = """\
load(
    "@rules_swift//swift:swift.bzl",
    _swift_binary = "swift_binary",
    _swift_compiler_plugin = "swift_compiler_plugin",
    _swift_import = "swift_import",
    _swift_interop_hint = "swift_interop_hint",
    _swift_library = "swift_library",
    _swift_library_group = "swift_library_group",
    _swift_test = "swift_test",
    _universal_swift_compiler_plugin = "universal_swift_compiler_plugin",
)

swift_binary = _swift_binary
swift_compiler_plugin = _swift_compiler_plugin
swift_import = _swift_import
swift_interop_hint = _swift_interop_hint
swift_library = _swift_library
swift_library_group = _swift_library_group
swift_test = _swift_test
universal_swift_compiler_plugin = _universal_swift_compiler_plugin
"""

def _rules_swift_alias_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", "")
    repository_ctx.file("swift/BUILD.bazel", "")
    repository_ctx.file("swift/swift.bzl", _SWIFT_BZL)

rules_swift_alias = repository_rule(
    implementation = _rules_swift_alias_impl,
    doc = "rules_swift's rules under rules_swift's old repository name.",
)
