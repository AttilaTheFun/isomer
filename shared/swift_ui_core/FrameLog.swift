// The frame log, for finding what a frame rebuilds: with `ISO_FRAME_LOG` in
// the host's environment (read as `hostValue("env:ISO_FRAME_LOG")`), each
// build of the tree is logged through the host: the state written since the
// build before (what it rebuilds around), how many composite views were
// reused, and the ones built, by type, with why each was not reused:
//
//   new         first built here (or its place changed)
//   state       state it or a view inside it owns was written
//   inputs      its stored properties differ from last frame's
//   environment the environment it was built in differs
//   context     a style stack it was built under differs
//   volatile    last frame's build read runtime state (a .task, an
//               .onAppear, a GeometryReader, …), so it was not kept
//   binding     last frame's build read a binding's value
//   uncomparable its inputs cannot be compared (a closure), so it was not kept
//   type, navigation   its type, or the navigation level it is at, changed
//
// Off, it costs one check per frame.

final class _FrameLog {
    /// "Type: reason" → how many were built this build.
    var built: [String: Int] = [:]
    /// Why the build at a path was not kept, last build and this one.
    var notKept: [String: String] = [:]
    var notKeptNext: [String: String] = [:]
    /// The built-in views whose builds were volatile, by type.
    var volatileBy: [String: Int] = [:]
    /// Each composite type's builds' time, inclusive of what they built
    /// inside them (ms; nested builds of one type count once each).
    var inclusive: [String: Double] = [:]
    var reusedAtStart = 0
    /// The views a partial frame built alone (InPlace.swift), or why the
    /// frame was built whole ("whole: …").
    var inPlace: [String] = []
    var partial = ""
    var dirty: [String] = []
    var started = 0.0
    var builds = 0
}

extension Runtime {
    /// The frame log, when the host asked for one (checked once).
    var activeFrameLog: _FrameLog? {
        if !frameLogChecked {
            frameLogChecked = true
            if host?.hostValue("env:ISO_FRAME_LOG") != nil { frameLog = _FrameLog() }
        }
        return frameLog
    }

    func frameLogBegin() {
        guard let log = activeFrameLog else { return }
        log.built = [:]
        log.volatileBy = [:]
        log.inclusive = [:]
        log.inPlace = []
        log.partial = ""
        log.notKept = log.notKeptNext
        log.notKeptNext = [:]
        log.reusedAtStart = reusedSubtrees
        log.dirty = dirtyStateKeys.sorted()
        log.started = host?.now() ?? 0
    }

    func frameLogEnd() {
        guard let log = frameLog, let host else { return }
        log.builds += 1
        let ms = ((host.now()) - log.started) * 1000
        let dirty = log.dirty.prefix(4).joined(separator: ", ") + (log.dirty.count > 4 ? " (+\(log.dirty.count - 4))" : "")
        let total = log.built.values.reduce(0, +)
        let top = log.built.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(14).map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
        let volatile = log.volatileBy.sorted { $0.value > $1.value }.prefix(60).map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
        let slowest = log.inclusive.sorted { $0.value > $1.value }.prefix(12)
            .map { "\($0.key) \(Int($0.value))" }.joined(separator: "; ")
        let how = log.inPlace.isEmpty ? (log.partial.isEmpty ? "" : " (\(log.partial))")
            : " (in place: \(log.inPlace.joined(separator: ", ")))"
        host.log("[frame] build \(log.builds)\(how) \(Int(ms)) ms | written: \(dirty.isEmpty ? "-" : dirty) | reused \(reusedSubtrees &- log.reusedAtStart) | built \(total): \(top) | volatile: \(volatile) | ms by type: \(slowest)")
    }
}

