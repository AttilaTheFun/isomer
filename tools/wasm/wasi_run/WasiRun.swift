// wasi_run: runs a WASI command module under WasmKit, from the shell or a
// test (Foundation's, the Metal translator's, SQLite's checks).
//
//   wasi_run [--dir=<path>]... [--map-dir=<guest>::<host>]... [--env=NAME=value]...
//            [--stack-size=<bytes>] <module.wasm> [args...]
//
// The options are the ones WAMR's `iwasm` took before it (0.38): `--dir`
// preopens a host directory under its own path, `--map-dir` under another
// (the guest's path first). The guest's stdout and stderr are this process's;
// its exit code is this process's, 1 when it traps. A module that imports a
// shared memory (built for wasm32-wasip1-threads) runs with WASI Threads.

import Foundation
import WASI
import WasmKit
import WasmKitWASI
import WasmKitWASIThreads

@main
enum WasiRun {
    static func main() {
        var preopens: [WASIBridgeToHost.Preopen] = []
        var environment: [String: String] = [:]
        // The interpreter's own stack (WasmKit's default is 512 KiB):
        // Foundation's and the translator's checks recurse further than that.
        var stackSize = 16 << 20

        let commandLine = CommandLine.arguments
        var index = 1
        options: while index < commandLine.count {
            let argument = commandLine[index]
            if let path = argument.value(after: "--dir=") {
                preopens.append(.init(guestPath: path, hostPath: path))
            } else if let value = argument.value(after: "--map-dir=") {
                guard let separator = value.range(of: "::") else {
                    fail("--map-dir wants guest::host, got \(value)", code: 2)
                }
                preopens.append(
                    .init(
                        guestPath: String(value[..<separator.lowerBound]),
                        hostPath: String(value[separator.upperBound...])))
            } else if let value = argument.value(after: "--env=") {
                guard let equals = value.firstIndex(of: "=") else {
                    fail("--env wants NAME=value, got \(value)", code: 2)
                }
                environment[String(value[..<equals])] = String(value[value.index(after: equals)...])
            } else if let value = argument.value(after: "--stack-size=") {
                guard let bytes = Int(value), bytes > 0 else { fail("--stack-size wants bytes, got \(value)", code: 2) }
                stackSize = bytes
            } else {
                break options
            }
            index += 1
        }
        guard index < commandLine.count else {
            fail(
                "usage: wasi_run [--dir=path]... [--map-dir=guest::host]... [--env=K=V]... "
                    + "[--stack-size=bytes] module.wasm [args...]", code: 2)
        }
        let path = commandLine[index]
        // argv[0] is the module's path, as `iwasm` gave it.
        let arguments = Array(commandLine[index...])

        var configuration = EngineConfiguration(stackSize: stackSize)
        configuration.features.insert(.threads)
        let engine = Engine(configuration: configuration)

        let module: Module
        do {
            module = try parseWasm(filePath: path, features: configuration.features)
        } catch {
            fail("cannot load \(path): \(error)", code: 2)
        }
        let threaded = module.imports.contains {
            if case .memory(let type) = $0.descriptor { return type.shared }
            return false
        }

        let wasi: WASIBridgeToHost
        do {
            wasi = try WASIBridgeToHost(args: arguments, environment: environment, preopens: preopens)
        } catch {
            fail("WASI: \(error)", code: 2)
        }

        do {
            let code = try wasi.runAndClose { wasi -> UInt32 in
                let store = Store(engine: engine)
                guard threaded else {
                    var imports = Imports()
                    wasi.link(to: &imports, store: store)
                    return try wasi.start(try module.instantiate(store: store, imports: imports))
                }
                // The process ends when the main thread returns or a guest
                // thread fails, as a native program's does.
                let threads = try WASIThreads(
                    module: module, engine: engine,
                    processControl: .init(
                        terminateAfterMainReturn: { code in exit(Int32(truncatingIfNeeded: code)) },
                        terminateAfterWorkerFailure: { error in
                            if let exitCode = error as? WASIExitCode {
                                exit(Int32(truncatingIfNeeded: exitCode.code))
                            }
                            fail("a guest thread failed: \(error)")
                        }),
                    childImports: { store in
                        var imports = Imports()
                        wasi.link(to: &imports, store: store)
                        return imports
                    })
                let instance = try module.instantiate(store: store, imports: try threads.makeImports(store: store))
                threads.mainThreadDidExit(code: try wasi.start(instance))
            }
            exit(Int32(truncatingIfNeeded: code))
        } catch {
            fail("\(error)")
        }
    }
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("wasi_run: \(message)\n".utf8))
    exit(code)
}

extension String {
    /// What follows `prefix`, when the string starts with it.
    fileprivate func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
