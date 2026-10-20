package dev.isomer.runtime

// Benchmark instrumentation: the uniform startup content signal. Logs
// "[content-frame]" ONCE, from the first UI-toolkit draw pass for which
// [ready] returns true — i.e. the first frame that actually draws the app's
// content, not "the framework believes it handed content off" (a JS-side
// commit log) and not "an empty host window appeared" (ActivityManager's
// Displayed). OnDraw fires on the main thread during the traversal that
// renders the frame; presentation follows within the same vsync for every
// cell, so the anchor is uniform across frameworks.

import android.view.View
import android.view.ViewTreeObserver

object ContentFrame {
    /** Install on the window's decor view; [ready] should report whether the
     *  content views exist yet (e.g. the retained tree is non-null). */
    fun install(view: View, ready: () -> Boolean) {
        val listener = object : ViewTreeObserver.OnDrawListener {
            private var logged = false
            override fun onDraw() {
                if (logged || !ready()) return
                logged = true
                android.util.Log.i("Isomer", "[content-frame]")
                // Macrobenchmark's StartupTimingMetric surfaces this as
                // timeToFullDisplayMs - the content-anchored startup.
                var c = view.context
                while (c is android.content.ContextWrapper) {
                    if (c is android.app.Activity) { c.reportFullyDrawn(); break }
                    c = c.baseContext
                }
                // Listeners can't be removed during dispatch; defer.
                view.post { view.viewTreeObserver.removeOnDrawListener(this) }
            }
        }
        if (view.isAttachedToWindow) {
            view.viewTreeObserver.addOnDrawListener(listener)
        } else {
            view.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) {
                    v.viewTreeObserver.addOnDrawListener(listener)
                    v.removeOnAttachStateChangeListener(this)
                }
                override fun onViewDetachedFromWindow(v: View) {}
            })
        }
    }

    /** Content predicate for view-hierarchy frameworks (RN/Valdi-style): the
     *  subtree under [root] has at least [minViews] descendant views — the
     *  mounted label + button rather than an empty shell. */
    fun hasDescendants(root: View, minViews: Int): Boolean {
        var count = 0
        fun walk(v: View) {
            count++
            if (count >= minViews) return
            if (v is android.view.ViewGroup) {
                for (i in 0 until v.childCount) {
                    walk(v.getChildAt(i))
                    if (count >= minViews) return
                }
            }
        }
        walk(root)
        return count >= minViews
    }
}
