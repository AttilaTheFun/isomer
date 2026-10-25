#!/bin/bash
# Compiles probes/ against Apple's SwiftUI twice, with Apple's SwiftUIMacros
# plugin and with Isomer's (built to name SwiftUICore, as Apple's does), and
# compares the expansions the compiler prints. Run on a Mac with Xcode.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
(cd .. && bazel build //swift_ui_macros/xcode:SwiftUIMacrosForXcode 2>&1 | grep -E "^ERROR|error:" || true)
plugin="$(cd .. && bazel cquery --output=files //swift_ui_macros/xcode:SwiftUIMacrosForXcode 2>/dev/null | head -1)"
plugin="$(cd .. && pwd)/$plugin#SwiftUIMacros"
out="$(mktemp -d)"
trap 'rm -r "$out"' EXIT
status=0
for probe in probes/*.swift; do
  name="$(basename "$probe" .swift)"
  check=(xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -swift-version 6
         -typecheck -module-name Probe -Xfrontend -dump-macro-expansions "$probe")
  "${check[@]}" > "$out/$name.apple" 2>&1 || true
  "${check[@]}" -load-plugin-executable "$plugin" > "$out/$name.isomer" 2>&1 || true
  if cmp -s "$out/$name.apple" "$out/$name.isomer"; then
    echo "identical: $probe"
  else
    echo "DIFFERENT: $probe"
    diff "$out/$name.apple" "$out/$name.isomer" || true
    status=1
  fi
done
exit $status
