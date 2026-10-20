"""The examples' SwiftPM graph under an extension identity of its own.

A module that depends on another with a SwiftPM graph of its own cannot hand
rules_swift_package_manager's one `swift_deps` extension a second manifest,
so the examples resolve theirs through this re-export, and an application
in that position points the other module's package repositories at its graph
(`override_repo`): one SwiftProtobuf, one NIO.
"""

load("@rules_swift_package_manager//:extensions.bzl", _swift_deps = "swift_deps")

swift_deps = _swift_deps
