import SDKSmoke

#if canImport(WASILibc)
import WASILibc
#endif

let lines = SmokeChecks.report()
for line in lines { print(line) }
exit(lines.last == "SDKSMOKE PASS" ? 0 : 1)
