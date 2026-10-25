#!/bin/bash
# Mints the team's development certificate and wildcard provisioning profile
# ("iOS Team Provisioning Profile: *", a year long with a paid team) on a
# Mac that has neither, by building this vanilla project with automatic
# signing. The team is the builder's own, ISOMER_TEAM_ID (the one the
# Playground's .bazelrc.user gives Bazel, tools/signing). The Xcode project
# is not checked in (*.xcodeproj is ignored): make an iOS App project named
# MintProfile here, with MintProfile/App.swift as its only source and the
# Playground's bundle identifier. Connect the iPhone so it is registered if
# it is not already.
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild -project MintProfile.xcodeproj -scheme MintProfile \
    DEVELOPMENT_TEAM="${ISOMER_TEAM_ID:?set ISOMER_TEAM_ID to your Apple team}" \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration build 2>&1 | tail -5
echo "--- profiles now on disk matching the Playground id:"
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
         ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision; do
    [ -f "$f" ] || continue
    if security cms -D -i "$f" 2>/dev/null | grep -q "Isomer.Playground"; then
        echo "$f"
    fi
done
