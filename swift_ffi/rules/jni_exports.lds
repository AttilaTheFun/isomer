/* A JNI library's exports when it ships (--//swift_ffi/rules:jni_exports_only,
   kt_swift_library.bzl): the Java_* entry points and JNI_OnLoad, which the
   JVM looks up by name, and nothing else. Every other symbol is local, so
   the linker's --gc-sections drops what no entry point reaches (unused
   Foundation, SwiftUI and SwiftProtobuf code among it). */
{
  global:
    Java_*;
    JNI_OnLoad;
  local:
    *;
};
