// Subprocess support for the SIMULATOR compile backend. The iOS SDK hides
// Foundation.Process and marks posix_spawn unavailable — but a simulator app
// is an unhardened macOS process where the symbols exist in libSystem, so we
// resolve them with dlsym at runtime. On a real device resolution fails and
// `Spawn.isAvailable` is false (the device backend links the compiler as a
// library instead of spawning it).

import Foundation

enum Spawn {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    // C signatures for the dlsym'd entry points. posix_spawn_file_actions_t
    // is pointer-sized and opaque; we pass pointers to a raw slot.
    private typealias SpawnFn = @convention(c) (
        UnsafeMutablePointer<pid_t>?, UnsafePointer<CChar>?,
        UnsafeRawPointer?, UnsafeRawPointer?,
        UnsafePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias ActionsFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ActionsDup2Fn = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32
    ) -> Int32
    private typealias ActionsCloseFn = @convention(c) (
        UnsafeMutableRawPointer?, Int32
    ) -> Int32
    private typealias WaitpidFn = @convention(c) (
        pid_t, UnsafeMutablePointer<Int32>?, Int32
    ) -> pid_t

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let raw = dlsym(dlopen(nil, RTLD_NOW), name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private static let posixSpawn = symbol("posix_spawn", as: SpawnFn.self)
    private static let actionsInit = symbol("posix_spawn_file_actions_init", as: ActionsFn.self)
    private static let actionsDestroy = symbol("posix_spawn_file_actions_destroy", as: ActionsFn.self)
    private static let actionsDup2 = symbol("posix_spawn_file_actions_adddup2", as: ActionsDup2Fn.self)
    private static let actionsClose = symbol("posix_spawn_file_actions_addclose", as: ActionsCloseFn.self)
    private static let waitpidFn = symbol("waitpid", as: WaitpidFn.self)

    static var isAvailable: Bool {
        posixSpawn != nil && actionsInit != nil && actionsDup2 != nil && waitpidFn != nil
    }

    /// Runs `tool` with `arguments` and a MINIMAL environment (the simulator
    /// app's own environ is full of sim-flavored DYLD state that would
    /// confuse a host toolchain child). Blocks until exit; call off-main.
    static func run(
        _ tool: String, _ arguments: [String], environment: [String: String] = [:]
    ) -> Output {
        guard let posixSpawn, let actionsInit, let actionsDup2, let waitpidFn else {
            return Output(status: -1, stdout: "", stderr: "spawn unavailable on this platform")
        }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return Output(status: -1, stdout: "", stderr: "pipe() failed: \(errno)")
        }

        // One pointer-sized opaque slot for posix_spawn_file_actions_t.
        let actions = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<UnsafeRawPointer>.size,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { actions.deallocate() }
        _ = actionsInit(actions)
        defer { _ = actionsDestroy?(actions) }
        _ = actionsDup2(actions, outPipe[1], 1)
        _ = actionsDup2(actions, errPipe[1], 2)
        _ = actionsClose?(actions, outPipe[0])
        _ = actionsClose?(actions, errPipe[0])

        var env = environment
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin" }
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }
        if env["HOME"] == nil { env["HOME"] = NSTemporaryDirectory() }

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([tool] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posixSpawn(&pid, tool, actions, nil, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return Output(
                status: -1, stdout: "",
                stderr: "posix_spawn(\(tool)) failed: \(rc) (\(String(cString: strerror(rc))))")
        }

        // Drain both pipes without deadlocking on a full buffer: non-blocking
        // reads in a poll loop until both hit EOF.
        for fd in [outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        }
        var stdoutData = Data()
        var stderrData = Data()
        var openCount = 2
        var buffer = [UInt8](repeating: 0, count: 65536)
        var outOpen = true
        var errOpen = true
        while openCount > 0 {
            var drained = false
            for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
                if isOut ? !outOpen : !errOpen { continue }
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    drained = true
                    let chunk = Data(bytes: buffer, count: n)
                    if isOut { stdoutData.append(chunk) } else { stderrData.append(chunk) }
                } else if n == 0 {
                    close(fd)
                    if isOut { outOpen = false } else { errOpen = false }
                    openCount -= 1
                } else if errno != EAGAIN {
                    close(fd)
                    if isOut { outOpen = false } else { errOpen = false }
                    openCount -= 1
                }
            }
            if !drained && openCount > 0 { usleep(5000) }
        }

        var status: Int32 = 0
        while waitpidFn(pid, &status, 0) == -1 && errno == EINTR {}
        // WIFEXITED/WEXITSTATUS without the (unavailable) macros.
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -status
        return Output(
            status: exitCode,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self))
    }
}
