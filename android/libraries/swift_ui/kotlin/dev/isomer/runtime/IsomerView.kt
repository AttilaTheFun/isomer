package dev.isomer.runtime

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.opengl.GLSurfaceView
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout

/**
 * An embeddable Isomer surface — the Android analogue of a
 * `UIHostingController`'s view. Drop it into any layout to host the Isomer
 * app (its Swift `@main`) inside an existing Android screen, for incremental
 * adoption. It owns the GL surface, renderer, touch routing, the IME-backed
 * text input, and the host-view overlay for app-authored representables.
 * All chrome (bars, lists, scrolling, press feedback) is drawn by the Swift
 * runtime into the GL surface — drawn entirely by the SwiftGPURenderer.
 *
 * Backed by the global runtime, so one instance is active at a time. Forward
 * `onResume()`/`onPause()` from the hosting Activity/Fragment lifecycle.
 */
@SuppressLint("ClickableViewAccessibility")
class IsomerView(context: Context) : FrameLayout(context) {
    private val surface = GLSurfaceView(context)
    private val textInput = EditText(context)
    private var suppressWatcher = false

    init {
        IsomerRuntime.prepare(context)
        NativeBridge.appContext = context.applicationContext
        NativeBridge.density = resources.displayMetrics.density

        surface.setEGLContextClientVersion(2)
        surface.setEGLConfigChooser(8, 8, 8, 8, 0, 0)
        surface.setRenderer(UIRenderer())
        surface.renderMode = GLSurfaceView.RENDERMODE_WHEN_DIRTY
        NativeBridge.surface = surface
        // Async image loads live in HostServices now; refresh the GL surface
        // when one lands (the pre-split loadBitmap did this via surface.requestRender).
        NativeBridge.onImageLoaded = { surface.requestRender() }
        surface.setOnTouchListener { _, event ->
            val kind = when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> 0
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> 1
                MotionEvent.ACTION_MOVE -> 2
                else -> -1
            }
            if (kind >= 0) {
                // Anchor at UP (kind 1): the action-triggering event (see WasmGpuView).
                UIRenderer.lastInputAt = if (kind == 1) System.nanoTime() else 0L
                val density = NativeBridge.density
                val x = event.x / density
                val y = event.y / density
                surface.queueEvent {
                    if (NativeBridge.nativePointer(kind, x, y)) surface.requestRender()
                }
            }
            true
        }
        addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        configureTextInput()
        addView(textInput, LayoutParams(dp(200), dp(40)))

        NativeBridge.textInput = textInputBridge()
        NativeBridge.hostViews = HostViewManager(context as Activity, this, surface)
    }

    fun onResume() = surface.onResume()
    fun onPause() = surface.onPause()

    /** Route a system back press to the runtime (pop nav / dismiss sheet); calls
     * `onUnhandled` on the UI thread when there's nothing to pop. */
    fun handleBack(onUnhandled: () -> Unit) {
        // Dismiss the keyboard (e.g. an open list search) when navigating back.
        findFocus()?.clearFocus()
        imm().hideSoftInputFromWindow(windowToken, 0)
        surface.queueEvent {
            if (NativeBridge.nativeBack()) {
                surface.requestRender()
            } else {
                post { onUnhandled() }
            }
        }
    }

    private fun configureTextInput() {
        textInput.visibility = View.GONE
        textInput.inputType = InputType.TYPE_CLASS_TEXT
        textInput.imeOptions = EditorInfo.IME_ACTION_DONE
        textInput.setSingleLine(true)
        textInput.setPadding(dp(8), 0, dp(8), 0)
        textInput.background = null
        textInput.gravity = Gravity.CENTER_VERTICAL
        textInput.setTextColor(0xDD000000.toInt())
        textInput.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(editable: Editable?) {
                if (suppressWatcher) return
                val text = editable?.toString() ?: ""
                surface.queueEvent {
                    if (NativeBridge.nativeTextChanged(text)) surface.requestRender()
                }
            }
        })
        textInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                surface.queueEvent {
                    if (NativeBridge.nativeTextSubmitted()) surface.requestRender()
                }
                true
            } else {
                false
            }
        }
    }

    private fun textInputBridge() = object : NativeBridge.TextInput {
        override fun begin(text: String, x: Float, y: Float, w: Float, h: Float, fontSize: Float) {
            post {
                val density = NativeBridge.density
                val params = LayoutParams((w * density).toInt(), (h * density).toInt())
                params.leftMargin = (x * density).toInt()
                params.topMargin = (y * density).toInt()
                textInput.layoutParams = params
                textInput.setTextSize(TypedValue.COMPLEX_UNIT_PX, fontSize * density)
                suppressWatcher = true
                textInput.setText(text)
                textInput.setSelection(text.length)
                suppressWatcher = false
                textInput.visibility = View.VISIBLE
                textInput.requestFocus()
                imm().showSoftInput(textInput, InputMethodManager.SHOW_IMPLICIT)
            }
        }

        override fun end() {
            post {
                imm().hideSoftInputFromWindow(textInput.windowToken, 0)
                textInput.visibility = View.GONE
                surface.requestFocus()
            }
        }
    }

    private fun imm(): InputMethodManager =
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
