// Dispatch's time constants, as Apple's dispatch/time.h defines them and
// its Dispatch module exports them to Swift: here for the platforms whose
// Dispatch lacks them (the Android SDK's libdispatch) or that have none
// (WASI). Foundation re-exports this module there, as Apple's Foundation
// re-exports Dispatch; it holds Apple's names only.

public var NSEC_PER_SEC: UInt64 { 1_000_000_000 }
public var NSEC_PER_MSEC: UInt64 { 1_000_000 }
public var NSEC_PER_USEC: UInt64 { 1_000 }
public var USEC_PER_SEC: UInt64 { 1_000_000 }
