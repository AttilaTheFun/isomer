"""The Playground's SwiftPM graph under an extension identity of its own.

A module that depends on another with a SwiftPM graph of its own cannot hand
rules_swift_package_manager's one `swift_deps` extension a second manifest,
so the Playground resolves its graph (AgentUI, OpenRouterKit) through this
re-export, as isomer's examples do. The generated package repositories then
see this module's apparent repository names (rules_license, rules_swift).
"""

load("@rules_swift_package_manager//:extensions.bzl", _swift_deps = "swift_deps")

swift_deps = _swift_deps
