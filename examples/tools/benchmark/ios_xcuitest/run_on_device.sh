#!/bin/bash
# Runs the XCUITest perf bundle on a physical iPhone with FREE (personal-team)
# provisioning — the path rules_apple's built-in runner can't take, because it
# names the runner app com.apple.test.* (Apple-reserved, unprovisionable).
#
# We assemble the XCTRunner ourselves with a bundle id you CAN provision
# (com.LoganShire.IsomerUITestRunner — mint its Xcode-managed profile
# once by building an empty app of that id for the device), embed that
# profile, sign everything with its team's Apple Development cert, then drive
# `xcodebuild test-without-building` against a hand-built .xctestrun.
#
#   ISO_TARGET_BUNDLE_ID=com.LoganShire.IsomerExamples \
#   DEVICE_UDID=00008110-001E219A1E44801E \
#   TEST=CellPerformanceTests/testStartup \
#   tools/benchmark/ios_xcuitest/run_on_device.sh
#
# The app under test must already be installed (build+install the cell first);
# XCUIApplication(bundleIdentifier:) launches whatever is on the device.
set -euo pipefail

RUNNER_BUNDLE_ID="${RUNNER_BUNDLE_ID:-com.LoganShire.IsomerUITestRunner}"
TARGET_BUNDLE_ID="${ISO_TARGET_BUNDLE_ID:-com.LoganShire.IsomerExamples}"
DEVICE_UDID="${DEVICE_UDID:?set DEVICE_UDID (xcrun xctrace list devices)}"
TEST="${TEST:-CellPerformanceTests}"
# The app under test as a bundle ON DISK (xctestrun's UITargetAppPath is
# mandatory for UI tests): an .app dir or an .ipa to extract.
TARGET_APP="${ISO_TARGET_APP:?set ISO_TARGET_APP to the cell .app or .ipa}"
: "${BUILD_WORKSPACE_DIRECTORY:=$(cd "$(dirname "$0")/../../.." && pwd)}"
cd "$BUILD_WORKSPACE_DIRECTORY"

DEVDIR="$(xcode-select -p)"
LIBDIR="$DEVDIR/Platforms/iPhoneOS.platform/Developer/Library"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Locating the minted runner profile ($RUNNER_BUNDLE_ID)"
PROFILE=""
for pp in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
          ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision; do
  [ -f "$pp" ] || continue
  appid=$(security cms -D -i "$pp" 2>/dev/null \
    | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null)
  if [[ "$appid" == *".$RUNNER_BUNDLE_ID" ]]; then PROFILE="$pp"; break; fi
done
[ -n "$PROFILE" ] || { echo "No profile for $RUNNER_BUNDLE_ID — mint it in Xcode first."; exit 1; }
echo "    $PROFILE"

# The signing identity + entitlements come from the profile itself.
PLIST="$WORK/profile.plist"
security cms -D -i "$PROFILE" -o "$PLIST" 2>/dev/null
TEAM=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.team-identifier" "$PLIST")
# The signing authority is the CN of the profile's own first certificate
# (identity names don't carry the team id, so no grepping by team).
/usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:0" "$PLIST" > "$WORK/cert.der" 2>/dev/null
CERT_AUTH=$(openssl x509 -inform DER -in "$WORK/cert.der" -noout -subject 2>/dev/null \
  | sed -E 's/.*CN[[:space:]]*=[[:space:]]*([^,\/]+).*/\1/' | sed 's/[[:space:]]*$//')
[ -n "$CERT_AUTH" ] || { echo "Could not read signing cert from profile"; exit 1; }
echo "    identity: $CERT_AUTH  (team $TEAM)"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$PLIST" > "$WORK/entitlements.plist"

step "Building the test bundle (release, device arch)"
bazel build //tools/benchmark/ios_xcuitest:cell_performance_tests \
  -c opt --ios_multi_cpus=arm64 >/dev/null 2>&1
ZIP=$(bazel cquery --output=files //tools/benchmark/ios_xcuitest:cell_performance_tests \
  -c opt --ios_multi_cpus=arm64 2>/dev/null | grep '\.zip$' | head -1)
unzip -qo "$ZIP" -d "$WORK/xctest"
XCTEST="$WORK/xctest/cell_performance_tests.xctest"

step "Assembling the runner app ($RUNNER_BUNDLE_ID)"
RUNNER="$WORK/IsomerUITestRunner-Runner.app"
cp -R "$LIBDIR/Xcode/Agents/XCTRunner.app" "$RUNNER"
chmod -R u+w "$RUNNER"
# Point its Info.plist at our bundle id + product name.
PL="$RUNNER/Info.plist"
plutil -convert xml1 "$PL"
# Keep the executable name XCTRunner (the template binary's actual name);
# only the bundle identifier becomes ours.
sed -i "" \
  -e "s/\$(WRAPPEDPRODUCTNAME)/XCTRunner/g" \
  -e "s/WRAPPEDPRODUCTNAME/XCTRunner/g" \
  -e "s/\$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)/$RUNNER_BUNDLE_ID/g" \
  -e "s/WRAPPEDPRODUCTBUNDLEIDENTIFIER/$RUNNER_BUNDLE_ID/g" "$PL"
plutil -convert binary1 "$PL"

