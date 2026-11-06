"""isomer's SwiftPM graph under an extension identity of its own.

rules_swift_package_manager's `swift_deps` takes one graph per extension, and
an application on Isomer usually has its own: so isomer resolves its graph
(swift-foundation, and what it needs) through this re-export, and an
application whose graph has a package of isomer's too (swift-collections,
swift-syntax) points isomer's repository at its own with `override_repo`
(README: "Consuming isomer").
"""

load("@rules_swift_package_manager//:extensions.bzl", _swift_deps = "swift_deps")

swift_deps = _swift_deps
