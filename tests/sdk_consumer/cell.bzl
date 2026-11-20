"""The cell's Android API level, SDK variant and rules_android
(tools/ci/sdk_smoke writes this beside cell.MODULE.bazel; as committed, the
release consumers have)."""

# kt_swift_library, from where the cell's isomer has it.
load("@isomer//swift_ffi/rules:kt_swift_library.bzl", _kt_swift_library = "kt_swift_library")

MIN_SDK_VERSION = 23
I18N = True
RULES_ANDROID = "0.6.0"
kt_swift_library = _kt_swift_library
