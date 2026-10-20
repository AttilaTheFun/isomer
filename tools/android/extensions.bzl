"""Hermetic Android build tooling: JDK, Kotlin compiler, Android SDK pieces.

We deliberately avoid requiring ANDROID_HOME / a local Java install. The APK
is assembled with plain Bazel actions (aapt2 / kotlinc / d8 / apksigner), so
only the individual packages below are needed, each pinned by sha256.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_JDK_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "Contents/Home/bin/java",
    "Contents/Home/bin/jar",
])

filegroup(
    name = "java",
    srcs = ["Contents/Home/bin/java"],
)

filegroup(
    name = "all",
    srcs = glob(["Contents/Home/**"]),
)
"""

_KOTLIN_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "lib/kotlin-compiler.jar",
    "lib/kotlin-stdlib.jar",
    "lib/annotations-13.0.jar",
])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
"""

_BUILD_TOOLS_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files([
    "aapt2",
    "zipalign",
    "lib/d8.jar",
    "lib/apksigner.jar",
])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
"""

_PLATFORM_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "android_jar",
    srcs = ["android.jar"],
)
"""

_PLATFORM_TOOLS_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["adb"])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
"""

_EMULATOR_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["emulator/emulator"])

filegroup(
    name = "all",
    srcs = glob(["emulator/**"]),
)
"""

_SYSTEM_IMAGE_BUILD = """\
package(default_visibility = ["//visibility:public"])

exports_files(["system.img"])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
"""

# The host's builds: a Mac on Apple silicon, and Linux on x86_64 (GitHub's
# hosted runners, where CI boots the emulator under KVM). The system image is
# the host's own architecture, so the emulator runs it natively (HVF, KVM;
# run_emulator.sh picks its ABI by `uname -m`). Each is (url, sha256).
_HOST_ARCHIVES = {
    "mac": {
        "jdk": ("https://github.com/adoptium/temurin21-binaries/releases/download/" +
                "jdk-21.0.5%2B11/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.5_11.tar.gz",
                "dc6db7347907d23743d13af935d3c10e8b3490acdf542115f578838227da0dab"),
        "build_tools": ("https://dl.google.com/android/repository/build-tools_r35_macosx.zip",
                        "530cdbd1ec315e1477624d7ed2f0f2962108d69f36eddba5894cef9ea2cedb48"),
        "platform_tools": ("https://dl.google.com/android/repository/platform-tools_r35.0.2-darwin.zip",
                           "1820078db90bf21628d257ff052528af1c61bb48f754b3555648f5652fa35d78"),
        "emulator": ("https://dl.google.com/android/repository/emulator-darwin_aarch64-15565763.zip",
                     "25378c67fd5bd03178e3a478b866496da8545e969df3a7a26ce9167772ffc026"),
        "system_image": ("https://dl.google.com/android/repository/sys-img/android/arm64-v8a-34_r04.zip",
                         "1447958a4c6747c44390ac5f5f4c894be6d1dfce93868a0385a95c5f0ae4c339"),
        "abi": "arm64-v8a",
    },
    "linux": {
        "jdk": ("https://github.com/adoptium/temurin21-binaries/releases/download/" +
                "jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz",
                "3c654d98404c073b8a7e66bffb27f4ae3e7ede47d13284c132d40a83144bfd8c"),
        "build_tools": ("https://dl.google.com/android/repository/build-tools_r35_linux.zip",
                        "bd3a4966912eb8b30ed0d00b0cda6b6543b949d5ffe00bea54c04c81e1561d88"),
        "platform_tools": ("https://dl.google.com/android/repository/platform-tools_r35.0.2-linux.zip",
                           "acfdcccb123a8718c46c46c059b2f621140194e5ec1ac9d81715be3d6ab6cd0a"),
        "emulator": ("https://dl.google.com/android/repository/emulator-linux_x64-15565763.zip",
                     "6b6eff96c228b96e3feedddf3f5c8e00e84cb66499aaba5a3fd94d74b59d84e1"),
        "system_image": ("https://dl.google.com/android/repository/sys-img/android/x86_64-34_r04.zip",
                         "b57f6386af25b0fe5488e77196b43c03778c6760e6f4311611d090391b9cb2b3"),
        "abi": "x86_64",
    },
}

def _android_tools_impl(mctx):
    host = _HOST_ARCHIVES["linux" if mctx.os.name == "linux" else "mac"]

    http_archive(
        name = "hermetic_jdk",
        url = host["jdk"][0],
        sha256 = host["jdk"][1],
        strip_prefix = "jdk-21.0.5+11",
        build_file_content = _JDK_BUILD,
    )

    http_archive(
        name = "kotlin_compiler",
        url = "https://github.com/JetBrains/kotlin/releases/download/v2.1.20/kotlin-compiler-2.1.20.zip",
        sha256 = "a118197b0de55ffab2bc8d5cd03a5e39033cfb53383d6931bc761dec0784891a",
        strip_prefix = "kotlinc",
        build_file_content = _KOTLIN_BUILD,
    )

    http_archive(
        name = "android_build_tools",
        url = host["build_tools"][0],
        sha256 = host["build_tools"][1],
        strip_prefix = "android-15",
        build_file_content = _BUILD_TOOLS_BUILD,
    )

    http_archive(
        name = "android_platform_jar",
        url = "https://dl.google.com/android/repository/platform-35_r02.zip",
        sha256 = "0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0",
        strip_prefix = "android-35",
        build_file_content = _PLATFORM_BUILD,
    )

    http_archive(
        name = "android_platform_tools",
        url = host["platform_tools"][0],
        sha256 = host["platform_tools"][1],
        strip_prefix = "platform-tools",
        build_file_content = _PLATFORM_TOOLS_BUILD,
    )

    # Emulator + a full AOSP (default) system image so `bazel run
    # //tools/android/emulator` works with nothing preinstalled. A regular
    # GPU-enabled image (not the headless ATD image) is required so the native
    # view overlays the app layers over its GL surface composite correctly.
    http_archive(
        name = "android_emulator",
        url = host["emulator"][0],
        sha256 = host["emulator"][1],
        build_file_content = _EMULATOR_BUILD,
    )

    http_archive(
        name = "android_system_image",
        url = host["system_image"][0],
        sha256 = host["system_image"][1],
        strip_prefix = host["abi"],
        build_file_content = _SYSTEM_IMAGE_BUILD,
    )

android_tools = module_extension(implementation = _android_tools_impl)