mkdir -p "$RUNNER/PlugIns"
cp -R "$XCTEST" "$RUNNER/PlugIns/"
FW="$RUNNER/Frameworks"; mkdir -p "$FW"
cp -R "$LIBDIR/Frameworks/XCTest.framework" "$FW/"
cp -R "$LIBDIR/PrivateFrameworks/XCTestCore.framework" "$FW/"
cp -R "$LIBDIR/PrivateFrameworks/XCTAutomationSupport.framework" "$FW/"
cp -R "$LIBDIR/PrivateFrameworks/XCUnit.framework" "$FW/"
[ -d "$LIBDIR/PrivateFrameworks/XCTestSupport.framework" ] && \
  cp -R "$LIBDIR/PrivateFrameworks/XCTestSupport.framework" "$FW/"
cp "$DEVDIR/Platforms/iPhoneOS.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib" "$FW/"
cp "$DEVDIR/Platforms/iPhoneOS.platform/Developer/usr/lib/libXCTestBundleInject.dylib" "$FW/"
cp "$PROFILE" "$RUNNER/embedded.mobileprovision"
# Strip arm64e: personal-team signatures can't launch the arm64e slice —
# XCTRunner aborts at _XCTRunnerRunTests (rules_apple does the same strip).
if lipo "$RUNNER/XCTRunner" -verify_arch arm64e 2>/dev/null; then
  lipo "$RUNNER/XCTRunner" -remove arm64e -output "$RUNNER/XCTRunner"
fi

step "Signing (frameworks → xctest → runner)"
for f in "$FW"/*.framework "$FW"/*.dylib; do
  codesign -f --timestamp=none -s "$CERT_AUTH" "$f" >/dev/null 2>&1
done
codesign -f --timestamp=none -s "$CERT_AUTH" \
  --entitlements "$WORK/entitlements.plist" "$RUNNER/PlugIns/cell_performance_tests.xctest" >/dev/null 2>&1
codesign -f --timestamp=none -s "$CERT_AUTH" \
  --entitlements "$WORK/entitlements.plist" "$RUNNER" >/dev/null 2>&1

step "Installing the runner on the device"
xcrun devicectl device install app --device "$DEVICE_UDID" "$RUNNER" >/dev/null

step "Staging the app under test"
if [[ "$TARGET_APP" == *.ipa ]]; then
  unzip -qo "$TARGET_APP" -d "$WORK/target_ipa"
  TARGET_APP="$(find "$WORK/target_ipa" -name '*.app' -maxdepth 3 | head -1)"
fi
TARGET_APP_NAME="$(basename "$TARGET_APP")"
cp -R "$TARGET_APP" "$WORK/$TARGET_APP_NAME"
echo "    $TARGET_APP_NAME"

step "Building the .xctestrun"
XCTESTRUN="$WORK/perf.xctestrun"
cat > "$XCTESTRUN" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CellPerformanceTests</key>
  <dict>
    <key>ProductModuleName</key>
    <string>CellPerformanceTests</string>
    <key>IsUITestBundle</key><true/>
    <key>IsAppHostedTestBundle</key><true/>
    <key>IsXCTRunnerHostedTestBundle</key><true/>
    <key>TestBundlePath</key>
    <string>__TESTHOST__/PlugIns/cell_performance_tests.xctest</string>
    <key>TestHostPath</key>
    <string>__TESTROOT__/IsomerUITestRunner-Runner.app</string>
    <key>TestHostBundleIdentifier</key>
    <string>$RUNNER_BUNDLE_ID</string>
    <key>UITargetAppPath</key>
    <string>__TESTROOT__/$TARGET_APP_NAME</string>
    <key>UITargetAppBundleIdentifier</key>
    <string>$TARGET_BUNDLE_ID</string>
    <key>DependentProductPaths</key>
    <array>
      <string>__TESTHOST__/PlugIns/cell_performance_tests.xctest</string>
      <string>__TESTROOT__/$TARGET_APP_NAME</string>
      <string>__TESTROOT__/IsomerUITestRunner-Runner.app</string>
    </array>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>ISO_TARGET_BUNDLE_ID</key><string>$TARGET_BUNDLE_ID</string>
      <key>ISO_BUSY</key><string>${ISO_BUSY:-0}</string>
    </dict>
    <key>OnlyTestIdentifiers</key>
    <array><string>$TEST</string></array>
  </dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>FormatVersion</key><integer>1</integer>
  </dict>
</dict>
</plist>
PLIST
# (The runner already lives in $WORK, next to the xctestrun — __TESTROOT__
# resolves without copying.)

step "Running: $TEST on $DEVICE_UDID"
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -resultBundlePath "$WORK/result.xcresult" 2>&1 | tee "$WORK/xcodebuild.log" \
  | grep -iE "Test Suite|passed|failed|measured|average|relative|Metric|seconds|error:" || true

step "Results"
RESULT_DIR="${ISO_RESULT_DIR:-/tmp/iso_ios_perf}"
mkdir -p "$RESULT_DIR"
cp -R "$WORK/result.xcresult" "$RESULT_DIR/$(echo "$TEST" | tr '/' '_').xcresult" 2>/dev/null || true
echo "    xcresult: $RESULT_DIR/$(echo "$TEST" | tr '/' '_').xcresult"
