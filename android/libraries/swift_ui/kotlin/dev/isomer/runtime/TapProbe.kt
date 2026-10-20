package dev.isomer.runtime

// The interaction-benchmark probe (the Android peer of the iOS
// InteractionSignpost): an async trace section "iso-tap" from a real tap's
// ACTION_UP receipt to the first pre-draw pass after the cell applied its
// update — Macrobenchmark's TraceSectionMetric reads it. Injection latency
// and RenderThread/present time are outside the section by construction.
//
// A cell wires two things:
//   1. dispatchTouchEvent -> TapProbe.onTouch(this, ev)
//   2. its update signal  -> TapProbe.markUpdated()
//      (the Compose ISO cells get 2. for free: ComposeTreeState.applyPatch
//      calls it directly)
//
// Only real TAPS open a section (travel <= touchSlop, hold < 300 ms): a
// swipe's ACTION_UP must not open a phantom section.
object TapProbe {
    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L
    private var tapUpAt = 0L
    private var sectionOpen = false
    private var updatedSinceTap = false

    fun install(activity: android.app.Activity) {
        activity.window.decorView.viewTreeObserver.addOnPreDrawListener {
            if (sectionOpen && updatedSinceTap) {
                val ms = android.os.SystemClock.uptimeMillis() - tapUpAt
                android.util.Log.i("Isomer", "[native-tap] ${ms}ms")
                android.os.Trace.endAsyncSection("iso-tap", 0)
                sectionOpen = false
                updatedSinceTap = false
            }
            true
        }
    }

    fun onTouch(activity: android.app.Activity, ev: android.view.MotionEvent) {
        when (ev.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                downX = ev.x; downY = ev.y
                downAt = android.os.SystemClock.uptimeMillis()
            }
            android.view.MotionEvent.ACTION_UP -> {
                val slop = android.view.ViewConfiguration.get(activity).scaledTouchSlop
                val dx = ev.x - downX
                val dy = ev.y - downY
                val heldMs = android.os.SystemClock.uptimeMillis() - downAt
                if (dx * dx + dy * dy <= slop.toFloat() * slop && heldMs < 300) {
                    tapUpAt = android.os.SystemClock.uptimeMillis()
                    updatedSinceTap = false
                    android.os.Trace.beginAsyncSection("iso-tap", 0)
                    sectionOpen = true
                }
            }
        }
    }

    fun markUpdated() {
        updatedSinceTap = true
    }
}