/// Notes a composite view built (not reused), with why.
func _frameLogBuilt(_ view: any View, ctx: BuildContext) {
    guard let log = Runtime.shared.frameLog else { return }
    let runtime = Runtime.shared
    let reason: String
    if let entry = runtime.buildCache[ctx.path] {
        if type(of: entry.view) != type(of: view) { reason = "type" }
        else if entry.navigationLevel != ctx.navigationLevel || entry.navigation != ctx.navigation.map(ObjectIdentifier.init) { reason = "navigation" }
        else if runtime.hasDirtyState(under: ctx.path) { reason = "state" }
        else if !reuseEqual(entry.view, view) { reason = "inputs" }
        else if !entry.env._sameForReuse(ctx.env) { reason = "environment" + _frameLogEnvironmentDifference(entry.env, ctx.env) }
        else if entry.context != runtime.reuseContext() { reason = "context" }
        else { reason = "?" }
    } else {
        reason = log.notKept[ctx.path] ?? "new"
    }
    let name = String(_typeName(type(of: view), qualified: false).prefix(48))
    log.built["\(name): \(reason)", default: 0] += 1
}

/// What differs between two environments a view was built in, by field
/// (" (font, custom Bool)": a custom key by its value's type), read
/// through reflection: the log's only. The transaction's animation, which
/// reuse does not compare, is left out.
func _frameLogEnvironmentDifference(_ a: EnvironmentValues, _ b: EnvironmentValues) -> String {
    var names: [String] = []
    let theirs = Dictionary(Mirror(reflecting: b._storage).children.compactMap { child in
        child.label.map { ($0, child.value) }
    }, uniquingKeysWith: { first, _ in first })
    for child in Mirror(reflecting: a._storage).children {
        guard let label = child.label, label != "animation", label != "animationChosen", label != "custom",
              let other = theirs[label] else { continue }
        if String(describing: child.value) != String(describing: other) { names.append(label) }
    }
    for (key, value) in a.custom where b.custom[key].map({ !reuseEqual(value, $0) }) ?? true {
        names.append("custom \(type(of: value))")
    }
    for (key, value) in b.custom where a.custom[key] == nil { names.append("custom \(type(of: value))") }
    return names.isEmpty ? "" : " (\(names.prefix(4).joined(separator: ", ")))"
}

/// When a composite's build started (frame log on), for its time.
func _frameLogStart() -> Double {
    guard Runtime.shared.frameLog != nil, let host = Runtime.shared.host else { return 0 }
    return host.now()
}

/// Adds a composite's build time, from `started`.
func _frameLogTime(_ view: any View, started: Double) {
    guard let log = Runtime.shared.frameLog, let host = Runtime.shared.host else { return }
    let name = String(_typeName(type(of: view), qualified: false).prefix(32))
    log.inclusive[name, default: 0] += (host.now() - started) * 1000
}

/// Times a first answer about a type (a reuse plan, a property layout),
/// logging those over 2 ms with the frame log on: they are where a first
/// build's time goes when the runtime scans for conformances.
func _frameLogTypeFact<T>(_ what: String, _ type: Any.Type, _ work: () -> T) -> T {
    guard Runtime.shared.frameLog != nil, let host = Runtime.shared.host else { return work() }
    let started = host.now()
    let result = work()
    let ms = (host.now() - started) * 1000
    if ms > 2 { host.log("[type] \(what) \(String(_typeName(type, qualified: false).prefix(80))) \(Int(ms)) ms") }
    return result
}

/// Notes why a composite's build was not kept for reuse.
func _frameLogNotKept(path: String, volatile: Bool, bindingRead: Bool) {
    guard let log = Runtime.shared.frameLog else { return }
    log.notKeptNext[path] = path == "root" ? "root" : volatile ? "volatile" : bindingRead ? "binding" : "uncomparable"
}

/// Notes a built-in view whose build was volatile.
func _frameLogVolatile(_ view: any View) {
    guard let log = Runtime.shared.frameLog else { return }
    var name = _typeName(type(of: view), qualified: false)
    if let modified = view as? _ModifiedView { name = "." + modified.descend }
    log.volatileBy[String(name.prefix(70)), default: 0] += 1
}
