// Isomer's Foundation for the platforms that have no Foundation of Apple's
// (wasm, Android, Linux, Windows): swift-foundation's FoundationEssentials,
// with what corelibs gives Swift code elsewhere (CharacterSet, NSString's
// string API, String(format:) and the rest of this directory),
// FoundationInternationalization when the app asks for it
// (`--@isomer//foundation:internationalization`), and CoreGraphics' geometry,
// which Apple's Foundation re-exports too. There is no corelibs layer: no
// NS classes, CoreFoundation, FoundationNetworking or FoundationXML
// (docs/parity/Foundation.md). URLSession is in this module, as on Apple
// platforms, over the transports a host installs in IsomerFoundation
// (//foundation/isomer_foundation), which this module imports `internal`ly:
// nothing of it reaches an app through `import Foundation`.

@_exported import CoreGraphics
@_exported import FoundationEssentials

// As Apple's Foundation re-exports Darwin and Dispatch (and corelibs Glibc):
// code that imports Foundation reaches memcpy, ceil and DispatchQueue.
#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif canImport(Android)
@_exported import Android
#elseif canImport(WASILibc)
@_exported import WASILibc
#elseif canImport(ucrt)
@_exported import ucrt
#endif
#if canImport(Dispatch)
@_exported import Dispatch
#endif
#if canImport(IsomerFoundationInternationalization)
@_exported import IsomerFoundationInternationalization
#endif

// Dispatch's time constants (NSEC_PER_SEC and its family), which Apple's
// Foundation reaches through Dispatch: neither the Android SDK's libdispatch
// nor WASI (no Dispatch) gives them, so a module of their own does
// (//foundation/dispatch_time), re-exported here as Apple's re-exports Dispatch.
#if os(Android) || os(WASI)
@_exported import IsomerDispatchTime
#endif
