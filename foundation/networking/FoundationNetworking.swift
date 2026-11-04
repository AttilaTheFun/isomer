// FoundationNetworking, where Isomer's Foundation is the Foundation (Android,
// the web): Isomer's Foundation, whose URLSession, URLRequest and
// URLResponse are this module's on corelibs. Code written for Linux imports
// it (`#if canImport(FoundationNetworking)`); the Swift SDK's own module of
// this name is corelibs', and beside Isomer's Foundation its URLSession made
// the name ambiguous. This one is found first (a dependency's module before
// the SDK's), so the import gets these types.
@_exported import Foundation
