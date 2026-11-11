#!/bin/bash
# The simulator the test runs on: the one its caller booted, handed over as
# ISOMER_SIMULATOR (the hosted iPhone test's job, which installed the
# headful Storybook in it, tools/ci/hosted_headful_test.sh; the Playground's
# e2e, for the Safari driver). Without it, the test makes one as
# rules_apple's creator does.
set -euo pipefail
if [ -n "${ISOMER_SIMULATOR:-}" ]; then
    printf '%s\n' "$ISOMER_SIMULATOR"
    exit 0
fi
udid="$(xcrun simctl create "isomer-hosted-$$" "${SIMULATOR_DEVICE_TYPE:-iPhone 17}")"
xcrun simctl boot "$udid" > /dev/null
xcrun simctl bootstatus "$udid" -b > /dev/null
printf '%s\n' "$udid"
