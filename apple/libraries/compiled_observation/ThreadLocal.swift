// Isomer's: the tracking scope's thread-local, over pthreads. The
// toolchain's ThreadLocal.cpp reads the Swift runtime's own thread-local
// storage through its private headers. The two functions keep the
// runtime's names, so Isomer's core sets a view's scope aside as it does
// on wasm and Android (shared/swift_ui_core/ObservationSupport.swift); the
// OS's own are hidden in libswiftObservation and do not clash.
#if canImport(Darwin)
import Darwin
#endif

private let _observationKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
}()

@_silgen_name("_swift_observation_tls_get")
func _tlsGet() -> UnsafeMutableRawPointer? {
    pthread_getspecific(_observationKey)
}

@_silgen_name("_swift_observation_tls_set")
func _tlsSet(_ value: UnsafeMutableRawPointer?) {
    pthread_setspecific(_observationKey, value)
}

struct _ThreadLocal {
    static var value: UnsafeMutableRawPointer? {
        get { _tlsGet() }
        set { _tlsSet(newValue) }
    }
}
