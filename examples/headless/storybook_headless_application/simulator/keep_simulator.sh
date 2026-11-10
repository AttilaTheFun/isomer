#!/bin/bash
# The job's simulator is the job's to shut down (hosted_headful_test.sh);
# one made here, without ISOMER_SIMULATOR, is deleted.
if [ -z "${ISOMER_SIMULATOR:-}" ] && [ -n "${SIMULATOR_UDID:-}" ]; then
    xcrun simctl shutdown "$SIMULATOR_UDID" > /dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR_UDID" > /dev/null 2>&1 || true
fi
exit 0
