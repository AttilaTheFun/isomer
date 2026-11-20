"""Android's macros and rules are the isomer_android module's since 0.59
(@isomer_android//:defs.bzl, android/module here): isomer asks for no
Android or Kotlin rules (docs/platform_modules.md). These say so."""

def _moved(name):
    fail(("%s is the isomer_android module's since 0.59: add bazel_dep(name = \"isomer_android\", " +
          "version = <isomer's>) and load it from @isomer_android//:defs.bzl (docs/platform_modules.md)") % name)

def android_apk(**_kwargs):
    _moved("android_apk")

def flat_assets(**_kwargs):
    _moved("flat_assets")

def isomer_android_webview_app(**_kwargs):
    _moved("isomer_android_webview_app")

def apk_install_run(**_kwargs):
    _moved("apk_install_run")

def isomer_android_library(**_kwargs):
    _moved("isomer_android_library")

def isomer_android_shared_library(**_kwargs):
    _moved("isomer_android_shared_library")

def isomer_wasm_android_library(**_kwargs):
    _moved("isomer_wasm_android_library")

def isomer_android_app(**_kwargs):
    _moved("isomer_android_app")

def isomer_android_aar(**_kwargs):
    _moved("isomer_android_aar")
