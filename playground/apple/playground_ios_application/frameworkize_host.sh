#!/bin/bash
# Converts the staged host dylibs (compiler SwiftSyntax libs, the in-process
# plugin server, prebuilt macro plugins) into embedded FRAMEWORKS under
# host/frameworks/<name>.framework — iOS only loads code the app bundle
# embeds in Frameworks/ with a signature, and rules_apple signs imported
# dynamic frameworks (raw resource dylibs ship unsigned → dyld refuses them
# on device: "missing code signature"). Install names are rewritten to
# @rpath/<name>.framework/<name>. Idempotent; the raw dylibs are removed.
#   frameworkize_host.sh embedded_toolchain/<platform>/host <platform>
set -euo pipefail
HOST="$1"; PLATFORM="${2:-iphoneos}"
[ "$PLATFORM" = "iphonesimulator" ] && SUPPORTED="iPhoneSimulator" || SUPPORTED="iPhoneOS"
FW="$HOST/frameworks"; mkdir -p "$FW"
DYLIBS=$(find "$HOST" -maxdepth 2 -name "*.dylib" -not -path "$FW/*")
[ -z "$DYLIBS" ] && { echo "nothing to convert in $HOST"; exit 0; }
# Framework names are SHORT on purpose: install_name_tool can only rewrite a
# load command in place when the new path is no longer than the old one
# ("@rpath/<name>.dylib" → "@rpath/<N>.framework/<N>" needs
# 2·len(N) ≤ len(name) − 5), and the simulator dylibs carry no header
# padding. Two swift-syntax families exist: the compiler's own
# (lib_CompilerSwift*, prefix C) and the plugin server's (libSwift*, prefix S).
short_name() {
    case "$1" in
        lib_CompilerSwiftBasicFormat) echo CBasicFmt ;;
        lib_CompilerSwiftCompilerPluginMessageHandling) echo CPluginMsgHandling ;;
        lib_CompilerSwiftDiagnostics) echo CDiag ;;
        lib_CompilerSwiftIDEUtils) echo CIDEUtils ;;
        lib_CompilerSwiftIfConfig) echo CIfConfig ;;
        lib_CompilerSwiftLexicalLookup) echo CLexLookup ;;
        lib_CompilerSwiftOperators) echo COperators ;;
        lib_CompilerSwiftParser) echo CParser ;;
        lib_CompilerSwiftParserDiagnostics) echo CParserDiag ;;
        lib_CompilerSwiftSyntax) echo CSyntax ;;
        lib_CompilerSwiftSyntaxBuilder) echo CSynBuilder ;;
        lib_CompilerSwiftSyntaxMacroExpansion) echo CMacroExpansion ;;
        lib_CompilerSwiftSyntaxMacros) echo CSynMacros ;;
        libSwiftBasicFormat) echo SBasFmt ;;
        libSwiftCompilerPluginMessageHandling) echo SPluginMsgHdl ;;
        libSwiftDiagnostics) echo SDiag ;;
        libSwiftIfConfig) echo SIfC ;;
        libSwiftInProcPluginServer) echo SPluginSrv ;;
        libSwiftLibraryPluginProvider) echo SLibPlugProv ;;
        libSwiftOperators) echo SOps ;;
        libSwiftParser) echo SPrs ;;
        libSwiftParserDiagnostics) echo SParserDg ;;
        libSwiftSyntax) echo SSyn ;;
        libSwiftSyntaxBuilder) echo SSynBld ;;
        libSwiftSyntaxMacroExpansion) echo SMacroExp ;;
        libSwiftSyntaxMacros) echo SSynMac ;;
        *) echo "$1" ;;
    esac
}
NAMES=()
for d in $DYLIBS; do NAMES+=("$(basename "$d" .dylib)"); done
for d in $DYLIBS; do
    n="$(basename "$d" .dylib)"; N="$(short_name "$n")"; dir="$FW/$N.framework"
    # Macro PLUGINS (host/plugins) keep a lib<Name>.dylib binary name: the
    # frontend derives the plugin's module name from exactly that shape
    # (PluginLoader.cpp), and rules_apple copies + signs a framework whose
    # binary isn't named after it without linking it — right for a dlopen'd
    # plugin. Everything else is linked, so binary == framework name.
    # rules_apple additionally requires binary == framework name, so a plugin
    # framework is "lib<Name>.dylib.framework/lib<Name>.dylib" (imported
    # bundle_only: copied + signed, never linked, so its install name is moot).
    case "$d" in */plugins/*) bin="$n.dylib"; dir="$FW/$n.dylib.framework" ;; *) bin="$N" ;; esac
    mkdir -p "$dir"
    cp "$d" "$dir/$bin"; chmod u+w "$dir/$bin"
    case "$d" in */plugins/*) ;; *) install_name_tool -id "@rpath/$N.framework/$N" "$dir/$bin" ;; esac
    for dep in "${NAMES[@]}"; do
        D="$(short_name "$dep")"
        if otool -L "$dir/$bin" | grep -q "@rpath/$dep.dylib"; then
            install_name_tool -change "@rpath/$dep.dylib" "@rpath/$D.framework/$D" "$dir/$bin"
        fi
    done
    # Anything still pointing at a .dylib install name would fail at dyld.
    # (skip the file-name + LC_ID lines: a plugin keeps its lib<Name>.dylib id)
    if otool -L "$dir/$bin" | tail -n +3 | grep -E "@rpath/lib(_Compiler)?Swift[A-Za-z]*\.dylib" >/dev/null; then
        echo "ERROR: unresolved install names in $dir/$bin:"; otool -L "$dir/$bin" | grep "@rpath/.*\.dylib"; exit 1
    fi
    cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$bin</string>
  <key>CFBundleIdentifier</key><string>com.LoganShire.Isomer.$(echo "$bin" | tr '_.' '--')</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$bin</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$SUPPORTED</string></array>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PLIST
    rm "$d"
done
rmdir "$HOST/plugins" 2>/dev/null || true
echo "converted ${#NAMES[@]} dylibs into $FW"
