package dev.isomer.runtime

// Runs a WASI command module (a compiler, a linker: something with `_start`)
// under WAMR, from a file, with arguments, an environment and the host
// directories it may open; its stdout and stderr come back as the output. The
// Android Playground compiles with it (the browser's swift-frontend.wasm and
// wasm-ld.wasm, ahead-of-time compiled for the phone). Blocking: call it off
// the main thread.

import java.io.File

object WasiCommand {
    init { System.loadLibrary("iso_wamr_jni") }

    class Result(val exitCode: Int, val output: String) {
        val ok: Boolean get() = exitCode == 0
    }

    /** [argv] starts with the program's name; [dirs] are preopened at their own paths. */
    fun run(module: File, argv: List<String>, dirs: List<File>, envs: Map<String, String> = emptyMap()): Result {
        val output = File.createTempFile("wasi", ".out", module.parentFile)
        try {
            val code = nativeRun(
                module.absolutePath, argv.toTypedArray(),
                dirs.map { it.absolutePath }.toTypedArray(),
                envs.map { (k, v) -> "$k=$v" }.toTypedArray(),
                output.absolutePath,
            )
            return Result(code, output.readText())
        } finally {
            output.delete()
        }
    }

    private external fun nativeRun(
        modulePath: String, argv: Array<String>, dirs: Array<String>, envs: Array<String>, outputPath: String,
    ): Int
}
