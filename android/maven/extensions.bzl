"""Where Isomer's AndroidX set is: the isomer_android_maven module's, when
the build has it (docs/android_maven.md).

isomer declares no Maven of its own for its consumers (a module extension
reads every module's tags, so every build on Isomer would evaluate it). The
isomer_android_maven module holds Isomer's set and tells this extension
where, with a `set` tag:

    android_maven = use_extension("@isomer//android/maven:extensions.bzl", "android_maven")
    android_maven.set(
        androidx = "//:androidx",
        compose_compiler = "//:compose_compiler",
    )

The extension makes @isomer_android_maven_set, whose `androidx` and
`compose_compiler` are //android/maven's flags' defaults: aliases of the
set's targets, or, with no module in the build to say where they are,
targets that fail when analyzed, saying to add the module or to point the
flags at the app's own. Only a build that leaves a flag at its default
loads them: an app that sets both never evaluates this extension.

isomer itself can't name the module's repository: it depends on the module
only for its own builds (a dev dependency, invisible to consumers), and a
consumer's dependency on it is the consumer's, not isomer's.
"""

_MISSING = """\
Isomer's AndroidX set is not in this build (@isomer//android/maven:{flag} is at its default).
Either:
  - depend on Isomer's set, the isomer_android_maven module, at isomer's version, in MODULE.bazel:
        bazel_dep(name = "isomer_android_maven", version = "<isomer's version>")
  - or point both of Isomer's flags at your own AndroidX (an app with AndroidX of its own), in .bazelrc:
        build --@isomer//android/maven:androidx=<your set, exporting what Isomer's does>
        build --@isomer//android/maven:compose_compiler=<the Compose compiler plugin for your kotlinc>
isomer's docs/android_maven.md has both.
"""

def _set_repository_impl(repository_ctx):
    if repository_ctx.attr.androidx:
        repository_ctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

# Isomer's AndroidX set, from {module}.
alias(
    name = "androidx",
    actual = "{androidx}",
)

alias(
    name = "compose_compiler",
    actual = "{compose_compiler}",
)
""".format(
            module = repository_ctx.attr.module,
            androidx = repository_ctx.attr.androidx,
            compose_compiler = repository_ctx.attr.compose_compiler,
        ))
        return

    # No module said where the set is: each target fails when analyzed (a
    # build that never uses it, Android's or not, never sees the message).
    repository_ctx.file("missing.bzl", """\
_MESSAGE = {message}

def _missing_impl(ctx):
    fail("\\n\\n" + _MESSAGE.format(flag = ctx.label.name))

missing = rule(
    implementation = _missing_impl,
    doc = "Fails when analyzed: Isomer's AndroidX set is not in this build.",
)
""".format(message = repr(_MISSING)))
    repository_ctx.file("BUILD.bazel", """\
load(":missing.bzl", "missing")

package(default_visibility = ["//visibility:public"])

missing(name = "androidx")

missing(name = "compose_compiler")
""")

_set_repository = repository_rule(
    implementation = _set_repository_impl,
    attrs = {
        # Canonical labels (`@@isomer_android_maven+//:androidx`): this
        # repository can't see the module by its name.
        "androidx": attr.string(),
        "compose_compiler": attr.string(),
        "module": attr.string(),
    },
)

_set = tag_class(
    doc = "Where Isomer's AndroidX set is (the isomer_android_maven module's tag).",
    attrs = {
        "androidx": attr.label(
            mandatory = True,
            doc = "The set: an android_library exporting Isomer's AndroidX artifacts.",
        ),
        "compose_compiler": attr.label(
            mandatory = True,
            doc = "The Compose compiler plugin, matching rules_kotlin's kotlinc.",
        ),
    },
)

def _android_maven_impl(module_ctx):
    # The first module that says, in Bazel's order (the root first): the
    # isomer_android_maven module, unless the root says otherwise.
    found = None
    for module in module_ctx.modules:
        if len(module.tags.set) > 1:
            fail("{}: one android_maven.set, not {}".format(module.name, len(module.tags.set)))
        if module.tags.set and not found:
            found = (module, module.tags.set[0])
    if found:
        module, tag = found
        _set_repository(
            name = "isomer_android_maven_set",
            androidx = str(tag.androidx),
            compose_compiler = str(tag.compose_compiler),
            module = "{}@{}".format(module.name, module.version),
        )
    else:
        _set_repository(name = "isomer_android_maven_set")
    return module_ctx.extension_metadata(reproducible = True)

android_maven = module_extension(
    implementation = _android_maven_impl,
    tag_classes = {"set": _set},
    doc = "Makes @isomer_android_maven_set, //android/maven's flags' defaults.",
)
