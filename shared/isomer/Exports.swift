// The Isomer module: what Isomer adds to Apple's frameworks for an app that
// wants it (platform views, platform modifiers, the web view, JSON, the
// platform bridge), and the umbrella over Isomer's own modules, the API
// Isomer gives an app or a host beyond Apple's. `SwiftUI`, `Foundation`,
// `CoreGraphics` and `Metal` stay Apple's interface only (the rule,
// docs/isomer_031_plan.md phase 10): what is Isomer's own is here.
//
// - IsomerFFI: swift_ffi's runtime, its export macros, the injected
//   dependencies a host hands an app.
// - IsomerSwiftUI: binding a host to Isomer's SwiftUI (`HostBridge`,
//   `IsomerRuntime.connection`), the render tree's wire types.
// - IsomerFoundation: what Isomer's Foundation reads of its host (the URL
//   transports, UserDefaults' store), where Foundation is Isomer's.
// - IsomerNetworkHost: the HTTP and WebSocket interfaces a host implements.
// - IsomerMetal: Metal's backend interface and shader translator, where
//   Metal is Isomer's.
// Each where the platform has it.

@_exported import IsomerFFI
#if canImport(IsomerSwiftUI)
@_exported import IsomerSwiftUI
#endif
#if canImport(IsomerFoundation)
@_exported import IsomerFoundation
#endif
#if canImport(IsomerNetworkHost)
@_exported import IsomerNetworkHost
#endif
#if canImport(IsomerMetal)
@_exported import IsomerMetal
#endif
