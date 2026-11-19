import IsomerFFI
import SDKSmoke

/// The checks' report, a line each, the last "SDKSMOKE PASS" or
/// "SDKSMOKE FAIL".
@ExportedFunction
public func smokeReport() -> String {
    SmokeChecks.report().joined(separator: "\n")
}
