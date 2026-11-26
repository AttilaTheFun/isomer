// The wasm page's host view: "wasm:page" representables drawn as WasmViews,
// each in a tree of its own (WasmPages).

package dev.isomer.runtime

object WasmPageAppServices {
    fun install() {
        WasmPages.register()
    }
}
