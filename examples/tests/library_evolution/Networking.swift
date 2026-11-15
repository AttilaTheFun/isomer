// FoundationNetworking, where Isomer's Foundation is the Foundation (Android,
// the web): code written for Linux imports it for URLSession.
#if canImport(FoundationNetworking)
public import FoundationNetworking

public func resilientSession() -> URLSession {
    URLSession(configuration: .default)
}
#endif
