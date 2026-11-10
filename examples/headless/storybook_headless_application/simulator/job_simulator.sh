#!/bin/bash
# The hosted iPhone test's simulator: the one the job booted and installed
# the headful Storybook in (tools/ci/hosted_headful_test.sh), handed over as
# ISOMER_SIMULATOR. Without it, the test makes one as rules_apple's
# creator does.
set -euo pipefail
if [ -n "${ISOMER_SIMULATOR:-}" ]; then
    printf '%s\n' "$ISOMER_SIMULATOR"
    exit 0
fi
udid="$(xcrun simctl create "isomer-hosted-$$" "${SIMULATOR_DEVICE_TYPE:-iPhone 17}")"
xcrun simctl boot "$udid" > /dev/null
xcrun simctl bootstatus "$udid" -b > /dev/null
printf '%s\n' "$udid"
