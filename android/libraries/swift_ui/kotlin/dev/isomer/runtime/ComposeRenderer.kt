package dev.isomer.runtime

// The Kotlin half of the JetpackComposeRenderer (the component-system
// renderer bound by nativeStart when the host asks for "jetpackCompose").
//
// Interprets the runtime's serialized view tree (docs/renderer_layers.md) as
// Material 3 composables: stacks become Column/Row/Box, chrome host views
// become TopAppBar/NavigationBar/DropdownMenu/Switch/DatePickerDialog, and
// presentations become ModalBottomSheet/AlertDialog — the app should feel
// like a Material app, not a redrawn iOS one. Interactive nodes report back
// through SwiftUIBridge.nativeHostEvent (which feeds Runtime.hostViewEvent).
// Compose owns layout and recomposition — the runtime never computes frames
// or emits a draw list under this binding.

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.border
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.RadioButton
import androidx.compose.ui.semantics.Role
import kotlinx.coroutines.launch
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.Brush
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ColorScheme
import androidx.compose.ui.draw.blur
import androidx.compose.ui.zIndex
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.absolutePadding
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalConfiguration
import android.app.Activity
import android.webkit.WebView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.SuspendingPointerInputModifierNode
import androidx.compose.ui.node.DelegatingNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.PointerInputModifierNode
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ProgressIndicatorDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.IntOffset
import androidx.compose.foundation.layout.offset
import kotlin.math.roundToInt
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.window.Popup
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONArray
import org.json.JSONObject

/** The latest retained render tree from Swift; recomposition follows the state.
 *  Unchanged subtrees keep their [UNode] identity across updates (see
 *  [FlatTree.applyPatch]) so the skippable
 *  [IsoNode] only recomposes the views that actually changed. */
object ComposeTreeState {
    val tree = androidx.compose.runtime.mutableStateOf<UNode?>(null)
    val imageTick = mutableStateOf(0)

    /** Apply a `Patch` buffer to the retained tree — the only wire format,
     *  compiled and wasm alike (the first patch is a full root op). Only the
     *  changed nodes' identities change. */
    fun applyPatch(bytes: ByteArray) {
        android.os.Trace.beginSection("iso:patch")
        try { tree.value = FlatTree.applyPatch(tree.value, bytes) } finally { android.os.Trace.endSection() }
        // `adb shell setprop log.tag.IsoTree DEBUG`: the retained tree, one
        // line per node, for verifying a layout on a device.
        if (android.util.Log.isLoggable("IsoTree", android.util.Log.DEBUG)) {
            fun dump(n: UNode, depth: Int) {
                val j = n.json
                val keys = j.keys().asSequence().filter { it != "ch" && it != "params" }.joinToString(" ") { k -> "$k=${j.opt(k).toString().take(if (k == "key") 400 else 40)}" }
                val params = j.optJSONObject("params")?.let { pj -> pj.keys().asSequence().joinToString(" ") { k -> "$k=${pj.opt(k).toString().take(30)}" } } ?: ""
                android.util.Log.d("IsoTree", "  ".repeat(depth) + keys + (if (params.isEmpty()) "" else " {$params}"))
                for (c in n.children) dump(c, depth + 1)
            }
            tree.value?.let { dump(it, 0) }
        }
        // Benchmark: the TapProbe's update signal, compiled and wasm alike
        // (a bare flag set; dormant without an armed probe).
        TapProbe.markUpdated()
        logTapLatency()
    }

    /** Benchmark hook: when a tree update is the response to a tap (sendEvent
     *  stamped IsoEventRouter.lastEventAt), log tap->tree latency. Uniform for the
     *  compiled cell (full trees) and the wasm cell (diff Patches) since both
     *  route tap -> sendEvent -> sink -> (in-process Swift | WasmKit reactor) ->
     *  applyPatch. See docs/benchmarks.md. */
    private fun logTapLatency() {
        val at = IsoEventRouter.lastEventAt
        if (at > 0L) {
            IsoEventRouter.lastEventAt = 0L
            android.util.Log.i(
                "Isomer",
                "[iso-tap] latency=${android.os.SystemClock.uptimeMillis() - at}ms",
            )
        }
    }

    /** Drop the retained tree (e.g. a wasm bundle relaunch) so the next patch's
     *  root op rebuilds from scratch. */
    fun clear() {
        tree.value = null
    }
}

/** Where a node's events go. Defaults to a no-op so the interpreter carries NO
 *  dependency on the native `SwiftUIBridge` (that is what lets it run in the
 *  Swift-free wasm cell). The native compiled-Swift path installs a sink that
 *  feeds the in-process Swift runtime and pumps frames (see
 *  `installNativeEventSink`); the wasm WasmView (//android/libraries/wasm_view)
 *  installs a sink that routes to its WasmKit reactor. */
object IsoEventRouter {
    var sink: (String, String) -> Unit = { _, _ -> }

    /** A field's key for `.onKeyPress`, answered synchronously: true when
     *  the app took it (and the field must not type it). */
    var keySink: (String, String) -> Boolean = { _, _ -> false }

    /** Uptime (ms) the last real tap was dispatched, consumed by
     *  [ComposeTreeState.applyPatch] to log tap->tree latency. 0 = none pending. */
    @Volatile var lastEventAt: Long = 0L
}

/** The Compose keys a `KeyEquivalent` names by AppKit's private-use characters. */
private val keyEquivalents = mapOf(
    Key.Enter to "\r", Key.NumPadEnter to "\r", Key.Backspace to "\u007f", Key.Delete to "\uf728",
    Key.Escape to "\u001b", Key.Tab to "\t",
    Key.DirectionUp to "\uf700", Key.DirectionDown to "\uf701",
    Key.DirectionLeft to "\uf702", Key.DirectionRight to "\uf703",
    Key.MoveHome to "\uf729", Key.MoveEnd to "\uf72b", Key.PageUp to "\uf72c", Key.PageDown to "\uf72d",
)

/** A hardware key event as `KeyPress(hostValue:)` reads it (see the web
 *  renderer's keyPress): true when the app took it. */
private fun keyPress(id: String, event: androidx.compose.ui.input.key.KeyEvent, keyUp: Boolean): Boolean {
    val native = event.nativeKeyEvent
    val phase = when {
        event.type == KeyEventType.KeyUp -> if (keyUp) "u" else return false
        event.type != KeyEventType.KeyDown -> return false
        native.repeatCount > 0 -> "r"
        else -> "d"
    }
    val named = keyEquivalents[event.key]
    // The character the key types without Control/Alt (Ctrl+C is "c").
    val plain = native.getUnicodeChar(native.metaState and
        (android.view.KeyEvent.META_SHIFT_MASK or android.view.KeyEvent.META_CAPS_LOCK_ON))
    val key = named ?: if (plain > 0) String(Character.toChars(plain)) else return false
    var mods = phase
    if (event.isShiftPressed) mods += "s"
    if (event.isCtrlPressed) mods += "c"
    if (event.isAltPressed) mods += "o"
    if (event.isMetaPressed) mods += "m"
    if (native.isCapsLockOn) mods += "l"
    val chars = named ?: if (event.isCtrlPressed && key.length == 1 && key[0].code in 0x40..0x7f)
        (key.uppercase()[0].code and 0x1f).toChar().toString()
    else if (event.utf16CodePoint > 0) String(Character.toChars(event.utf16CodePoint)) else key
    return IsoEventRouter.keySink(id, "$mods\u001f$key\u001f$chars")
}

private fun sendEvent(id: String, value: String) {
    if (id.isEmpty()) return
    IsoEventRouter.lastEventAt = android.os.SystemClock.uptimeMillis()
    IsoEventRouter.sink(id, value)
}

/** Parses the serialized gradient paint into a Brush (direction approximated). */
private fun gradientBrush(n: JSONObject): androidx.compose.ui.graphics.Brush? {
    val spec = try {
        JSONObject(n.optString("gradient").ifEmpty { return null })
    } catch (_: Exception) {
        return null
    }
    val stops = spec.optJSONArray("stops") ?: return null
    val colors = (0 until stops.length()).mapNotNull { index ->
        colorOf(stops.getJSONObject(index), "c")
    }
    if (colors.isEmpty()) return null
    return when (spec.optString("kind")) {
        "radial" -> androidx.compose.ui.graphics.Brush.radialGradient(colors)
        "angular" -> androidx.compose.ui.graphics.Brush.sweepGradient(colors)
        "solid" -> androidx.compose.ui.graphics.SolidColor(colors.first())
        else -> androidx.compose.ui.graphics.Brush.linearGradient(colors)
    }
}

/** A "#rrggbbaa" color, as tints and symbol styles travel. */
private fun hexColorOf(hex: String): Color? {
    val digits = hex.removePrefix("#")
    if (digits.length != 8) return null
    val value = digits.toLongOrNull(16) ?: return null
    return Color(
        red = ((value shr 24) and 0xff) / 255f, green = ((value shr 16) and 0xff) / 255f,
        blue = ((value shr 8) and 0xff) / 255f, alpha = (value and 0xff) / 255f)
}

private fun colorOf(n: JSONObject, key: String): Color? {
    val a = n.optJSONArray(key) ?: return null
    // A ground Swift names (a grouped list's, a cell's, a sheet's): the
    // Material role it is here.
    MaterialGrounds.named(n.optJSONObject("params")?.optString(if (key == "bg") "bgName" else key + "Name"))?.let { return it }
    return Color(
        a.optDouble(0, 0.0).toFloat(),
        a.optDouble(1, 0.0).toFloat(),
        a.optDouble(2, 0.0).toFloat(),
        a.optDouble(3, 1.0).toFloat(),
    )
}

/** Swift's named grounds in the Material roles they are on Android: a
 *  grouped list's ground is the container tone, a cell on it the lowest (the
 *  highest in the dark), a sheet's ground the low container. Set by the theme
 *  as it composes; null (the colours as Swift resolved them) elsewhere. */
object MaterialGrounds {
    @Volatile var scheme: ColorScheme? = null
    @Volatile var dark: Boolean = false

    /** The role for a ground's name ("groupedBackground", "@0.50" for an
     *  opacity), or null for a name that is not a ground. */
    fun named(spec: String?): Color? {
        if (spec.isNullOrEmpty()) return null
        val s = scheme ?: return null
        val parts = spec.split("@")
        val base = when (parts[0]) {
            "groupedBackground", "barBackground" -> s.surfaceContainer
            "secondaryBackground" -> if (dark) s.surfaceContainerHigh else s.surfaceContainerLowest
            "elevatedGroupedBackground" -> s.surfaceContainerLow
            "elevatedSecondaryBackground" -> if (dark) s.surfaceContainerHighest else s.surfaceContainerLowest
            else -> return null
        }
        val opacity = parts.getOrNull(1)?.toFloatOrNull() ?: 1f
        return base.copy(alpha = base.alpha * opacity)
    }
}

/** Shared decorations: size, shadow, corner clip, background, tap, padding. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
private fun baseModifier(n: JSONObject, extra: Modifier): Modifier {
    var m = extra
    // `.fixedSize`: the content at its ideal size on the fixed axes, however
    // little the parent offers.
    n.optJSONObject("params")?.optString("fixed")?.let { fixed ->
        if (fixed.contains("h")) m = m.wrapContentWidth(unbounded = true)
        if (fixed.contains("v")) m = m.wrapContentHeight(unbounded = true)
    }
    // `.offset` / `.scaleEffect`: drawn moved or scaled, as SwiftUI's are,
    // without changing the layout around them.
    if (n.has("offsetX") || n.has("offsetY") || n.has("scale")) {
        val dx = n.optDouble("offsetX", 0.0).toFloat()
        val dy = n.optDouble("offsetY", 0.0).toFloat()
        val scale = n.optDouble("scale", 1.0).toFloat()
        m = m.graphicsLayer {
            translationX = dx * density
            translationY = dy * density
            scaleX = scale
            scaleY = scale
        }
        // A hit target where it is drawn: Compose hands a pointer outside an
        // ancestor's bounds to that ancestor's gestures only when it lands on
        // a pointer node below it, and SwiftUI's gestures around an offset or
        // zoomed view take touches wherever the view is drawn.
        m = m.pointerInput(Unit) {}
    }
    // A drag and/or a pinch (`.gesture`), reported as SwiftUI's
    // simultaneous gesture sees them: the translation and the magnification
    // since the fingers went down.
    val dragID = n.optString("drag")
    val magnifyID = n.optJSONObject("params")?.optString("magnify") ?: ""
    if (dragID.isNotEmpty() || magnifyID.isNotEmpty()) m = m.guestGestures(dragID, magnifyID)
    // Accessibility: the label and value TalkBack reads, and
    // `.accessibilityElement(children:)` (merge the children into this node,
    // or replace them with its own description).
    n.optJSONObject("params")?.let { p ->
        val label = p.optString("a11yLabel").takeIf { p.has("a11yLabel") }
        val value = p.optString("a11yValue").takeIf { p.has("a11yValue") }
        when {
            p.optString("a11yHidden") == "1" -> m = m.clearAndSetSemantics { }
            p.optString("a11yChildren") == "ignore" -> m = m.clearAndSetSemantics {
                label?.let { contentDescription = it }
                value?.let { stateDescription = it }
            }
            p.optString("a11yChildren") == "combine" || label != null || value != null ->
                m = m.semantics(mergeDescendants = p.optString("a11yChildren") == "combine") {
                    label?.let { contentDescription = it }
                    value?.let { stateDescription = it }
                }
        }
        // `.accessibilityIdentifier`: a test tag, which UI Automator reads as
        // the node's resource-id (as XCUITest reads the identifier and the
        // web's tests data-testid).
        p.optString("a11yId").takeIf { it.isNotEmpty() }?.let { id ->
            m = m.semantics {
                testTagsAsResourceId = true
                testTag = id
            }
        }
    }
    // `.zIndex` (over its siblings) and `.blur(radius:)`.
    n.optJSONObject("params")?.optString("z")?.toFloatOrNull()?.let { m = m.zIndex(it) }
    n.optJSONObject("params")?.optString("blur")?.toFloatOrNull()?.let { if (it > 0) m = m.blur(it.dp) }
    // A Form's parts in Material's metrics: its rows a list item's 56dp at
    // the least, its groups' corners the large shape's.
    val formRole = n.optJSONObject("params")?.optString("form") ?: ""
    if (formRole == "row") m = m.defaultMinSize(minHeight = 56.dp)
    if (n.optBoolean("expandW")) m = m.fillMaxWidth()
    if (n.optBoolean("expandH")) m = m.fillMaxHeight()
    if (n.has("width")) m = m.width(n.optDouble("width").dp)
    if (n.has("height")) m = m.height(n.optDouble("height").dp)
    // Finite frame bounds (`.frame(minWidth:maxWidth:minHeight:maxHeight:)`,
    // the minW/maxW/minH/maxH params): the flexible frame clamped to them, as
    // SwiftUI and the other hosts do. A vertical scroll so capped (a composer's
    // suggestions) is measured within its cap; unbounded, Compose refuses it.
    n.optJSONObject("params")?.let { p ->
        fun bound(key: String) = p.optString(key).toFloatOrNull()?.dp ?: Dp.Unspecified
        if (p.has("minW") || p.has("maxW")) m = m.widthIn(min = bound("minW"), max = bound("maxW"))
        if (p.has("minH") || p.has("maxH")) m = m.heightIn(min = bound("minH"), max = bound("maxH"))
    }
    // `.aspectRatio(_:contentMode:)`: width from height or the reverse.
    n.optJSONObject("params")?.optString("aspect")?.toDoubleOrNull()?.let { ratio ->
        if (ratio > 0) m = m.aspectRatio(ratio.toFloat(), matchHeightConstraintsFirst = n.optJSONObject("params")?.optString("aspectMode") == "fill")
    }
    val radius = if (formRole == "card") 20.0 else n.optDouble("radius", 0.0)
    val shape = if (radius > 0) RoundedCornerShape(radius.dp) else RoundedCornerShape(0.dp)
    // Compose draws the full shadow silhouette even for transparent content,
    // which reads as a gray panel — only elevate nodes that paint a fill.
    if (n.has("bg") || n.has("gradient")) {
        n.optJSONObject("shadow")?.let { s ->
            m = m.shadow(
                elevation = (s.optDouble("radius", 4.0) / 2).dp,
                shape = shape,
                clip = false,
            )
        }
    }
    if (radius > 0) m = m.clip(shape)
    colorOf(n, "bg")?.let { m = m.background(it, shape) }
    val kind = n.optString("k")
    if (kind != "shape" && kind != "gradient") {
        // Gradient backgrounds (`.background(LinearGradient…)`); gradient
        // *nodes* paint themselves with their own shape in IsoNode.
        val brush = gradientBrush(n)
        if (n.optString("gradient").contains("\"material\"")) {
            // A `Material` fill behind a view: opaque here (Material has no
            // blur, and the web's translucent tint would leave the content
            // under it legible), with a hairline. (A dark tint is the dark
            // scheme's.)
            val tint = (brush as? androidx.compose.ui.graphics.SolidColor)?.value ?: Color.Gray
            val dark = tint.red + tint.green + tint.blue < 1.5f
            m = m.background(tint.copy(alpha = 1f), shape)
            m = m.border(1.dp, if (dark) Color.White.copy(alpha = 0.14f) else Color.Black.copy(alpha = 0.08f), shape)
        } else {
            brush?.let { m = m.background(it, shape) }
        }
    }
    // (A disabled button takes no press, and shows none.)
    n.optString("tap").takeIf { it.isNotEmpty() && n.optJSONObject("params")?.optString("disabled") != "1" }?.let { id ->
        m = if ((n.optJSONObject("params")?.optString("tapCount") ?: "") == "2") {
            // `onTapGesture(count: 2)`: a double tap.
            m.doubleTap(id)
        } else {
            m.clickable { sendEvent(id, "") } // ripple via MaterialTheme
        }
    }
    val p = n.optJSONArray("padding")
    if (p != null) {
        m = m.padding(
            top = p.optDouble(0, 0.0).dp,
            start = p.optDouble(1, 0.0).dp,
            bottom = p.optDouble(2, 0.0).dp,
            end = p.optDouble(3, 0.0).dp,
        )
    }
    if (n.has("opacity")) m = m.alpha(n.optDouble("opacity", 1.0).toFloat())
    return m
}

private fun children(n: UNode): List<UNode> = n.children

private fun alignH(n: JSONObject): Alignment.Horizontal = when (n.optString("alignH")) {
    "leading" -> Alignment.Start
    "trailing" -> Alignment.End
    else -> Alignment.CenterHorizontally
}

/** Whether a stack child takes a share of the leftover space along the
 *  stack's axis: a spacer, a scroll view, or an `.infinity` frame (expand),
 *  or a container holding one (a List inside a ScrollViewReader or a
 *  padding box is as greedy as the List) — not a node that is merely
 *  flexible because a shape sits inside it. The encoder's grow flag marks
 *  the subtrees worth looking into. */
private fun greedyChild(c: UNode, vertical: Boolean): Boolean {
    val j = c.json
    val kind = j.optString("k")
    if (kind == "spacer") return true
    if (kind == "scroll") return j.optString("axis") == (if (vertical) "v" else "h") || j.optBoolean(if (vertical) "expandH" else "expandW")
    if (j.optBoolean(if (vertical) "expandH" else "expandW")) return true
    if (j.has("height") && vertical || j.has("width") && !vertical) return false
    if (!j.optBoolean(if (vertical) "growH" else "growW")) return false
    // A GeometryReader takes all it is offered, on both axes.
    if (c.holdsReader) return true
    if (kind != "box" && kind != "stack") return false
    return c.children.any { child ->
        child.json.optJSONObject("params")?.has("layer") != true && greedyChild(child, vertical)
    }
}

/**
 * SwiftUI's HStack layout, not Compose's Row: the least flexible children
 * (a short label) take their size first, wrapping text takes what is left,
 * and spacers / greedy children share the remainder last — so a long
 * address next to a trailing tag wraps instead of pushing the tag out.
 */
/** One line cut at its head or in its middle (`.truncationMode`; a path
 *  reads "…/Developer/visor"): Compose 1.7 ellipsizes only at the end, so
 *  what is kept is measured, the most of the words that fit beside the
 *  ellipsis in the width there is. A layout of its own, not a
 *  BoxWithConstraints: a stack asks its children's intrinsic widths, which
 *  a subcomposition cannot answer (the app stopped there). Its least width
 *  is the ellipsis's, so a row gives it what is left, as SwiftUI does. */
@Composable
private fun EllipsizedLine(text: String, m: Modifier, style: TextStyle, mode: String) {
    val measurer = rememberTextMeasurer()
    val drawn = remember { mutableStateOf<TextLayoutResult?>(null) }
    val policy = remember(text, style, mode, measurer) {
        fun line(s: String) = measurer.measure(s, style, maxLines = 1, softWrap = false)
        // Never half a surrogate pair at a cut.
        fun tail(n: Int) = text.takeLast(n).let { if (it.firstOrNull()?.isLowSurrogate() == true) it.drop(1) else it }
        fun head(n: Int) = text.take(n).let { if (it.lastOrNull()?.isHighSurrogate() == true) it.dropLast(1) else it }
        fun cut(keep: Int) = if (mode == "head") "…" + tail(keep) else head((keep + 1) / 2) + "…" + tail(keep / 2)
        fun fit(max: Int): TextLayoutResult {
            val full = line(text)
            if (max == Constraints.Infinity || full.size.width <= max) return full
            var low = 0
            var high = text.length - 1
            while (low < high) {
                val mid = (low + high + 1) / 2
                if (line(cut(mid)).size.width <= max) low = mid else high = mid - 1
            }
            return line(cut(low))
        }
        object : MeasurePolicy {
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                val result = fit(constraints.maxWidth)
                drawn.value = result
                return layout(
                    result.size.width.coerceIn(constraints.minWidth, constraints.maxWidth),
                    result.size.height.coerceIn(constraints.minHeight, constraints.maxHeight),
                ) {}
            }
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                line("…").size.width
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
                line(text).size.width
            override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
                line(text).size.height
            override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<IntrinsicMeasurable>, width: Int) =
                line(text).size.height
        }
    }
    Layout(
        content = {},
        modifier = m
            .semantics { this.text = AnnotatedString(text) }
            .drawBehind { drawn.value?.let { drawText(it) } },
        measurePolicy = policy,
    )
}

@Composable
private fun IsoHStack(n: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val j = n.json
    val spacingPx = with(LocalDensity.current) { j.optDouble("spacing", 8.0).dp.roundToPx() }
    val vertical = j.optString("alignV")
    val children = n.children
    val greedy = children.map { c -> greedyChild(c, vertical = false) && bw }
    Layout(
        content = { for ((i, c) in children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, bw, bh) } },
        modifier = m,
    ) { measurables, constraints ->
        val count = measurables.size
        val gaps = if (count > 1) spacingPx * (count - 1) else 0
        val bounded = constraints.hasBoundedWidth
        var remaining = if (bounded) (constraints.maxWidth - gaps).coerceAtLeast(0) else Int.MAX_VALUE
        val placeables = arrayOfNulls<Placeable>(count)
        val childHeight = if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity
        // A spacer's minimum length is held back from everything else, as in
        // SwiftUI: a bubble after Spacer(minLength: 60) wraps 60 short of
        // the edge whether or not other greedy children share the row.
        val spacers = (0 until count).filter { greedy[it] && children[it].json.optString("k") == "spacer" }
        val held = if (bounded) spacers.sumOf { children[it].json.optDouble("min", 0.0).dp.roundToPx() }.coerceAtMost(remaining) else 0
        remaining -= held
        // Fixed and wrapping children, least flexible first.
        val flexible = (0 until count).filter { !greedy[it] }.sortedBy { i ->
            val mm = measurables[i]
            mm.maxIntrinsicWidth(childHeight) - mm.minIntrinsicWidth(childHeight)
        }
        var left = flexible.size
        for (i in flexible) {
            val proposal = if (bounded) remaining / left else Int.MAX_VALUE
            val pl = measurables[i].measure(Constraints(0, if (bounded) proposal.coerceAtLeast(0) else Constraints.Infinity, 0, childHeight))
            placeables[i] = pl
            if (bounded) remaining = (remaining - pl.width).coerceAtLeast(0)
            left -= 1
        }
        // Greedy children share what is left, spacers last: as in SwiftUI a
        // spacer yields to any other greedy child, keeping only its minimum
        // length (a bubble whose column holds a trailing Spacer beside a
        // leading Spacer(minLength: 60) spans all but 60, not half).
        val greedyIndices = (0 until count).filter { greedy[it] }
        val others = greedyIndices - spacers.toSet()
        fun share(indices: List<Int>) {
            if (indices.isEmpty()) return
            val each = if (bounded) remaining / indices.size else 0
            for (i in indices) {
                val pl = measurables[i].measure(Constraints(if (bounded) each else 0, if (bounded) each else Constraints.Infinity, 0, childHeight))
                placeables[i] = pl
            }
            if (bounded) remaining = (remaining - each * indices.size).coerceAtLeast(0)
        }
        share(others)
        remaining += held
        share(spacers)
        val width = if (constraints.hasBoundedWidth && (greedyIndices.isNotEmpty() || j.optBoolean("growW"))) constraints.maxWidth
            else (placeables.sumOf { it?.width ?: 0 } + gaps).coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = (placeables.maxOfOrNull { it?.height ?: 0 } ?: 0).coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(width, height) {
            var x = 0
            for (i in 0 until count) {
                val pl = placeables[i] ?: continue
                val y = when (vertical) { "top" -> 0; "bottom" -> height - pl.height; else -> (height - pl.height) / 2 }
                pl.placeRelative(x, y)
                x += pl.width + spacingPx
            }
        }
    }
}

/**
 * SwiftUI's `Grid`: every `GridRow`'s cells in columns shared by all rows.
 * A column is as wide as its widest cell when the grid fits; otherwise each
 * starts at its narrowest (the longest word of its text) and the rest of the
 * width is shared in proportion to how much wider each would like to be — a
 * browser's automatic table layout — so text wraps and its row grows taller.
 * Lines that are not rows (a divider) span the columns.
 */
@Composable
private fun IsoGrid(n: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val j = n.json
    val columns = j.optJSONObject("params")?.optString("grid")?.toIntOrNull()?.coerceAtLeast(1) ?: 1
    val lines = n.children
    val isRow = lines.map { it.json.optJSONObject("params")?.optString("gridRow") == "1" }
    val density = LocalDensity.current
    val firstRow = lines.indices.firstOrNull { isRow[it] }
    val hSpacing = with(density) { (firstRow?.let { lines[it].json.optDouble("spacing", 8.0) } ?: 8.0).dp.roundToPx() }
    val vSpacing = with(density) { j.optDouble("spacing", 8.0).dp.roundToPx() }
    // (line, column) per composed child; column -1 for a line spanning them all.
    val slots = buildList {
        for ((index, line) in lines.withIndex()) {
            if (isRow[index]) for (column in line.children.indices) add(index to column) else add(index to -1)
        }
    }
    Layout(
        content = {
            for ((index, column) in slots) key(index, column) {
                val node = if (column < 0) lines[index] else lines[index].children[column]
                IsoNode(node, Modifier, bw, bh)
            }
        },
        modifier = m,
    ) { measurables, constraints ->
        val narrowest = IntArray(columns)
        val widest = IntArray(columns)
        for ((k, slot) in slots.withIndex()) {
            val column = slot.second
            if (column !in 0 until columns) continue
            narrowest[column] = maxOf(narrowest[column], measurables[k].minIntrinsicWidth(Constraints.Infinity))
            widest[column] = maxOf(widest[column], measurables[k].maxIntrinsicWidth(Constraints.Infinity))
        }
        val gaps = hSpacing * (columns - 1)
        val widths = widest.copyOf()
        val wanted = widest.sum()
        if (constraints.hasBoundedWidth) {
            val offered = (constraints.maxWidth - gaps).coerceAtLeast(0)
            if (wanted > offered) {
                val least = narrowest.sum()
                for (c in 0 until columns) {
                    widths[c] = if (least >= offered) narrowest[c]
                        else narrowest[c] + ((widest[c] - narrowest[c]).toLong() * (offered - least) / (wanted - least)).toInt()
                }
            }
        }
        val gridWidth = widths.sum() + gaps
        val placeables = arrayOfNulls<Placeable>(slots.size)
        val lineHeights = IntArray(lines.size)
        for ((k, slot) in slots.withIndex()) {
            val (index, column) = slot
            val width = if (column < 0) gridWidth else if (column < columns) widths[column] else 0
            val pl = measurables[k].measure(Constraints(0, width, 0, Constraints.Infinity))
            placeables[k] = pl
            lineHeights[index] = maxOf(lineHeights[index], pl.height)
        }
        val height = lineHeights.sum() + vSpacing * (lines.size - 1).coerceAtLeast(0)
        val width = gridWidth.coerceIn(constraints.minWidth, constraints.maxWidth)
        layout(width, height.coerceIn(constraints.minHeight, constraints.maxHeight)) {
            val tops = IntArray(lines.size)
            var y = 0
            for (index in lines.indices) { tops[index] = y; y += lineHeights[index] + vSpacing }
            for ((k, slot) in slots.withIndex()) {
                val (index, column) = slot
                val pl = placeables[k] ?: continue
                val line = lines[index].json
                val slotWidth = if (column < 0) gridWidth else widths.getOrElse(column) { 0 }
                val left = if (column < 0) 0 else (0 until column).sumOf { widths[it] + hSpacing }
                val alignH = if (column < 0) j.optString("alignH") else line.optString("alignH")
                val alignV = line.optString("alignV")
                val x = left + when (alignH) { "leading" -> 0; "trailing" -> slotWidth - pl.width; else -> (slotWidth - pl.width) / 2 }
                val dy = when (alignV) { "top" -> 0; "bottom" -> lineHeights[index] - pl.height; else -> (lineHeights[index] - pl.height) / 2 }
                pl.placeRelative(x, tops[index] + dy)
            }
        }
    }
}

/** A shape node's `path` param (Shapes.swift: `M x y`, `L x y`, `Z`,
 *  `R x y w h`, `Q x y w h r`, `E x y w h`, in the unit square) as a Compose
 *  shape, scaled to the size it is given. */
private fun pathShape(text: String): androidx.compose.ui.graphics.Shape = androidx.compose.foundation.shape.GenericShape { size, _ ->
    val t = text.split(" ")
    var i = 0
    fun n(): Float = t[i++].toFloat()
    val w = size.width
    val h = size.height
    while (i < t.size) {
        when (t[i++]) {
            "M" -> moveTo(n() * w, n() * h)
            "L" -> lineTo(n() * w, n() * h)
            "Z" -> close()
            "R" -> { val x = n() * w; val y = n() * h; addRect(androidx.compose.ui.geometry.Rect(x, y, x + n() * w, y + n() * h)) }
            "Q" -> {
                val x = n() * w; val y = n() * h; val rw = n() * w; val rh = n() * h; val radius = n() * minOf(w, h)
                addRoundRect(androidx.compose.ui.geometry.RoundRect(x, y, x + rw, y + rh, androidx.compose.ui.geometry.CornerRadius(radius, radius)))
            }
            "E" -> { val x = n() * w; val y = n() * h; addOval(androidx.compose.ui.geometry.Rect(x, y, x + n() * w, y + n() * h)) }
            else -> return@GenericShape
        }
    }
}

/** A toolbar item: its symbol as an icon button (named by its title), else its words. */
@Composable
private fun IsoBarItem(title: String, symbol: String, label: String, prominent: Boolean = false, disabled: Boolean = false, onClick: () -> Unit) {
    val entry = if (symbol.isNotEmpty()) Symbols.table[symbol] else null
    // Material's: an icon button, or a text button with the words.
    if (entry != null) {
        val vector = remember(symbol, entry) { symbolVector(entry) }
        BarButton(onClick = onClick, icon = true, enabled = !disabled) { Icon(vector, contentDescription = label.ifEmpty { title }) }
    } else {
        BarButton(onClick = onClick, enabled = !disabled) {
            Text(title, fontWeight = if (prominent) FontWeight.Bold else FontWeight.Medium)
        }
    }
}

private fun alignV(n: JSONObject): Alignment.Vertical = when (n.optString("alignV")) {
    "top" -> Alignment.Top
    "bottom" -> Alignment.Bottom
    else -> Alignment.CenterVertically
}

private fun boxAlign(n: JSONObject): Alignment {
    val h = n.optString("alignH")
    val v = n.optString("alignV")
    return when {
        v == "top" && h == "leading" -> Alignment.TopStart
        v == "top" && h == "trailing" -> Alignment.TopEnd
        v == "top" -> Alignment.TopCenter
        v == "bottom" && h == "leading" -> Alignment.BottomStart
        v == "bottom" && h == "trailing" -> Alignment.BottomEnd
        v == "bottom" -> Alignment.BottomCenter
        h == "leading" -> Alignment.CenterStart
        h == "trailing" -> Alignment.CenterEnd
        else -> Alignment.Center
    }
}

/**
 * Renders one serialized node.
 *
 * [boundedH]/[boundedW] track whether the incoming constraints are finite
 * along each axis: `Modifier.weight` is illegal under infinite constraints
 * (inside a scroll container), so greedy children fall back to wrap-content
 * there — the scroll axis provides the space instead.
 */
@Composable
fun IsoNode(
    n: UNode,
    extra: Modifier,
    boundedW: Boolean = true,
    boundedH: Boolean = true,
) {
    val j = n.json
    // `.textSelection`: the text inside is selectable (a SelectionContainer:
    // long press selects a range, with Copy) or not (DisableSelection), an
    // inner one overriding an outer one. The container takes the node's
    // place in its parent (its parent data, its weight); the node is drawn
    // inside it.
    val select = j.optJSONObject("params")?.optString("select") ?: ""
    if (select.isNotEmpty() && LocalSelectionApplied.current !== n) {
        CompositionLocalProvider(LocalSelectionApplied provides n) {
            if (select == "1") {
                SelectionContainer(extra) { IsoNode(n, Modifier, boundedW, boundedH) }
            } else {
                DisableSelection { IsoNode(n, extra, boundedW, boundedH) }
            }
        }
        return
    }
    var m = baseModifier(j, extra)
    // `.id(_:)` inside a scroll: where a ScrollViewProxy request finds it.
    val vid = j.optJSONObject("params")?.optString("vid") ?: ""
    val targets = LocalScrollTargets.current
    if (vid.isNotEmpty() && targets != null) m = m.onGloballyPositioned { targets[vid] = it }
    // A fixed dimension re-bounds the subtree even inside a scroller.
    val bw = boundedW || j.has("width")
    val bh = boundedH || j.has("height")
    when (j.optString("k")) {
        "stack" -> when (j.optString("axis")) {
            "h" -> IsoHStack(n, m, bw, bh)
            "z" -> Box(m, contentAlignment = boxAlign(j)) {
                for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
            }
            else -> if ((j.optJSONObject("params")?.optString("grid") ?: "").isNotEmpty()) {
                IsoGrid(n, m, bw, bh)
            } else if (n.children.size == 2 && (j.optJSONObject("params")?.optString("inset") ?: "").isNotEmpty()) {
                IsoInsetStack(n, m, bw, bh)
            } else Column(
                m,
                verticalArrangement = Arrangement.spacedBy(j.optDouble("spacing", 8.0).dp),
                horizontalAlignment = alignH(j),
            ) {
                for ((i, c) in n.children.withIndex()) key(childKey(c, i)) {
                    // Only the truly greedy share the leftover (a spacer, a
                    // scroll, an .infinity frame); a row that merely holds a
                    // shape keeps its content height — measured without a
                    // height bound so, past the bottom, it overflows the way
                    // SwiftUI's does instead of being squeezed.
                    val greedy = greedyChild(c, vertical = true) && bh
                    IsoNode(c, if (greedy) Modifier.weight(1f) else Modifier.wrapContentHeight(align = Alignment.Top, unbounded = true), bw, bh)
                }
            }
        }
        "text" -> {
            // An `Image(systemName:)` is a text node carrying its symbol
            // name: drawn from the portable table (Symbols.kt) at the text's
            // size; unknown names keep the guest's fallback glyph.
            val symbol = j.optJSONObject("params")?.optString("symbol") ?: ""
            val entry = if (symbol.isNotEmpty()) Symbols.table[symbol] else null
            if (entry != null) {
                val size = (j.optDouble("size", 17.0) * 1.15).dp
                val tint = onSelection(colorOf(j, "color") ?: Color.Black)
                val secondary = hexColorOf(j.optJSONObject("params")?.optString("symbol2") ?: "")
                if (secondary != null && entry.inner.isNotEmpty()) {
                    // `.foregroundStyle(_:_:)`: the badge in the secondary
                    // style, its glyph in the primary (one tint can't do both).
                    val vector = remember(symbol, entry, tint, secondary) { symbolVector(entry, tint, secondary) }
                    Image(vector, contentDescription = null, modifier = m.size(size))
                } else if (entry.filled && entry.inner.isNotEmpty()) {
                    // A filled badge's glyph is cut out of it (an SF symbol's
                    // `.fill`): drawn in what is behind it, which a tint over
                    // the whole icon would paint over.
                    // (A row drawing its own ground leaves its segment clear:
                    // the ground a grouped row has, then.)
                    val row = LocalRowContainer.current
                    val behind = when {
                        row.isSpecified && row.alpha > 0f -> row
                        row.isSpecified -> groupedRowContainer()
                        else -> MaterialTheme.colorScheme.background
                    }
                    val vector = remember(symbol, entry, tint, behind) { symbolVector(entry, behind, tint) }
                    Image(vector, contentDescription = null, modifier = m.size(size))
                } else {
                    val vector = remember(symbol, entry) { symbolVector(entry) }
                    Icon(vector, contentDescription = null, tint = tint, modifier = m.size(size))
                }
            } else {
                val params = j.optJSONObject("params")
                val runs = params?.optString("runs") ?: ""
                // `.minimumScaleFactor`: Compose 1.7 has no auto-size, so a
                // text that overflows is drawn again smaller, down to it.
                val minScale = params?.optString("minScale")?.toFloatOrNull()?.coerceIn(0.01f, 1f)
                var scale by remember(j.optString("v"), minScale) { mutableStateOf(1f) }
                // The width it was last made smaller at: given more (a
                // rotation), it starts again from its full size.
                var shrunkAt by remember(j.optString("v"), minScale) { mutableStateOf(Int.MAX_VALUE) }
                val style = TextStyle(
                    fontSize = (j.optDouble("size", 17.0) * scale).sp,
                    fontWeight = FontWeight(j.optInt("weight", 400)),
                    color = onSelection(colorOf(j, "color") ?: Color.Black),
                    fontFamily = textFontFamily(params),
                    // `.monospacedDigit()`: tabular figures.
                    fontFeatureSettings = if (params?.optString("tnum") == "1") "tnum" else null,
                )
                val shrink: (TextLayoutResult) -> Unit = { layout ->
                    val width = layout.layoutInput.constraints.maxWidth
                    if (minScale != null && scale < 1f && width > shrunkAt) {
                        scale = 1f
                        shrunkAt = Int.MAX_VALUE
                    } else if (minScale != null && layout.hasVisualOverflow && scale > minScale) {
                        scale = maxOf(minScale, scale * 0.9f)
                        shrunkAt = width
                    }
                }
                val maxLines = if (j.has("lines")) j.optInt("lines") else Int.MAX_VALUE
                val truncation = params?.optString("truncation") ?: ""
                if (maxLines == 1 && runs.isEmpty() && (truncation == "head" || truncation == "middle")) {
                    EllipsizedLine(j.optString("v"), m, style, truncation)
                } else if (runs.isNotEmpty()) {
                    Text(styledRuns(j.optString("v"), runs), m, style = style, maxLines = maxLines, overflow = TextOverflow.Ellipsis, onTextLayout = shrink)
                } else {
                    Text(j.optString("v"), m, style = style, maxLines = maxLines, overflow = TextOverflow.Ellipsis, onTextLayout = shrink)
                }
            }
        }
        "spacer" -> Spacer(m.size(j.optDouble("min", 0.0).dp))
        "divider" -> HorizontalDivider(m.fillMaxWidth())
        "scroll" -> {
            val horizontal = j.optString("axis") == "h"
            if (horizontal) {
                // `.scrollDisabled(true)`: laid out the same, not scrollable.
                val scrollEnabled = j.optJSONObject("params")?.optString("scrollDisabled") != "1"
                Row(m.horizontalScroll(rememberScrollState(), enabled = scrollEnabled), verticalAlignment = Alignment.CenterVertically) {
                    CompositionLocalProvider(LocalInScroll provides true) {
                        for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, boundedW = false, boundedH = bh) }
                    }
                }
            } else {
                IsoVerticalScroll(n, m, bw)
            }
        }
        "image" -> IsoImage(j.optString("src"), j.optBoolean("remote"), j.optBoolean("fit"), m,
            resizable = j.optBoolean("resizable") && !j.has("width") && !j.has("height"))
        "textField" -> IsoTextField(
            id = j.optString("id"),
            value = j.optString("v"),
            placeholder = j.optString("placeholder"),
            editID = j.optString("edit"),
            search = false,
            modifier = j.optJSONObject("params")?.optString("keys")?.takeIf { it.isNotEmpty() }
                ?.let { keys -> m.onPreviewKeyEvent { keyPress(keys, it, j.optJSONObject("params")?.optString("keyUp") == "1") } }
                ?: m,
            plain = j.optJSONObject("params")?.optString("fieldStyle") == "plain",
            maxLines = j.optJSONObject("params")?.optString("maxLines")?.toIntOrNull() ?: 1,
            focusID = j.optJSONObject("params")?.optString("focusId") ?: "",
            focusWanted = j.optJSONObject("params")?.optString("focus") == "1",
            secure = j.optJSONObject("params")?.optString("secure") == "1",
            selectionID = j.optJSONObject("params")?.optString("selId") ?: "",
            selectionRequest = j.optJSONObject("params")?.optString("sel") ?: "",
            submitID = j.optJSONObject("params")?.optString("submit") ?: "",
            editor = j.optJSONObject("params")?.optString("editor") == "1",
        )
        "slider" -> Slider(
            value = j.optDouble("v", 0.0).toFloat(),
            onValueChange = { sendEvent(j.optString("edit"), it.toString()) },
            modifier = m.fillMaxWidth(),
        )
        "progress" -> if (j.has("v")) {
            // `.tint`: the bar's fill (Material's track and shape otherwise).
            val tint = hexColorOf(j.optJSONObject("params")?.optString("tint") ?: "")
            LinearProgressIndicator(
                progress = { j.optDouble("v", 0.0).toFloat() },
                modifier = m.fillMaxWidth(),
                color = tint ?: ProgressIndicatorDefaults.linearColor,
            )
        } else {
            // Its own layer: the spinner redraws every frame, and without
            // one each frame re-records everything that shares its layer (a
            // whole transcript around a status row's spinner).
            if (j.optDouble("opacity", 1.0) <= 0.0) {
                // Hidden but holding its place: the same room, no animation
                // (an invisible indicator still ticks every frame).
                Box(m.size(28.dp))
            } else {
                CircularProgressIndicator(m.size(28.dp).graphicsLayer())
            }
        }
        "shape", "gradient" -> {
            // `.trim` on a stroked circle: the arc of a ring.
            val trim = j.optJSONObject("params")?.optString("trim") ?: ""
            val strokeColor = colorOf(j, "stroke")
            if (trim.isNotEmpty() && j.optString("shape") == "circle" && strokeColor != null) {
                val parts = trim.split(",").mapNotNull { it.toFloatOrNull() }
                val from = parts.getOrElse(0) { 0f }
                val to = parts.getOrElse(1) { 1f }
                val width = j.optDouble("strokeWidth", 1.0).toFloat()
                Canvas(m) {
                    val inset = width / 2
                    drawArc(
                        color = strokeColor,
                        startAngle = 360f * from,
                        sweepAngle = 360f * (to - from).coerceIn(0f, 1f),
                        useCenter = false,
                        topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
                        size = androidx.compose.ui.geometry.Size(size.width - width, size.height - width),
                        style = Stroke(width = width, cap = StrokeCap.Round),
                    )
                }
                return
            }
            val custom = j.optJSONObject("params")?.optString("path") ?: ""
            val shape = when {
                // An app's own shape: its path in the unit square, scaled to the box.
                custom.isNotEmpty() -> pathShape(custom)
                j.optString("shape") == "circle" -> CircleShape
                j.optString("shape") == "capsule" -> RoundedCornerShape(50)
                else -> RoundedCornerShape(j.optDouble("radius", 0.0).dp)
            }
            // A material fill (`.thinMaterial`, `.glassEffect`): an opaque
            // tonal surface (MaterialChrome.kt).
            val gradient = j.optString("gradient")
            val tint = (gradientBrush(j) as? androidx.compose.ui.graphics.SolidColor)?.value
            if (gradient.contains("\"material\"") && tint != null) {
                MaterialSurface(shape, tint, modifier = m) {
                    for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, bw, bh) }
                }
                return
            }
            var box = m
            colorOf(j, "fill")?.let { box = box.background(it, shape) }
            gradientBrush(j)?.let { brush -> box = box.background(brush, shape) }
            Box(box, contentAlignment = Alignment.Center) {
                for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, bw, bh) }
            }
        }
        "hostView" -> when (j.optString("view")) {
            "navstack" -> IsoNavStack(n, m, bw, bh)
            "navsplit" -> IsoNavSplit(n, m, bw, bh)
            "tabs" -> IsoTabs(n, m, bw, bh)
            "menu" -> IsoMenu(n, m)
            else -> IsoHostView(j, m)
        }
        "presentation" -> IsoPresentation(n)
        else -> {
            // Semantic list rows carry a `cell` role instead of baked-in
            // chrome — Material row metrics + a hairline separator.
            val params = j.optJSONObject("params") ?: JSONObject()
            val cell = params.optString("cell")
            val place = LocalRowPlace.current
            if (cell == "row" && place != null) {
                // A grouped list's row, as Material 3 draws a list in groups
                // (Android's Settings): rows a little apart in a rounded
                // group, its ends rounded more, on the list's ground; the
                // selected row in the secondary container.
                GroupedRow(n, m, params, place, bw, bh)
            } else if (cell == "header" && place != null) {
                // A group's title, over its rows and in line with their
                // text; a section without one is the space between groups.
                val empty = n.children.all { it.json.optString("k") == "box" && it.children.isEmpty() }
                if (empty) Spacer(m.height(16.dp))
                else Box(m.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = if (place.first) 0.dp else 8.dp)) {
                    for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
                }
            } else if (cell == "footer" && place != null) {
                // A group's footer: under it, in line with its rows' text.
                Box(m.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 4.dp)) {
                    for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
                }
            } else if (cell == "row" && LocalSidebarList.current) {
                SidebarListRow(n, m, params, bw, bh)
            } else if (cell == "row") {
                // (A row with a view behind it draws its own selection.)
                val selected = params.optString("selected") == "1" && params.optString("rowOwnBg") != "1"
                val tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
                val rowModifier = if (selected) m.fillMaxWidth().background(tint) else m.fillMaxWidth()
                // The platform's row metrics, unless the app set its own:
                // `.listRowInsets` on the row ("top,leading,bottom,trailing"),
                // `\.defaultMinListRowHeight` on the list.
                val rowPadding = rowInsetsPadding(params, 11f, 16f)
                // A swipe row slides the whole cell on the list's own ground
                // (a sidebar's grey, the page's): it takes the padding. With
                // Material's surface and inside the padding, its content stood
                // in a lighter box on a sidebar's ground.
                val swipes = n.children.singleOrNull()?.json?.optJSONObject("params")?.optString("swipe")?.isNotEmpty() == true
                val ground = pageGround()
                CompositionLocalProvider(
                    LocalRowContainer provides (if (selected) tint.compositeOver(ground) else ground),
                    LocalSwipePadding provides (if (swipes) rowPadding else PaddingValues(0.dp)),
                ) {
                Column(rowModifier) {
                    Box(
                        Modifier.fillMaxWidth()
                            .defaultMinSize(minHeight = LocalListMinRowHeight.current.dp)
                            .then(if (swipes) Modifier else Modifier.padding(rowPadding)),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
                    }
                    // SwiftUI's separators: hidden for the row
                    // (`.listRowSeparator(.hidden)`) or the whole list.
                    if (LocalListSeparators.current && params.optString("noSeparator") != "1") {
                        Box(
                            Modifier.fillMaxWidth().height(1.dp)
                                .background(MaterialTheme.colorScheme.outlineVariant))
                    }
                }
                }
            } else if (params.has("swipe") && params.optString("swipe").isNotEmpty()) {
                IsoSwipeRow(n, m, bw, bh)
            } else if (params.has("ctxmenu") && params.optString("ctxmenu").isNotEmpty()) {
                IsoContextMenuBox(n, m, bw, bh)
            } else {
                // A GeometryReader wrapper: report the size Compose lays out
                // ("<w>x<h>" in dp on the `.geo` id) so the guest rebuilds
                // the reader's content against its CONTAINER, not the canvas.
                // Deduped per composition; a same-size re-report after a
                // remount yields an identical tree (empty patch) and settles.
                var mm = m
                val geo = j.optJSONObject("params")?.optString("geo") ?: ""
                if (geo.isNotEmpty()) {
                    val density = LocalDensity.current.density
                    val lastSent = remember(geo) { arrayOf("") }
                    // And where it is in the window ("@<x>,<y>", for
                    // `frame(in: .global)`), outside a scroll only: inside
                    // one it moves with every frame of a scroll, and the
                    // reader would be built again for each.
                    val inScroll = LocalInScroll.current
                    mm = mm.onGloballyPositioned { coordinates ->
                        val w = (coordinates.size.width / density).toInt()
                        val h = (coordinates.size.height / density).toInt()
                        if (w > 0 && h > 0) {
                            val place = if (inScroll) "" else coordinates.positionInWindow().let {
                                "@${(it.x / density).toInt()},${(it.y / density).toInt()}"
                            }
                            val value = "${w}x${h}$place"
                            if (lastSent[0] != value) {
                                lastSent[0] = value
                                sendEvent(geo, value)
                            }
                        }
                    }
                }
                val fits = j.optJSONObject("params")?.optString("fits") ?: ""
                // `.background(view)` / `.overlay(view)` layers ride alongside
                // the content: behind or over it, sized to the box, placed by
                // their own alignment.
                val layered = n.children.any { it.json.optJSONObject("params")?.optString("layer")?.isNotEmpty() == true }
                if (fits.isNotEmpty()) {
                    IsoFitsBox(n, mm, fits, bw, bh)
                } else if (layered) {
                    val content = n.children.filter { it.json.optJSONObject("params")?.optString("layer").isNullOrEmpty() }
                    val backgrounds = n.children.filter { it.json.optJSONObject("params")?.optString("layer") == "background" }
                    val overlays = n.children.filter { it.json.optJSONObject("params")?.optString("layer") == "overlay" }
                    // `.mask(alignment:_:)`: the box drawn offscreen, then
                    // kept only where the mask's layer draws (DstIn).
                    val masks = n.children.filter { it.json.optJSONObject("params")?.optString("layer") == "mask" }
                    val composited = if (masks.isEmpty()) mm
                        else mm.graphicsLayer(compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen)
                    Box(composited, contentAlignment = boxAlign(j)) {
                        for (c in backgrounds) IsoLayer(c, bw, bh)
                        for (c in content) IsoNode(c, boxChildModifier(c), bw, bh)
                        for (c in overlays) IsoLayer(c, bw, bh)
                        for (c in masks) Box(Modifier.matchParentSize().drawWithContent {
                            val keep = androidx.compose.ui.graphics.Paint().apply { blendMode = androidx.compose.ui.graphics.BlendMode.DstIn }
                            drawIntoCanvas { it.saveLayer(androidx.compose.ui.geometry.Rect(0f, 0f, size.width, size.height), keep) }
                            drawContent()
                            drawIntoCanvas { it.restore() }
                        }) { IsoLayer(c, bw, bh) }
                    }
                } else {
                    Box(mm, contentAlignment = boxAlign(j)) {
                        for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
                    }
                }
            }
        }
    }
}

/** `ViewThatFits`: the box's children are the candidates; it shows the first
 *  whose ideal size (its max intrinsic width or height) fits the space
 *  offered along the axes given ("h", "v", "hv"), else the last, and is that
 *  view's size, as SwiftUI's is. Intrinsics rather than a measure without
 *  bounds: a horizontal scroll (a carousel, the usual last candidate) can't
 *  be measured unbounded. Only the chosen one is measured and placed. */
@Composable
private fun IsoFitsBox(n: UNode, m: Modifier, axes: String, bw: Boolean, bh: Boolean) {
    val horizontal = 'h' in axes
    val vertical = 'v' in axes
    val alignment = boxAlign(n.json)
    Layout(
        modifier = m,
        content = { for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) } },
    ) { measurables, constraints ->
        if (measurables.isEmpty()) return@Layout layout(constraints.minWidth, constraints.minHeight) {}
        var chosen = measurables.lastIndex
        for (i in 0 until measurables.lastIndex) {
            val candidate = measurables[i]
            val fitsWidth = !horizontal || !constraints.hasBoundedWidth ||
                candidate.maxIntrinsicWidth(if (constraints.hasBoundedHeight) constraints.maxHeight else Constraints.Infinity) <= constraints.maxWidth
            val fitsHeight = !vertical || !constraints.hasBoundedHeight ||
                candidate.maxIntrinsicHeight(if (constraints.hasBoundedWidth) constraints.maxWidth else Constraints.Infinity) <= constraints.maxHeight
            if (fitsWidth && fitsHeight) {
                chosen = i
                break
            }
        }
        val placeable = measurables[chosen].measure(constraints.copy(minWidth = 0, minHeight = 0))
        val width = placeable.width.coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = placeable.height.coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(width, height) {
            placeable.place(alignment.align(IntSize(placeable.width, placeable.height), IntSize(width, height), layoutDirection))
        }
    }
}

/** A decoration layer inside its box: fills it when greedy (a backdrop, a
 *  stroked border), else sits at its `layerAlign` ("h,v" of start/center/end). */
@Composable
private fun BoxScope.IsoLayer(c: UNode, bw: Boolean, bh: Boolean) {
    val parts = (c.json.optJSONObject("params")?.optString("layerAlign") ?: "center,center").split(",")
    val h = parts.getOrNull(0) ?: "center"
    val v = parts.getOrNull(1) ?: "center"
    val alignment = when (v) {
        "start" -> when (h) { "start" -> Alignment.TopStart; "end" -> Alignment.TopEnd; else -> Alignment.TopCenter }
        "end" -> when (h) { "start" -> Alignment.BottomStart; "end" -> Alignment.BottomEnd; else -> Alignment.BottomCenter }
        else -> when (h) { "start" -> Alignment.CenterStart; "end" -> Alignment.CenterEnd; else -> Alignment.Center }
    }
    // As SwiftUI's: offered the box's size, never changing it. The layer
    // sits in a box matching its parent's size (a Box keeps one child
    // datum, so `align` and `matchParentSize` cannot share a node), placed
    // there by its alignment; a filling layer measured as an ordinary
    // child would grow to the parent's whole offer and stretch the box.
    val m: Modifier = when {
        c.json.optBoolean("growW") && c.json.optBoolean("growH") -> Modifier.fillMaxSize()
        c.json.optBoolean("growW") -> Modifier.fillMaxWidth()
        c.json.optBoolean("growH") -> Modifier.fillMaxHeight()
        else -> Modifier
    }
    // A view its alignment guide moved out of the box floats above the
    // screen's bars (param "float"; a menu floated above a composer): the
    // bars are drawn over the content, so it is drawn in a popup, a window
    // of its own above the app's, at the box's place by the layer's
    // alignment (its offset then moves it out). Not focusable, so the field
    // keeps the keyboard, and it takes the taps on it.
    if (c.json.optJSONObject("params")?.optString("float") == "1") {
        // The popup is a window as large as the view: the view's offset (its
        // guide's) moves the window, not the drawing in it, which the window
        // would clip.
        val density = LocalDensity.current.density
        val moved = IntOffset(
            (c.json.optDouble("offsetX", 0.0) * density).roundToInt(),
            (c.json.optDouble("offsetY", 0.0) * density).roundToInt())
        val unmoved = remember(c) {
            val names = c.json.keys().asSequence().filter { it != "offsetX" && it != "offsetY" }.toList().toTypedArray()
            UNode(JSONObject(c.json, names), c.children, c.sig)
        }
        Box(Modifier.matchParentSize()) {
            Popup(alignment = alignment, offset = moved, properties = PopupProperties(focusable = false, clippingEnabled = false)) {
                IsoNode(unmoved, m, bw, bh)
            }
        }
        return
    }
    Box(Modifier.matchParentSize(), contentAlignment = alignment) { IsoNode(c, m, bw, bh) }
}

/** Greedy children of a Box stretch to fill it (no-ops when unbounded). */
private fun boxChildModifier(c: UNode): Modifier {
    var m: Modifier = Modifier
    val kind = c.json.optString("k")
    // A shape, gradient, scroll or spacer fills its box, and so does what
    // holds a GeometryReader (it takes all it is offered); other children
    // fill it only when they ask to (an `.infinity` frame), not because a
    // shape sits somewhere inside them.
    val fills = kind == "shape" || kind == "gradient" || kind == "scroll" || kind == "spacer" || c.holdsReader
    if (c.json.optBoolean("expandW") || (fills && c.json.optBoolean("growW"))) m = m.fillMaxWidth()
    if (c.json.optBoolean("expandH") || (fills && c.json.optBoolean("growH"))) m = m.fillMaxHeight()
    return m
}

@Composable
private fun IsoImage(source: String, remote: Boolean, fit: Boolean, m: Modifier, resizable: Boolean = false) {
    // Read imageTick HERE so this leaf subscribes to it directly: when an async
    // load completes the tick bumps and this composable re-queries the cache
    // even if its parent IsoNode skipped (unchanged node identity).
    @Suppress("UNUSED_VARIABLE") val tick = ComposeTreeState.imageTick.value
    HostServices.imageBitmap(source, remote)?.let { bitmap ->
        // `.resizable()` with `.aspectRatio(contentMode: .fit)`: the picture
        // takes the room it is offered at its own proportions, as SwiftUI's
        // does, rather than its pixel size.
        val sized = if (resizable && fit && bitmap.height > 0) {
            m.aspectRatio(bitmap.width.toFloat() / bitmap.height.toFloat())
        } else {
            m
        }
        Image(
            bitmap.asImageBitmap(),
            contentDescription = source,
            modifier = sized,
            contentScale = if (fit) ContentScale.Fit else ContentScale.Crop,
        )
    } ?: Spacer(m.size(24.dp))
}

/**
 * Text input with focus-local state: while focused the field owns the text
 * (Swift re-renders would otherwise reset the caret); when unfocused it
 * follows the serialized value.
 */
@Composable
private fun IsoTextField(
    id: String,
    value: String,
    placeholder: String,
    editID: String,
    search: Boolean,
    modifier: Modifier,
    eventPrefix: String = "",
    plain: Boolean = false,
    maxLines: Int = 1,
    focusID: String = "",
    focusWanted: Boolean = false,
    secure: Boolean = false,
    selectionID: String = "",
    selectionRequest: String = "",
    submitID: String = "",
    editor: Boolean = false,
) {
    // A `TextEditor` has as many lines as it is given room for; a TextField
    // has one unless its axis is vertical.
    val multiline = editor || maxLines > 1
    val lines = if (editor) Int.MAX_VALUE else maxLines.coerceAtLeast(1)
    // `.onSubmit`: a field of one line submits with the keyboard's action key
    // (Done, Search in a search field). A field of several lines keeps its
    // Enter for new lines, as iOS's does.
    val submits = submitID.isNotEmpty() && !multiline
    val action = if (!submits) ImeAction.Default else if (search) ImeAction.Search else ImeAction.Done
    // A `SecureField`: masked as it is typed, the password keyboard.
    val masking = if (secure) PasswordVisualTransformation() else VisualTransformation.None
    val keys = if (secure) KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = action) else KeyboardOptions(imeAction = action)
    // `.focused($state)`: the guest's wish drives focus (and the keyboard);
    // focus changes go back to it.
    val requester = remember(id) { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var hasFocus by remember(id) { mutableStateOf(false) }
    LaunchedEffect(focusID, focusWanted) {
        if (focusID.isEmpty()) return@LaunchedEffect
        if (focusWanted && !hasFocus) {
            requester.requestFocus()
            keyboard?.show()
        } else if (!focusWanted && hasFocus) {
            focusManager.clearFocus()
        }
    }
    val modifier = if (focusID.isEmpty()) modifier else modifier
        .focusRequester(requester)
        .onFocusChanged { state ->
            if (state.isFocused == hasFocus) return@onFocusChanged
            hasFocus = state.isFocused
            if (state.isFocused != focusWanted) sendEvent(focusID, if (state.isFocused) "1" else "0")
        }
    // TextFieldValue (not a plain String) so the caret survives the
    // recomposition that follows every keystroke's round trip through Swift.
    var local by remember(id) {
        mutableStateOf(
            androidx.compose.ui.text.input.TextFieldValue(
                value, androidx.compose.ui.text.TextRange(value.length)))
    }
    // Reconciliation: texts this field sent that haven't echoed back yet, and
    // the last serialized value reconciled against. A NEW serialized value
    // that matches local (or an in-flight send) is just our own keystroke
    // echoing back — keep the caret. Anything else is a PROGRAMMATIC guest
    // change (a chat composer clearing its draft on send, a formatter) and
    // must win immediately, focused or not — otherwise the stale local text
    // rides back into guest state on the next keystroke.
    val pending = remember(id) { ArrayDeque<String>() }
    var lastSerialized by remember(id) { mutableStateOf(value) }
    if (value != lastSerialized) {
        lastSerialized = value
        if (value == local.text) {
            pending.clear()
        } else {
            val echo = pending.indexOf(value)
            if (echo >= 0) {
                repeat(echo + 1) { pending.removeFirst() }
            } else {
                local = androidx.compose.ui.text.input.TextFieldValue(
                    value, androidx.compose.ui.text.TextRange(value.length))
                pending.clear()
            }
        }
    }
    // `TextField(_:text:selection:)`: the field's selection goes to the guest
    // (selectionID, "start,end" in UTF-16 units, as Compose counts them), and
    // one the app set ("start,end,request") is shown once per request while
    // the field holds the guest's text (typing since wins over it).
    var reportedSelection by remember(id) { mutableStateOf("") }
    var shownRequest by remember(id) { mutableStateOf(0) }
    selectionRequest.split(",").mapNotNull { it.toIntOrNull() }.takeIf { it.size == 3 }?.let { (start, end, request) ->
        if (request > shownRequest) {
            shownRequest = request
            if (value == local.text) {
                val range = androidx.compose.ui.text.TextRange(start.coerceIn(0, value.length), end.coerceIn(0, value.length))
                local = local.copy(selection = range)
                reportedSelection = "${range.min},${range.max}"
            }
        }
    }
    val edited: (androidx.compose.ui.text.input.TextFieldValue) -> Unit = {
        val textChanged = it.text != local.text
        local = it
        if (textChanged) {
            pending.addLast(it.text)
            sendEvent(editID, eventPrefix + it.text)
        }
        if (selectionID.isNotEmpty()) {
            val selection = "${it.selection.min},${it.selection.max}"
            if (selection != reportedSelection) {
                reportedSelection = selection
                sendEvent(selectionID, selection)
            }
        }
    }
    val submit = {
        sendEvent(submitID, "")
        keyboard?.hide()
    }
    val actions = if (submits) KeyboardActions(onAny = { submit() }) else KeyboardActions.Default
    // Return on a hardware keyboard: in a field of one line it submits; in a
    // field of several, Shift-Return is a new line as Return is, as on
    // Apple's platforms and in Android's EditText (Compose's field takes
    // only a bare Enter for one and drops it). An app's own onKeyPress (on
    // the node, outside this) sees the key first.
    val fieldModifier = if (!multiline && !submits) modifier else modifier.onPreviewKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown || (event.key != Key.Enter && event.key != Key.NumPadEnter))
            return@onPreviewKeyEvent false
        if (!multiline) {
            submit()
        } else {
            if (!event.isShiftPressed) return@onPreviewKeyEvent false
            val at = local.selection
            edited(androidx.compose.ui.text.input.TextFieldValue(
                local.text.replaceRange(at.min, at.max, "\n"), androidx.compose.ui.text.TextRange(at.min + 1)))
        }
        true
    }.then(if (editor) Modifier.fillMaxHeight() else Modifier)
    if (plain) {
        // `.textFieldStyle(.plain)`: just the text (the app draws the bubble).
        BasicTextField(
            value = local,
            onValueChange = edited,
            modifier = fieldModifier.fillMaxWidth(),
            singleLine = !multiline,
            maxLines = lines,
            visualTransformation = masking,
            keyboardOptions = keys,
            keyboardActions = actions,
            textStyle = TextStyle(fontSize = 16.sp, color = LocalContentColor.current),
            decorationBox = { inner ->
                Box {
                    if (local.text.isEmpty()) Text(placeholder, fontSize = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    inner()
                }
            },
        )
        return
    }
    OutlinedTextField(
        value = local,
        onValueChange = edited,
        modifier = fieldModifier.fillMaxWidth(),
        placeholder = { Text(placeholder, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        leadingIcon = if (search) {
            { Icon(Icons.Filled.Search, contentDescription = null) }
        } else {
            null
        },
        singleLine = !multiline,
        maxLines = lines,
        visualTransformation = masking,
        keyboardOptions = keys,
        keyboardActions = actions,
        shape = RoundedCornerShape(12.dp),
        textStyle = TextStyle(fontSize = 16.sp),
    )
}

/** Semantic tabs: the selected tab's content over the Material bottom
 *  navigation bar (the existing tabbar rendering, fed the same params). */
@Composable
private fun IsoTabs(node: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val j = node.json
    Column(m.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            // The tab bar below takes the bottom safe area (Material's bar
            // pads for the navigation bar itself).
            CompositionLocalProvider(LocalSafeArea provides LocalSafeArea.current.copy(bottom = 0.dp)) {
                for (c in node.children) IsoNode(c, Modifier.fillMaxSize(), bw, bh)
            }
        }
        val bar = JSONObject()
            .put("view", "tabbar")
            .put("edit", j.optString("edit"))
            .put("v", j.optString("v"))
            .put("params", j.optJSONObject("params") ?: JSONObject())
        IsoHostView(bar, Modifier)
    }
}

/** `Menu`: its label (the app's own view — a symbol, an avatar — or its
 *  words), and its buttons in a dropdown. Option 0 is the label; the
 *  actions are 1… on the wire. */
@Composable
private fun IsoMenu(n: UNode, m: Modifier) {
    val j = n.json
    val edit = j.optString("edit")
    val options = j.optJSONArray("options") ?: JSONArray()
    val items = (1 until options.length()).map { options.optString(it) }
    var open by remember { mutableStateOf(false) }
    Box(m) {
        val label = n.children.firstOrNull()
        Box(Modifier.clickable { open = true }.padding(6.dp)) {
            if (label != null) {
                IsoNode(label, Modifier)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(j.optJSONObject("params")?.optString("label") ?: "", color = MaterialTheme.colorScheme.primary)
                    // `.menuIndicator(.hidden)`: the label alone.
                    if (j.optJSONObject("params")?.optString("indicator") != "hidden") {
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            items.forEachIndexed { index, title ->
                DropdownMenuItem(text = { Text(title) }, onClick = { open = false; sendEvent(edit, "${index + 1}") })
            }
        }
    }
}

/** Semantic navigation, Material idiom: a top app bar when it has content
 *  (back, toolbar items, inline title), a large headline + search field
 *  otherwise, then the screen content. Events ride the node's host-event
 *  channel ("back", "leading:<i>", "trailingItem:<i>", "search:<text>"). */
/** A compact split view's way back to the previous column, for the bar of
 *  the navigation stack at that column's root (null elsewhere). */
private val LocalSplitBack = compositionLocalOf<(() -> Unit)?> { null }

/** The node a `.textSelection` container was just put around (so drawing
 *  it inside the container doesn't wrap it again). */
private val LocalSelectionApplied = compositionLocalOf<UNode?> { null }

/** A `.principal` item's own view, drawn in the bar's centre. */
private val LocalPrincipalView = compositionLocalOf<UNode?> { null }

@Composable
private fun IsoNavStack(node: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val j = node.json
    val p = j.optJSONObject("params") ?: JSONObject()
    val edit = j.optString("edit")
    val depth = p.optString("depth").toIntOrNull() ?: 0
    val inline = p.optString("displayMode") == "inline"
    val title = p.optString("title")
    val splitBack = if (depth == 0) LocalSplitBack.current else null
    // The content, then a `.principal` item's own view when it has one.
    val principalView = if (p.optString("principalContent") == "1" && node.children.size > 1) node.children.last() else null
    val content = if (principalView != null) node.children.dropLast(1) else node.children
    val showBar = depth > 0 || p.optString("leading").isNotEmpty() ||
        p.optString("trailingItems").isNotEmpty() || inline || splitBack != null || principalView != null
    val bar: (@Composable () -> Unit)? = if (!showBar) null else ({
        val bar = JSONObject()
            .put("view", "navbar")
            .put("edit", edit)
            .put("params", JSONObject()
                .put("title", if (inline) title else "")
                .put("back", if (depth > 0 || splitBack != null) "1" else "0")
                .put("leading", p.optString("leading"))
                .put("trailingItems", p.optString("trailingItems"))
                .put("leadingSymbols", p.optString("leadingSymbols"))
                .put("trailingSymbols", p.optString("trailingSymbols"))
                .put("leadingLabels", p.optString("leadingLabels"))
                .put("trailingLabels", p.optString("trailingLabels"))
                .put("prominent", p.optString("prominent"))
                .put("leadingDisabled", p.optString("leadingDisabled"))
                .put("trailingDisabled", p.optString("trailingDisabled"))
                .put("principal", p.optString("principal")))
        CompositionLocalProvider(LocalPrincipalView provides principalView, LocalSplitBack provides splitBack) {
            IsoHostView(bar, Modifier)
        }
    })
    val safe = LocalSafeArea.current
    // Bar-only chrome (no large title, no search field) pins over the
    // content, as on iOS: the content runs up under it to the top of the
    // screen, and the screen's scroll takes the bar's height as its inset.
    val pinned = bar != null && (inline || title.isEmpty()) && p.optString("searchPrompt").isEmpty()
    if (pinned) {
        val target = edgeScroll(content.singleOrNull())
        val chrome = LocalChrome.current
        val density = LocalDensity.current
        // The page's ground (the content's own backdrop, a Form's grouped
        // fill, when it paints one): what the scroll edge washes toward.
        val ground = backdropColor(content.singleOrNull()) ?: pageGround()
        // `.scrollEdgeEffectStyle(.hard, for: .top)` on the scroll: a band.
        val hardEdge = target?.json?.optJSONObject("params")?.optString("edgeTop") == "hard"
        // Only a scroll passes under the bar (other content sits below it):
        // the bar is then on an opaque band, in Material's scrolled colour
        // while the scroll has content under it (the scroll says: BarScroll).
        val underBar = target != null
        val barScroll = remember { BarScroll() }
        // The bar is measured first and the content composed with its height
        // in the same pass (as in IsoInsetStack): its inset is right in the
        // first frame.
        SubcomposeLayout(m.fillMaxSize()) { constraints ->
            val barPlaceables = subcompose("bar") {
                Box(Modifier.fillMaxWidth().padding(top = safe.top)) {
                    bar!!()
                }
            }.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
            val barHeight = with(density) { (barPlaceables.maxOfOrNull { it.height } ?: 0).toDp() }
            val inner = EdgeInsets(barHeight, chrome.bottom)
            val mainPlaceables = subcompose("main") {
                CompositionLocalProvider(
                    LocalSplitBack provides null,
                    LocalSafeArea provides safe.copy(top = 0.dp),
                    LocalChrome provides (if (target != null) inner else EdgeInsets()),
                    LocalEdgeScroll provides target,
                    LocalBarScroll provides (if (underBar) barScroll else null),
                ) {
                    Box(Modifier.fillMaxSize()
                        .then(if (underBar) Modifier else Modifier.padding(top = inner.top, bottom = inner.bottom))) {
                        for (c in content) IsoNode(c, Modifier.fillMaxSize(), bw, bh)
                    }
                }
            }.map { it.measure(constraints) }
            val width = maxOf(constraints.minWidth, mainPlaceables.maxOfOrNull { it.width } ?: 0)
            val height = maxOf(constraints.minHeight, mainPlaceables.maxOfOrNull { it.height } ?: 0)
            // What the bar sits on, from the top of the screen (the status
            // bar's area with it) to the bar's bottom; hard: and its line
            // below.
            val barBottom = barPlaceables.maxOfOrNull { it.height } ?: 0
            val edgePlaceables = subcompose("edge") {
                if (underBar) BarBand(ground, barScroll.under, hardEdge)
            }.map { it.measure(Constraints.fixed(width, barBottom + if (hardEdge) with(density) { HardEdgeLine.roundToPx().coerceAtLeast(1) } else 0)) }
            layout(width, height) {
                mainPlaceables.forEach { it.place(0, 0) }
                edgePlaceables.forEach { it.place(0, 0) }
                barPlaceables.forEach { it.place(0, 0) }
            }
        }
        return
    }
    Column(m.fillMaxSize()) {
        // Below the status bar: the rows here sit on the page, not over it.
        Spacer(Modifier.height(safe.top))
        bar?.invoke()
        if (!inline && title.isNotEmpty()) {
            // A top-level screen's title as Material's large top app bar
            // sets it: the headline type, regular weight, room above it.
            Text(
                title,
                Modifier.padding(start = 16.dp, end = 16.dp, top = if (bar == null) 28.dp else 8.dp, bottom = 12.dp),
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
        if (p.optString("searchPrompt").isNotEmpty()) {
            IsoTextField(
                id = "$edit#search",
                value = p.optString("searchValue"),
                placeholder = p.optString("searchPrompt"),
                editID = edit,
                search = true,
                modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp),
                eventPrefix = "search:",
            )
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            CompositionLocalProvider(LocalSplitBack provides null, LocalSafeArea provides safe.copy(top = 0.dp)) {
                for (c in content) IsoNode(c, Modifier.fillMaxSize(), bw, bh)
            }
        }
    }
}

/** How many screens a pane's navigation stack has pushed (0 for a pane
 *  that is not a stack), looking through the boxes modifiers make. */
private fun stackDepth(pane: UNode?): Int {
    var current = pane
    while (current != null) {
        if (current.json.optString("view") == "navstack") {
            return current.json.optJSONObject("params")?.optString("depth")?.toIntOrNull() ?: 0
        }
        current = if (current.children.size == 1) current.children[0] else null
    }
    return 0
}

/** Semantic split view: sidebar | content | detail columns with hairline
 *  dividers on a wide canvas (240/340dp columns like the shared examples
 *  were designed against); a COMPACT canvas collapses to a single-pane
 *  drill — a tap in the visible pane advances (the row's own click fired
 *  first), the back row retreats — matching SwiftUI's compact split view. */
@Composable
private fun IsoNavSplit(node: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    BoxWithConstraints(m.fillMaxSize()) {
        if (maxWidth < 700.dp) {
            // The compact split: one column at a time. The guest decides
            // when to move on (a List selection advances; a cleared one goes
            // back: `compact` + `compactTick`), and every move is reported
            // ("compact:<column>", ":back" when it went back, which clears
            // the selections past it, as SwiftUI's compact split does).
            val params = node.json.optJSONObject("params")
            val edit = node.json.optString("edit")
            val names = if (node.children.size == 2) listOf("sidebar", "detail") else listOf("sidebar", "content", "detail")
            val tick = params?.optString("compactTick") ?: ""
            val target = names.indexOf(params?.optString("compact") ?: "")
            // Starts where the guest wants it: a selection made before the
            // split first composed (restored, or set at launch) arrives as
            // the tick already seen, so only this shows it.
            var pane by remember { mutableStateOf(target.coerceIn(0, node.children.size - 1)) }
            val seenTick = remember { arrayOf(tick) }
            fun go(next: Int) {
                if (next == pane || next < 0 || next >= node.children.size) return
                if (edit.isNotEmpty()) sendEvent(edit, "compact:" + names[next] + (if (next < pane) ":back" else ""))
                pane = next
            }
            LaunchedEffect(tick) {
                if (tick != seenTick[0]) {
                    seenTick[0] = tick
                    if (target >= 0) pane = target
                }
            }
            // System back from a pushed pane returns to the one before it,
            // as the pane's own back does, instead of leaving the app; but a
            // pane whose stack has screens pushed (a build opened from an
            // app's builds) goes back through them first, as SwiftUI's
            // collapsed split does: this handler steps aside for the
            // runtime's back, which pops the innermost stack.
            BackHandler(enabled = pane > 0 && stackDepth(node.children.getOrNull(pane)) == 0) { go(pane - 1) }
            val paneIsStack = node.children.getOrNull(pane)?.json?.optString("view") == "navstack"
            Column(Modifier.fillMaxSize()) {
                if (pane > 0 && !paneIsStack) {
                    Text(
                        "\u2039 Back",
                        Modifier
                            .clickable { go(pane - 1) }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        color = MaterialTheme.colorScheme.primary,
                        fontSize = 16.sp,
                    )
                }
                // The pane on its content's ground: a grouped list's
                // container tone (under its title too), the page's otherwise.
                val ground = paneGround(node.children.getOrNull(pane))
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(ground)
                ) {
                    node.children.getOrNull(pane)?.let {
                        // The pane's own bar shows the way back; a content-sized
                        // root sits in the middle, as SwiftUI places it.
                        CompositionLocalProvider(
                            LocalSplitBack provides (if (pane > 0) ({ go(pane - 1) }) else null),
                            LocalGround provides ground,
                        ) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                IsoNode(it, if (it.json.optBoolean("expandH") || it.json.optString("k") == "hostView") Modifier.fillMaxSize() else Modifier, bw, bh)
                            }
                        }
                    }
                }
            }
        } else {
            Row(Modifier.fillMaxSize()) {
                val divider: @Composable () -> Unit = {
                    Box(
                        Modifier.width(1.dp).fillMaxHeight()
                            .background(MaterialTheme.colorScheme.outlineVariant))
                }
                val p = node.json.optJSONObject("params")
                val sidebarWidth = (p?.optString("sidebarWidth")?.toIntOrNull() ?: 240).dp
                val contentWidth = (p?.optString("contentWidth")?.toIntOrNull() ?: 340).dp
                // The sidebar on Material's container tone, as a navigation
                // pane is.
                Box(
                    Modifier.width(sidebarWidth).fillMaxHeight()
                        .background(groupedGround())) {
                    node.children.getOrNull(0)?.let {
                        CompositionLocalProvider(LocalGround provides groupedGround()) {
                            IsoNode(it, Modifier.fillMaxSize(), bw, bh)
                        }
                    }
                }
                divider()
                // A content-sized column root sits in the middle (SwiftUI centres
                // a detail view that is not greedy); greedy roots fill.
                val columnRoot: @Composable (UNode) -> Unit = { c ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        IsoNode(c, if (c.json.optBoolean("expandH") || c.json.optString("k") == "hostView") Modifier.fillMaxSize() else Modifier, bw, bh)
                    }
                }
                if (node.children.size == 2) {
                    // Two-column split (sidebar + detail): the detail takes the rest.
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        node.children.getOrNull(1)?.let { columnRoot(it) }
                    }
                } else {
                    Box(Modifier.width(contentWidth).fillMaxHeight()) {
                        node.children.getOrNull(1)?.let { columnRoot(it) }
                    }
                    divider()
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        node.children.getOrNull(2)?.let { columnRoot(it) }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun IsoHostView(n: JSONObject, m: Modifier) {
    // Tabbar icons load through the async bitmap cache; subscribe to imageTick so
    // they refresh on load even when the enclosing IsoNode skipped.
    @Suppress("UNUSED_VARIABLE") val tick = ComposeTreeState.imageTick.value
    val p = n.optJSONObject("params") ?: JSONObject()
    val edit = n.optString("edit")
    when (val view = n.optString("view")) {
        "navbar" -> {
            val barTitle: @Composable () -> Unit = {
                // Large-title mode: the inline bar title fades in only as the
                // big in-content title collapses under the bar.
                val alpha = if (p.optString("large") == "1") {
                    p.optString("inlineAlpha").toFloatOrNull() ?: 1f
                } else {
                    1f
                }
                val principalView = LocalPrincipalView.current
                val principalIndex = p.optString("principal").toIntOrNull() ?: -1
                val trailingTitles = p.optString("trailingItems").split("\n")
                if (principalView != null) {
                    // Measured at its own size: a view taller than the bar (an
                    // avatar with a name pill hanging below) overflows it.
                    Box(Modifier.fillMaxWidth().wrapContentHeight(unbounded = true), contentAlignment = Alignment.Center) {
                        IsoNode(principalView, Modifier.wrapContentHeight(unbounded = true))
                    }
                } else if (principalIndex >= 0 && principalIndex < trailingTitles.size) {
                    // A worded principal item: a title-styled button.
                    TextButton(onClick = { sendEvent(edit, "trailingItem:$principalIndex") }) {
                        Text(trailingTitles[principalIndex], color = LocalContentColor.current, fontWeight = FontWeight.SemiBold)
                    }
                } else {
                    Text(
                        p.optString("title"),
                        Modifier.alpha(alpha),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            val barNavigation: @Composable () -> Unit = {
                Row(Modifier.padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    val splitBack = LocalSplitBack.current
                    if (p.optString("back") == "1") {
                        BarButton(onClick = { if (splitBack != null) splitBack() else sendEvent(edit, "back") }, icon = true) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                    // Leading toolbar items (ToolbarItem(placement: .navigation)):
                    // newline-joined titles, evented as "leading:<i>".
                    val leading = p.optString("leading")
                    if (leading.isNotEmpty()) {
                        val symbols = p.optString("leadingSymbols").split("\n")
                        val labels = p.optString("leadingLabels").split("\n")
                        val disabled = p.optString("leadingDisabled").split("\n")
                        leading.split("\n").forEachIndexed { i, title ->
                            IsoBarItem(title, symbols.getOrNull(i) ?: "", labels.getOrNull(i) ?: "", disabled = disabled.getOrNull(i) == "1") { sendEvent(edit, "leading:$i") }
                        }
                    }
                }
            }
            val barActions: @Composable RowScope.() -> Unit = {
                // Trailing toolbar items ("trailingItems", evented as
                // "trailingItem:<i>"); the legacy single "trailing" param is
                // the fallback for older bundles.
                val trailingItems = p.optString("trailingItems")
                if (trailingItems.isNotEmpty()) {
                    val symbols = p.optString("trailingSymbols").split("\n")
                    val labels = p.optString("trailingLabels").split("\n")
                    val prominent = p.optString("prominent").split("\n")
                    val disabled = p.optString("trailingDisabled").split("\n")
                    val principal = p.optString("principal").toIntOrNull() ?: -1
                    Row(Modifier.padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        trailingItems.split("\n").forEachIndexed { i, title ->
                            // The principal item sits in the title slot (its own view, or its words).
                            if (i == principal) return@forEachIndexed
                            IsoBarItem(title, symbols.getOrNull(i) ?: "", labels.getOrNull(i) ?: "", prominent.getOrNull(i) == "1", disabled.getOrNull(i) == "1") { sendEvent(edit, "trailingItem:$i") }
                        }
                    }
                } else {
                    val trailing = p.optString("trailing")
                    if (trailing.isNotEmpty()) {
                        TextButton(onClick = { sendEvent(edit, "trailing") }) { Text(trailing) }
                    }
                }
            }
            // Material's top app bar: the title at the start, beside the way
            // back, as Android's are; a principal item (the app's own view,
            // an avatar) keeps the middle. The navigation stack places it
            // (below the status bar) and draws the scroll edge behind it.
            if (LocalPrincipalView.current != null || (p.optString("principal").toIntOrNull() ?: -1) >= 0) {
                CenterAlignedTopAppBar(
                    windowInsets = WindowInsets(0, 0, 0, 0),
                    colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
                    title = barTitle, navigationIcon = barNavigation, actions = barActions,
                )
            } else {
                TopAppBar(
                    windowInsets = WindowInsets(0, 0, 0, 0),
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
                    title = barTitle, navigationIcon = barNavigation, actions = barActions,
                )
            }
        }
        "tabbar" -> NavigationBar {
            val count = p.optInt("count")
            val selected = p.optInt("selected")
            for (i in 0 until count) {
                NavigationBarItem(
                    selected = i == selected,
                    onClick = { sendEvent(edit, "$i") },
                    icon = {
                        val icon = p.optString("icon$i")
                        val bitmap = if (icon.isEmpty()) null else HostServices.imageBitmap(icon, false)
                        // A tab's SF Symbol (`Tab(_:systemImage:)`, a `.tabItem`'s
                        // Label), drawn from the symbol table in the bar's colours.
                        val symbol = p.optString("symbol$i")
                        val entry = Symbols.table[symbol] ?: Symbols.table[symbol.removeSuffix(".fill")]
                        if (bitmap != null) {
                            Icon(
                                bitmap.asImageBitmap(),
                                contentDescription = p.optString("label$i"),
                                modifier = Modifier.size(24.dp),
                                tint = Color.Unspecified,
                            )
                        } else if (entry != null) {
                            val vector = remember(symbol) { symbolVector(entry) }
                            Icon(vector, contentDescription = p.optString("label$i"), modifier = Modifier.size(24.dp))
                        } else {
                            Spacer(Modifier.size(24.dp))
                        }
                    },
                    label = { Text(p.optString("label$i")) },
                )
            }
        }
        "search" -> IsoTextField(
            id = edit,
            value = n.optString("v"),
            placeholder = p.optString("prompt").ifEmpty { "Search" },
            editID = edit,
            search = true,
            modifier = m,
        )
        "toggle" -> Switch(
            checked = n.optString("v") == "1",
            onCheckedChange = { sendEvent(edit, if (it) "1" else "0") },
            modifier = m,
        )
        "picker" -> {
            var open by remember { mutableStateOf(false) }
            val options = n.optJSONArray("options") ?: JSONArray()
            val labels = (0 until options.length()).map { options.optString(it) }
            val selected = n.optString("v").toIntOrNull()
            val label = if (view == "picker") {
                selected?.let { labels.getOrNull(it) } ?: n.optString("v")
            } else {
                n.optString("v").ifEmpty { labels.firstOrNull() ?: "" }
            }
            // A picker in a Form's or a List's row (`formRow`): its title
            // leading, the menu trailing, as SwiftUI draws it there; a
            // segmented one is Material's segmented buttons, across the row.
            val inRow = view == "picker" && p.optString("formRow") == "1"
            val pickerStyle = p.optString("style")
            if (view == "picker" && pickerStyle == "segmented") {
                SingleChoiceSegmentedButtonRow(if (inRow) m.fillMaxWidth() else m) {
                    labels.forEachIndexed { index, option ->
                        SegmentedButton(
                            selected = index == selected,
                            onClick = { sendEvent(edit, "$index") },
                            shape = SegmentedButtonDefaults.itemShape(index, labels.size),
                        ) { Text(option, maxLines = 1) }
                    }
                }
                return
            }
            // `.pickerStyle(.inline)`: the choices themselves, a row each,
            // Material's single choice: a radio button and its label.
            if (view == "picker" && pickerStyle == "inline") {
                Column(m.fillMaxWidth().selectableGroup()) {
                    labels.forEachIndexed { index, option ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                .selectable(selected = index == selected, role = Role.RadioButton, onClick = { sendEvent(edit, "$index") }),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = index == selected, onClick = null)
                            Text(option, Modifier.padding(start = 12.dp), style = TextStyle(fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurface))
                        }
                    }
                }
                return
            }
            val title = if (inRow && (pickerStyle.isEmpty() || pickerStyle == "menu") && p.optString("labelsHidden") != "1") {
                p.optString("title")
            } else {
                ""
            }
            Row(if (title.isNotEmpty()) m.fillMaxWidth() else m, verticalAlignment = Alignment.CenterVertically) {
                if (title.isNotEmpty()) {
                    Text(title, Modifier.weight(1f), style = TextStyle(fontSize = 17.sp, color = MaterialTheme.colorScheme.onSurface))
                }
                Box {
                    TextButton(onClick = { open = true }) {
                        Text(label)
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
                    }
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        labels.forEachIndexed { index, option ->
                            DropdownMenuItem(
                                text = { Text(option) },
                                onClick = {
                                    open = false
                                    sendEvent(edit, "$index")
                                },
                                trailingIcon = if (view == "picker" && index == selected) {
                                    { Icon(Icons.Filled.Check, contentDescription = null) }
                                } else {
                                    null
                                },
                            )
                        }
                    }
                }
            }
        }
        "datepicker" -> {
            var open by remember { mutableStateOf(false) }
            val iso = n.optString("v")
            TextButton(onClick = { open = true }, modifier = m) { Text(iso.ifEmpty { "Pick a date" }) }
            if (open) {
                val initial = try {
                    java.time.LocalDate.parse(iso)
                        .atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()
                } catch (_: Exception) {
                    null
                }
                val state = rememberDatePickerState(initialSelectedDateMillis = initial)
                DatePickerDialog(
                    onDismissRequest = { open = false },
                    confirmButton = {
                        TextButton(onClick = {
                            open = false
                            state.selectedDateMillis?.let { millis ->
                                val date = java.time.Instant.ofEpochMilli(millis)
                                    .atZone(java.time.ZoneOffset.UTC).toLocalDate()
                                sendEvent(edit, date.toString())
                            }
                        }) { Text("OK") }
                    },
                    dismissButton = {
                        TextButton(onClick = { open = false }) { Text("Cancel") }
                    },
                ) { DatePicker(state) }
            }
        }
        "image" -> IsoImage(n.optString("v"), n.optString("v").startsWith("http"), true, m)
        "webview" -> AndroidView(
            factory = { context ->
                WebView(context).apply {
                    settings.javaScriptEnabled = true
                    loadUrl(n.optString("v"))
                }
            },
            modifier = m.fillMaxWidth(),
        )
        "video" -> Surface(
            m.fillMaxWidth().clickable { HostServices.openUrl(n.optString("v")) },
            shape = RoundedCornerShape(12.dp),
            color = Color(0f, 0f, 0f, 0.06f),
        ) {
            Column(
                Modifier.padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null, Modifier.size(36.dp))
                Text("Open video", color = MaterialTheme.colorScheme.primary)
            }
        }
        else -> {
            // An app-authored representable: the composable the app
            // registered for the view's kind (AppHostViews).
            val factory = AppHostViews.factories[view]
            if (factory != null) {
                factory(n, m, edit)
                return
            }
            // Representables (`android:<hint>`): a plain platform text input,
            // matching the GL path's EditText representable example.
            if (view.startsWith("android:")) {
                var local by remember(edit) { mutableStateOf(n.optString("v")) }
                BasicTextField(
                    value = local,
                    onValueChange = {
                        local = it
                        sendEvent(edit, it)
                    },
                    modifier = m
                        .background(Color(0f, 0f, 0f, 0.06f), RoundedCornerShape(8.dp))
                        .padding(10.dp),
                )
            } else {
                Box(m)
            }
        }
    }
}

/** An alert action's role as the tree says it ("cancel", "destructive"):
 *  on the button's node, or on the one node it wraps. */
private fun alertActionRole(n: UNode): String {
    var node: UNode? = n
    while (node != null) {
        node.json.optJSONObject("params")?.optString("role")?.takeIf { it.isNotEmpty() }?.let { return it }
        node = node.children.singleOrNull()
    }
    return ""
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun IsoPresentation(n: UNode) {
    // A request: the system's own picker (MediaPickerHost), answered with
    // the copied files' paths (or, saving, where the file went); nothing is
    // drawn.
    n.json.optJSONObject("params")?.takeIf { it.has("request") }?.let { p ->
        val result = p.optString("result")
        LaunchedEffect(n.json.optString("dismiss")) {
            if (p.optString("request") == "export") {
                MediaPickerHost.export(p.optString("name"), p.optString("type"), p.optString("data")) { sendEvent(result, it) }
            } else {
                MediaPickerHost.request(p.optString("request"), p.optString("accept"), p.optString("multiple") == "1") { sendEvent(result, it) }
            }
        }
        return
    }
    val dismiss = n.json.optString("dismiss")
    if (n.json.optString("style") == "alert") {
        val title = n.json.optString("title")
        val message = n.json.optString("message")
        // The actions in Material's order, by their roles (the guest's
        // `Button(role: .cancel)`): two, one of them dismissive, sit side by
        // side at the dialog's end, the dismissive one first ("Later",
        // "Open Sign-In Page"); more stack, the dismissive ones last, as
        // Android's own stacked dialogs put them.
        // The guest's actions arrive in one stack (its ViewBuilder's): look
        // through it to the buttons.
        val wrapper = n.children.singleOrNull()?.takeIf { it.children.size > 1 && it.json.optJSONObject("params")?.has("button") != true }
        val actions = (wrapper?.children ?: n.children).withIndex().toList()
        val dismissive = actions.filter { alertActionRole(it.value) == "cancel" }
        val confirming = actions.filter { alertActionRole(it.value) != "cancel" }
        if (actions.size == 2 && dismissive.size == 1) {
            val (ci, c) = confirming.single()
            val (di, d) = dismissive.single()
            AlertDialog(
                onDismissRequest = { sendEvent(dismiss, "") },
                // Each with a Material text button's padding around its label.
                confirmButton = { key(childKey(c, ci)) { IsoNode(c, Modifier.padding(horizontal = 12.dp, vertical = 8.dp), boundedW = false, boundedH = false) } },
                dismissButton = { key(childKey(d, di)) { IsoNode(d, Modifier.padding(horizontal = 12.dp, vertical = 8.dp), boundedW = false, boundedH = false) } },
                title = if (title.isEmpty()) null else ({ Text(title) }),
                text = if (message.isEmpty()) null else ({ Text(message) }),
            )
            return
        }
        AlertDialog(
            onDismissRequest = { sendEvent(dismiss, "") },
            confirmButton = {},
            title = if (title.isEmpty()) null else ({ Text(title) }),
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (message.isNotEmpty()) Text(message)
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        for ((i, c) in confirming + dismissive) key(childKey(c, i)) { IsoNode(c, Modifier, boundedW = true, boundedH = false) }
                    }
                }
            },
        )
    } else {
        // A plain SwiftUI sheet presents at the LARGE detent — a full-height
        // card whose content gets the whole height (Spacer()/minHeight
        // layouts depend on it) — and shows no drag indicator. The guest
        // declares no detents yet, so partial expansion never applies.
        val params = n.json.optJSONObject("params") ?: JSONObject()
        val cover = params.optString("cover") == "1"
        val detents = params.optString("detents", "large").split(",")
        val grabber = params.optString("grabber", "1") != "0" && !cover
        val greedy = n.children.firstOrNull()?.json?.let { it.optBoolean("growH") || it.optBoolean("expandH") } ?: false
        if (cover) {
            // `.fullScreenCover`: the content IS the screen.
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
                // A screen of its own: its chrome takes the safe area.
                val main = n.children.singleOrNull()
                if (main != null) {
                    SafeAreaScreen(main) { IsoNode(main, Modifier, boundedW = true, boundedH = true) }
                } else Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars)) {
                    for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, boundedW = true, boundedH = true) }
                }
            }
        } else {
            // `.presentationDetents([.medium, .large])` rests half-open first;
            // the grabber follows `.presentationDragIndicator`. Growing content
            // (a NavigationStack / List / Form) runs edge to edge.
            // `.interactiveDismissDisabled()`: no drag or scrim tap puts it
            // away (a zoomed image pans instead); Back still does, as
            // Android's way out of anything.
            val noDismiss = params.optString("nodismiss") == "1"
            // A sheet holding a grouped list (a Form) is the list's grouped
            // ground all the way up, behind the drag handle too; any other
            // sheet the raised surface of an iPhone's sheet.
            val dark = isSystemInDarkTheme()
            val ground = backdropColor(n.children.firstOrNull()) ?: if (dark) Color(0xFF1C1C1E) else Color.White
            // Half-open only where there is the height for it: on a phone
            // in landscape (a compact height) a `.medium` sheet opens whole,
            // as iOS shows one there; half of it was little more than its
            // title bar. Keyed on it, so a turn of the phone starts the sheet
            // afresh (a half-open state saved in portrait can't be restored
            // into a sheet that has none).
            val compactHeight = LocalConfiguration.current.screenHeightDp < 480
            // Material centres the sheet (at most 640dp) on the whole window;
            // a navigation bar or cutout beside the screen (three-button
            // navigation in landscape) is taken off first, as SafeAreaScreen
            // takes it off a screen, so the sheet centres on the app's area
            // and stops short of the bar.
            val density = LocalDensity.current
            val direction = LocalLayoutDirection.current
            val sides = WindowInsets.navigationBars.union(WindowInsets.displayCutout)
            val left = with(density) { sides.getLeft(density, direction).toDp() }
            val right = with(density) { sides.getRight(density, direction).toDp() }
            key(compactHeight) {
            ModalBottomSheet(
                onDismissRequest = { sendEvent(dismiss, "") },
                // Below the status bar, as a sheet sits on a phone.
                modifier = Modifier.statusBarsPadding().absolutePadding(left = left, right = right).padding(top = 8.dp),
                containerColor = ground,
                sheetState = rememberModalBottomSheetState(
                    skipPartiallyExpanded = !detents.contains("medium") || compactHeight,
                    confirmValueChange = { !noDismiss || it != SheetValue.Hidden },
                ),
                dragHandle = if (grabber) ({ BottomSheetDefaults.DragHandle() }) else null,
            ) {
                if (noDismiss) BackHandler { sendEvent(dismiss, "") }
                // The sheet sits below the status bar and pads for the
                // navigation bar itself: nothing inside takes a safe area.
                CompositionLocalProvider(LocalSafeArea provides EdgeInsets(), LocalGround provides ground) {
                Column(
                    Modifier.fillMaxWidth().fillMaxHeight().padding(if (greedy) 0.dp else 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(if (greedy) 0.dp else 8.dp),
                ) {
                    for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, Modifier, boundedW = true, boundedH = true) }
                }
                }
            }
            }
        }
    }
}


/** A 24x24 outline icon from the portable symbol table (Lucide path data);
 *  a filled badge keeps its glyph in the contrasting colour. The vector is
 *  black; `Icon` tints it. */
internal fun symbolVector(symbol: Symbol, glyph: Color = Color.White, badge: Color = Color.Black): ImageVector {
    val builder = ImageVector.Builder(defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
        .addPath(
            pathData = PathParser().parsePathString(symbol.d).toNodes(),
            fill = if (symbol.filled) SolidColor(badge) else null,
            stroke = SolidColor(badge),
            strokeLineWidth = if (symbol.filled) 1.5f else 2f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    if (symbol.inner.isNotEmpty()) {
        builder.addPath(
            pathData = PathParser().parsePathString(symbol.inner).toNodes(),
            // A closed glyph (play.circle.fill's triangle) is cut out whole.
            fill = if (symbol.inner.trimEnd().endsWith("z", ignoreCase = true)) SolidColor(glyph) else null,
            stroke = SolidColor(glyph),
            strokeLineWidth = 2.2f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
    return builder.build()
}


/** One row action as the guest encodes it: index␞title␞symbol␞d? per item, ␟ between. */
internal data class RowAction(val index: Int, val title: String, val symbol: String, val destructive: Boolean)

internal fun decodeRowActions(text: String): List<RowAction> =
    text.split("\u001f").filter { it.isNotEmpty() }.map { part ->
        val f = part.split("\u001e")
        RowAction(f.getOrNull(0)?.toIntOrNull() ?: 0, f.getOrNull(1) ?: "", f.getOrNull(2) ?: "", f.getOrNull(3) == "d")
    }

/** A concatenated Text's spans: `length:flags[:r,g,b,a]` per run, ";" between (flags ⊂ b i m u s t). */
internal fun styledRuns(text: String, encoded: String): AnnotatedString = buildAnnotatedString {
    var at = 0
    for (part in encoded.split(";")) {
        val fields = part.split(":")
        val length = fields.getOrNull(0)?.toIntOrNull() ?: 0
        val flags = fields.getOrNull(1) ?: ""
        val end = minOf(text.length, at + length)
        val slice = text.substring(minOf(at, text.length), end)
        at = end
        val decorations = mutableListOf<TextDecoration>()
        if ('u' in flags) decorations.add(TextDecoration.Underline)
        if ('s' in flags) decorations.add(TextDecoration.LineThrough)
        val color = fields.getOrNull(2)?.split(",")?.mapNotNull { it.toFloatOrNull() }
        withStyle(SpanStyle(
            fontWeight = if ('b' in flags) FontWeight.SemiBold else null,
            fontStyle = if ('i' in flags) FontStyle.Italic else null,
            fontFamily = if ('m' in flags) FontFamily.Monospace else null,
            fontFeatureSettings = if ('t' in flags) "tnum" else null,
            textDecoration = if (decorations.isEmpty()) null else TextDecoration.combine(decorations),
            color = if (color != null && color.size >= 3) Color(color[0], color[1], color[2], color.getOrNull(3) ?: 1f) else Color.Unspecified,
        )) { append(slice) }
    }
}

/** `.contextMenu`: a long press opens the items as a drop-down at the box. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun IsoContextMenuBox(n: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val params = n.json.optJSONObject("params") ?: JSONObject()
    val items = decodeRowActions(params.optString("ctxitems"))
    val id = params.optString("ctxmenu")
    var open by remember { mutableStateOf(false) }
    // Only a long press is the menu's: a tap goes through to what holds
    // the box (a list row's selection), which a click handler here stole.
    Box(m.onLongPressObserving { open = true }) {
        for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (item in items) {
                DropdownMenuItem(
                    text = { Text(item.title, color = if (item.destructive) MaterialTheme.colorScheme.error else Color.Unspecified) },
                    leadingIcon = Symbols.table[item.symbol]?.let { sym -> { Icon(symbolVector(sym), contentDescription = null) } },
                    onClick = { open = false; sendEvent(id, "${item.index}") },
                )
            }
        }
    }
}

/** Calls [onLongPress] when the pointer is held still for the long-press
 *  time, and only then consumes the rest of that gesture: a tap is left
 *  unconsumed, so an enclosing clickable (a list row) still gets it. */
private fun Modifier.onLongPressObserving(onLongPress: () -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val released = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) break
                if ((change.position - down.position).getDistance() > viewConfiguration.touchSlop) break
            }
            true
        }
        if (released == null) {
            onLongPress()
            while (true) {
                val event = awaitPointerEvent()
                event.changes.forEach { it.consume() }
                if (event.changes.none { it.pressed }) break
            }
        }
    }
}

/** `.swipeActions`: the content slides with a horizontal drag and the buttons
 *  show in the space it leaves; a full swipe performs the first one. */
@Composable
private fun IsoSwipeRow(n: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    val params = n.json.optJSONObject("params") ?: JSONObject()
    val leading = decodeRowActions(params.optString("swipeLeading"))
    val trailing = decodeRowActions(params.optString("swipeTrailing"))
    val full = params.optString("swipeFull") == "1"
    val id = params.optString("swipe")
    val density = LocalDensity.current.density
    val buttonWidth = 84f * density
    var offset by remember { mutableStateOf(0f) }
    var rowWidth by remember { mutableStateOf(0f) }
    val perform: (RowAction) -> Unit = { offset = 0f; sendEvent(id, "${it.index}") }
    Box(m.fillMaxWidth().onSizeChanged { rowWidth = it.width.toFloat() }.pointerInput(leading, trailing) {
        detectHorizontalDragGestures(
            onDragEnd = {
                val w = rowWidth
                when {
                    offset < 0 && trailing.isNotEmpty() && full && -offset > w * 0.6f -> perform(trailing[0])
                    offset < 0 && trailing.isNotEmpty() -> offset = if (-offset > buttonWidth * trailing.size * 0.5f) -buttonWidth * trailing.size else 0f
                    offset > 0 && leading.isNotEmpty() && full && offset > w * 0.6f -> perform(leading[0])
                    offset > 0 && leading.isNotEmpty() -> offset = if (offset > buttonWidth * leading.size * 0.5f) buttonWidth * leading.size else 0f
                    else -> offset = 0f
                }
            },
            onHorizontalDrag = { _, dragAmount ->
                var next = offset + dragAmount
                if (next < 0 && trailing.isEmpty()) next = 0f
                if (next > 0 && leading.isEmpty()) next = 0f
                offset = next
            },
        )
    }) {
        @Composable fun actionButton(item: RowAction, index: Int, trailingSide: Boolean) {
            val color = when {
                item.destructive -> Color(0xFFFF3B30)
                index == 0 -> if (trailingSide) Color(0xFFFF9500) else Color(0xFF34C759)
                else -> Color(0xFF8E8E93)
            }
            Column(
                Modifier.width(84.dp).fillMaxHeight().background(color).clickable { perform(item) },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Symbols.table[item.symbol]?.let { Icon(symbolVector(it), contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp)) }
                Text(item.title, color = Color.White, fontSize = 13.sp)
            }
        }
        if (offset > 0) Row(Modifier.matchParentSize(), horizontalArrangement = Arrangement.Start) { leading.forEachIndexed { i, it -> actionButton(it, i, false) } }
        if (offset < 0) Row(Modifier.matchParentSize(), horizontalArrangement = Arrangement.End) { trailing.forEachIndexed { i, it -> actionButton(it, i, true) } }
        // The row's content slides over its actions: as wide as the cell,
        // on the cell's own ground (and with the cell's padding, so the
        // whole cell moves, as iOS's does).
        val container = LocalRowContainer.current.takeIf { it.isSpecified } ?: MaterialTheme.colorScheme.surface
        Box(Modifier.offset { IntOffset(offset.roundToInt(), 0) }.fillMaxWidth().background(container).padding(LocalSwipePadding.current)) {
            CompositionLocalProvider(LocalSwipePadding provides PaddingValues(0.dp)) {
                for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
            }
        }
    }
}


/** The views with an `.id` inside the nearest vertical scroll, by id, where
 *  they were last laid out. */
private val LocalScrollTargets = compositionLocalOf<HashMap<String, LayoutCoordinates>?> { null }

/** Inside a scroll (a ScrollView, a List, a horizontal one): what moves with
 *  every frame of a scroll there, a geometry reader's place among it. */
private val LocalInScroll = compositionLocalOf { false }

/** A vertical ScrollView. It honours `ScrollViewProxy.scrollTo(id, anchor:)`
 *  (the core sends the latest request, "id|tick|anchor", to every scroll; the
 *  one holding that id brings it to the anchor once per request, after the
 *  layout that carries it) and `.defaultScrollAnchor(.bottom)` (it opens at
 *  the bottom and stays there while content grows, until the reader scrolls
 *  up, as a chat log does). */
@Composable
private fun IsoVerticalScroll(n: UNode, m: Modifier, bw: Boolean) {
    val params = n.json.optJSONObject("params")
    val column = n.children.singleOrNull()
    if (params?.optString("list") == "1" && column != null &&
        column.json.optString("k") == "stack" && column.json.optString("axis") == "v") {
        IsoLazyList(n, column, m, bw)
        return
    }
    val request = params?.optString("scrollTo") ?: ""
    val bottomAnchored = params?.optString("anchor") == "bottom"
    val state = rememberScrollState()
    val targets = remember { HashMap<String, LayoutCoordinates>() }
    val viewport = remember { arrayOfNulls<LayoutCoordinates>(1) }
    val applied = remember { arrayOf("") }
    if (bottomAnchored) {
        var pinned by remember { mutableStateOf(true) }
        // Only the reader's own drags move the pin (see IsoLazyList).
        LaunchedEffect(state) {
            var dragged = false
            launch {
                state.interactionSource.interactions.collect {
                    if (it is DragInteraction.Start) { dragged = true; pinned = false }
                }
            }
            snapshotFlow { state.isScrollInProgress }.collect { scrolling ->
                if (!scrolling && dragged) { dragged = false; pinned = state.value >= state.maxValue - 4 }
            }
        }
        LaunchedEffect(state, pinned) {
            if (!pinned) return@LaunchedEffect
            snapshotFlow { state.maxValue }.collect { max ->
                if (state.value != max) state.scrollTo(max)
            }
        }
    }
    if (request.isNotEmpty()) {
        LaunchedEffect(request) {
            val parts = request.split("|")
            if (parts.size < 3 || applied[0] == parts[1]) return@LaunchedEffect
            // The target may land a frame or two after the request does.
            repeat(10) {
                withFrameNanos { }
                val target = targets[parts[0]]
                val box = viewport[0]
                if (target != null && target.isAttached && box != null && box.isAttached) {
                    applied[0] = parts[1]
                    val r = box.localBoundingBoxOf(target, clipBounds = false)
                    val h = box.size.height.toFloat()
                    val delta = when (parts[2]) {
                        "bottom" -> r.bottom - h
                        "top" -> r.top
                        "center" -> r.top + r.height / 2 - h / 2
                        else -> if (r.top < 0) r.top else if (r.bottom > h) r.bottom - h else 0f
                    }
                    if (delta != 0f) state.scrollTo((state.value + delta.roundToInt()).coerceIn(0, state.maxValue))
                    return@LaunchedEffect
                }
            }
        }
    }
    val insets = scrollInsets(n)
    // `onScrollGeometryChange`: exact here (the scroll state knows its
    // content), in points, reported as it changes.
    val geometryId = params?.optString("geometry") ?: ""
    var viewportSize by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    if (geometryId.isNotEmpty()) {
        val density = LocalDensity.current.density
        LaunchedEffect(state, geometryId) {
            var reported = ""
            snapshotFlow {
                if (viewportSize.height == 0) return@snapshotFlow ""
                fun pt(px: Float) = "%.1f".format(java.util.Locale.ROOT, px / density)
                val top = insets.top.value * density
                val bottom = insets.bottom.value * density
                val content = state.maxValue + viewportSize.height - top - bottom
                listOf(pt(0f), pt(state.value - top), pt(viewportSize.width.toFloat()), pt(content),
                    pt(viewportSize.width.toFloat()), pt(viewportSize.height.toFloat()),
                    pt(top), "0", pt(bottom), "0").joinToString(",")
            }.collect { value ->
                if (value.isNotEmpty() && value != reported) {
                    reported = value
                    sendEvent(geometryId, value)
                }
            }
        }
    }
    ReportScrollPhase(params?.optString("phase") ?: "", state, state.interactionSource)
    ReportScrolledUnder(n, state, reversed = false)
    CompositionLocalProvider(LocalScrollTargets provides targets, LocalSafeArea provides EdgeInsets(), LocalChrome provides EdgeInsets(), LocalEdgeScroll provides null, LocalInScroll provides true) {
        Column(
            m.onGloballyPositioned { viewport[0] = it }.onSizeChanged { viewportSize = it }
                .verticalScroll(state, enabled = n.json.optJSONObject("params")?.optString("scrollDisabled") != "1")
                .padding(top = insets.top, bottom = insets.bottom),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            for ((i, c) in n.children.withIndex()) key(childKey(c, i)) {
                val stretch = c.json.optBoolean("growW") && bw
                IsoNode(
                    c, if (stretch) Modifier.fillMaxWidth() else Modifier,
                    boundedW = bw, boundedH = false)
            }
        }
    }
}

/** `onScrollPhaseChange`: the reader's drag is "interacting", the scroll
 *  carrying on after it "decelerating", a scroll nobody dragged (an animated
 *  `scrollTo`) "animating", and a still one "idle". A touch that has not
 *  moved yet is not a drag here, so there is no "tracking". */
@Composable
private fun ReportScrollPhase(
    phaseId: String,
    state: androidx.compose.foundation.gestures.ScrollableState,
    interactions: androidx.compose.foundation.interaction.InteractionSource,
) {
    if (phaseId.isEmpty()) return
    LaunchedEffect(state, phaseId) {
        var dragging by mutableStateOf(false)
        launch {
            interactions.interactions.collect {
                when (it) {
                    is DragInteraction.Start -> dragging = true
                    is DragInteraction.Stop, is DragInteraction.Cancel -> dragging = false
                }
            }
        }
        var afterDrag = false
        var reported = "idle"
        snapshotFlow { state.isScrollInProgress to dragging }.collect { (scrolling, drag) ->
            val phase = when {
                drag -> "interacting"
                scrolling -> if (afterDrag) "decelerating" else "animating"
                else -> "idle"
            }
            if (drag) afterDrag = true else if (!scrolling) afterDrag = false
            if (phase != reported) {
                reported = phase
                sendEvent(phaseId, phase)
            }
        }
    }
}

/** Tells the bar pinned over the screen's edge scroll whether content is
 *  under it (scrolled past the top; a list laid out from its bottom has more
 *  above when it can scroll forward). */
@Composable
private fun ReportScrolledUnder(n: UNode, state: androidx.compose.foundation.gestures.ScrollableState, reversed: Boolean) {
    val report = LocalBarScroll.current ?: return
    if (LocalEdgeScroll.current !== n) return
    val under by remember(state, reversed) { derivedStateOf { if (reversed) state.canScrollForward else state.canScrollBackward } }
    SideEffect { report.under = under }
    DisposableEffect(report) { onDispose { report.under = false } }
}

/** A vertical scroll's content insets: the chrome over it when it is the
 *  screen's edge scroll, and any safe area left at its edges (it runs to the
 *  screen's bottom edge when nothing sits below it). */
@Composable
private fun scrollInsets(n: UNode): EdgeInsets {
    val chrome = if (LocalEdgeScroll.current === n) LocalChrome.current else EdgeInsets()
    val safe = LocalSafeArea.current
    return EdgeInsets(chrome.top + safe.top, chrome.bottom + safe.bottom)
}

/** What a child composable is keyed on: its identity from the tree (the
 *  view's, with `ForEach` ids in it), so its state and composition follow it
 *  when siblings come and go; the runtime's own unkeyed nodes by position. */
internal fun childKey(c: UNode, index: Int): Any {
    val key = c.json.optString("key")
    return if (key.isEmpty()) index else key
}

/** A `List`: a lazy column over its rows, keyed by each row's identity, so
 *  only the rows on screen are composed and laid out and a row keeps its
 *  composition while rows come and go around it (the collection-view model
 *  SwiftUI's List sits on). Honours `ScrollViewProxy.scrollTo` (the row that
 *  holds the target, brought to the anchor) and `.defaultScrollAnchor(.bottom)`
 *  (opens at the end and follows growth until the reader scrolls up). */
@Composable
private fun IsoLazyList(n: UNode, column: UNode, m: Modifier, bw: Boolean) {
    val params = n.json.optJSONObject("params")
    val request = params?.optString("scrollTo") ?: ""
    val bottomAnchored = params?.optString("anchor") == "bottom"
    val rows = column.children
    // `.defaultScrollAnchor(.bottom)` (a chat): the list is laid out from its
    // bottom (reversed), as chat apps' are. Its end is where it starts, and it
    // stays put while rows arrive or grow at the end, or above it take their
    // heights; a list laid out from the top had to chase its end a frame
    // after each change, and a long thread opening was seen scrolling down.
    // Once anchored, always laid out from the bottom: a chat lets go of the
    // anchor for a moment while a reply comes in (agent_ui's holdTop), and
    // flipping the layout then would throw the list to its other end. A row
    // put in above the last (the status row) is drawn in place at the bottom.
    // `at(i)` is the row drawn at slot i.
    val anchoredOnce = remember { arrayOf(false) }
    if (bottomAnchored) anchoredOnce[0] = true
    val reversed = anchoredOnce[0]
    fun at(slot: Int) = if (reversed) rows.size - 1 - slot else slot
    val state = rememberLazyListState()
    val applied = remember { arrayOf("") }
    // Lazy rows: a row not built this frame is a placeholder the height it
    // last had (by the row's identity), and the rows shown go back to the
    // guest ("first,last") so it builds around them.
    val heights = remember { HashMap<Any, Int>() }
    val windowId = params?.optString("window") ?: ""
    // The guest's row count for this build (as the web host sends it).
    val builtRows by rememberUpdatedState(params?.optString("rows") ?: "")
    if (windowId.isNotEmpty()) {
        LaunchedEffect(state, windowId, reversed) {
            var reported = ""
            snapshotFlow {
                val visible = state.layoutInfo.visibleItemsInfo
                val count = state.layoutInfo.totalItemsCount
                // A layout of rows the build has since replaced says nothing.
                if (visible.isEmpty() || (builtRows.isNotEmpty() && builtRows != count.toString())) "" else {
                    val a = if (reversed) count - 1 - visible.first().index else visible.first().index
                    val b = if (reversed) count - 1 - visible.last().index else visible.last().index
                    // With the row count it saw: a report about rows since
                    // replaced (a thread's loading rows, arriving after its
                    // transcript) is dropped, not read as the new rows'.
                    if (builtRows.isEmpty()) "${minOf(a, b)},${maxOf(a, b)}" else "${minOf(a, b)},${maxOf(a, b)},$builtRows"
                }
            }.collect { value ->
                if (value.isNotEmpty() && value != reported) {
                    reported = value
                    sendEvent(windowId, value)
                }
            }
        }
    }
    // `onScrollGeometryChange`: where the list is scrolled to and how tall
    // its content is (rows not yet measured counted at the measured rows'
    // average), in points, reported as it changes.
    val geometryId = params?.optString("geometry") ?: ""
    val listInsets = scrollInsets(n)
    // The rows as of the latest composition: the effect below outlives the
    // composition it started in (a thread's loading rows, then its rows).
    val latestRows by rememberUpdatedState(rows)
    if (geometryId.isNotEmpty()) {
        val density = LocalDensity.current.density
        LaunchedEffect(state, geometryId, reversed) {
            var reported = ""
            snapshotFlow {
                val info = state.layoutInfo
                val visible = info.visibleItemsInfo
                if (visible.isEmpty()) return@snapshotFlow ""
                val all = latestRows
                val count = info.totalItemsCount
                // A layout of rows since replaced: wait for the new one.
                if (count != all.size) return@snapshotFlow ""
                val average = visible.sumOf { it.size }.toFloat() / visible.size
                // Measured rows by slot, the rest at the average.
                fun size(slot: Int): Float {
                    visible.firstOrNull { it.index == slot }?.let { return it.size.toFloat() }
                    val index = if (reversed) all.size - 1 - slot else slot
                    return heights[childKey(all[index], index)]?.toFloat() ?: average
                }
                var content = 0f
                for (slot in 0 until count) content += size(slot)
                var before = 0f
                for (slot in 0 until state.firstVisibleItemIndex) before += size(slot)
                before += state.firstVisibleItemScrollOffset
                val viewport = info.viewportSize.height.toFloat()
                val top = listInsets.top.value * density
                val bottom = listInsets.bottom.value * density
                // From the content's top: a reversed list counts from its end.
                val offset = if (reversed) content + bottom - viewport - before else before - top
                fun pt(px: Float) = "%.1f".format(java.util.Locale.ROOT, px / density)
                listOf(pt(0f), pt(offset), pt(info.viewportSize.width.toFloat()), pt(content),
                    pt(info.viewportSize.width.toFloat()), pt(viewport),
                    pt(top), "0", pt(bottom), "0").joinToString(",")
            }.collect { value ->
                if (value.isNotEmpty() && value != reported) {
                    reported = value
                    sendEvent(geometryId, value)
                }
            }
        }
    }
    var pinned by remember { mutableStateOf(true) }
    if (reversed) {
        // Only the reader moves the pin: a drag lets go of the end, and where
        // that scroll (and its fling) settles decides whether it is back at
        // the end (slot 0, the bottom).
        LaunchedEffect(state) {
            var dragged = false
            launch {
                state.interactionSource.interactions.collect {
                    if (it is DragInteraction.Start) { dragged = true; pinned = false }
                }
            }
            snapshotFlow { state.isScrollInProgress }.collect { scrolling ->
                if (!scrolling && dragged) { dragged = false; pinned = !state.canScrollBackward }
            }
        }
        // A row put in at the end lands at slot 0, below the row the list
        // keeps in place: while pinned, the end is taken again in the same
        // layout pass.
        val lastKey = rows.lastOrNull()?.let { childKey(it, rows.size - 1) }
        val seenLast = remember { arrayOf<Any?>(null) }
        if (bottomAnchored && pinned && seenLast[0] != null && seenLast[0] != lastKey) state.requestScrollToItem(0)
        seenLast[0] = lastKey
    }
    if (request.isNotEmpty()) {
        LaunchedEffect(request) {
            val parts = request.split("|")
            if (parts.size < 3 || applied[0] == parts[1]) return@LaunchedEffect
            val index = rows.indexOfFirst { holdsScrollTarget(it, parts[0]) }
            if (index < 0) return@LaunchedEffect
            applied[0] = parts[1]
            // The last row to the bottom of a bottom-anchored list: its end,
            // where it already rests while pinned.
            if (reversed && index == rows.size - 1 && parts[2] == "bottom") {
                pinned = true
                state.scrollToItem(0)
                return@LaunchedEffect
            }
            val slot = at(index)
            state.scrollToItem(slot)
            withFrameNanos { }
            val item = state.layoutInfo.visibleItemsInfo.firstOrNull { it.index == slot } ?: return@LaunchedEffect
            val viewport = state.layoutInfo.viewportEndOffset - state.layoutInfo.viewportStartOffset
            // Where the row is drawn, from the viewport's top (a reversed
            // list measures its rows from the bottom).
            val top = if (reversed) viewport - item.offset - item.size else item.offset
            val bottom = top + item.size
            // How far the content moves up.
            val up = when (parts[2]) {
                "bottom" -> bottom - viewport
                "top" -> top
                "center" -> top + item.size / 2 - viewport / 2
                else -> if (top < 0) top else if (bottom > viewport) bottom - viewport else 0
            }
            if (up != 0) state.scrollBy(if (reversed) -up.toFloat() else up.toFloat())
            if (reversed) pinned = !state.canScrollBackward
        }
    }
    val insets = scrollInsets(n)
    ReportScrollPhase(params?.optString("phase") ?: "", state, state.interactionSource)
    ReportScrolledUnder(n, state, reversed)
    // SwiftUI's grouped lists (inset grouped, the automatic style on a
    // phone) are Material's lists in groups: each row knows where it sits in
    // its group (the rows between two headers), for its corners.
    val grouped = isGroupedList(params)
    val places = remember(rows) { if (grouped) groupPlaces(rows) else null }
    CompositionLocalProvider(
        LocalListSeparators provides (params?.optString("separators") != "0"),
        LocalSidebarList provides (params?.optString("listStyle") == "sidebar"),
        LocalListMinRowHeight provides (params?.optString("minRowHeight")?.toFloatOrNull() ?: if (grouped) 56f else 44f),
        LocalSafeArea provides EdgeInsets(), LocalChrome provides EdgeInsets(), LocalEdgeScroll provides null,
        LocalInScroll provides true,
    ) {
    LazyColumn(if (grouped) m.background(groupedGround()) else m, state = state, horizontalAlignment = Alignment.Start,
        reverseLayout = reversed,
        // `.scrollDisabled(true)`: laid out the same, not scrollable.
        userScrollEnabled = params?.optString("scrollDisabled") != "1",
        // Rows fewer than fill it sit at its top, unless the anchor's
        // alignment role says the bottom (a chat thread's).
        verticalArrangement = if (reversed && params?.optString("anchorAlign") == "bottom") Arrangement.Bottom else Arrangement.Top,
        contentPadding = PaddingValues(top = insets.top, bottom = insets.bottom)) {
        items(rows.size, key = { childKey(rows[at(it)], at(it)) }) { slot ->
            val index = at(slot)
            val c = rows[index]
            val key = childKey(c, index)
            if (c.json.optJSONObject("params")?.optString("placeholder") == "1") {
                val px = heights[key]
                Box(Modifier.fillMaxWidth().then(if (px != null) Modifier.height(with(LocalDensity.current) { px.toDp() }) else Modifier.height(60.dp)))
            } else {
                val stretch = c.json.optBoolean("growW") && bw
                CompositionLocalProvider(LocalRowPlace provides places?.getOrNull(index)) {
                    IsoNode(
                        c, (if (stretch) Modifier.fillMaxWidth() else Modifier).onSizeChanged { heights[key] = it.height },
                        boundedW = bw, boundedH = false)
                }
            }
        }
    }
    }
}

/** A text's typeface: a named one (`Font.custom`, when the system has it),
 *  the design's (`.serif`, `.monospaced`), else the system's. */
private fun textFontFamily(params: JSONObject?): FontFamily? {
    val family = params?.optString("family") ?: ""
    if (family.isNotEmpty()) return FontFamily(android.graphics.Typeface.create(family, android.graphics.Typeface.NORMAL))
    return when {
        params?.optString("mono") == "1" -> FontFamily.Monospace
        params?.optString("design") == "serif" -> FontFamily.Serif
        else -> null
    }
}

/** A list row's padding: `.listRowInsets` ("top,leading,bottom,trailing",
 *  "-" for a side left to the list), each side the list's otherwise. */
private fun rowInsetsPadding(params: JSONObject, vertical: Float, horizontal: Float): PaddingValues {
    val parts = params.optString("rowInsets").split(",")
    fun side(i: Int, standard: Float) = if (parts.size == 4) parts[i].toFloatOrNull() ?: standard else standard
    return PaddingValues(start = side(1, horizontal).dp, top = side(0, vertical).dp, end = side(3, horizontal).dp, bottom = side(2, vertical).dp)
}

/** Where a grouped list's row sits in its group: its corners. */
internal data class RowPlace(val first: Boolean, val last: Boolean)

/** The row being drawn's place in its group, in a grouped list (null in a
 *  plain one, or outside a list). */
private val LocalRowPlace = compositionLocalOf<RowPlace?> { null }

/** Whether the list being drawn is a sidebar (`.listStyle(.sidebar)`). */
private val LocalSidebarList = compositionLocalOf { false }

/** A sidebar's row, as a navigation drawer's item is: on the list's ground,
 *  no lines between rows; selected, a system-blue rounded fill 12dp in from
 *  the sides, its text white. */
@Composable
private fun SidebarListRow(n: UNode, m: Modifier, params: JSONObject, bw: Boolean, bh: Boolean) {
    val selected = params.optString("selected") == "1" && params.optString("rowOwnBg") != "1"
    val blue = if (isSystemInDarkTheme()) Color(0xFF0A84FF) else Color(0xFF007AFF)
    val padding = rowInsetsPadding(params, 10f, 16f)
    Box(
        m.fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 1.dp)
            .clip(RoundedCornerShape(16.dp))
            .then(if (selected) Modifier.background(blue) else Modifier)
    ) {
        // A swipe row slides on the sidebar's own ground (or the selection's
        // blue): Material's surface stood in a lighter box on it.
        CompositionLocalProvider(
            LocalRowContainer provides (if (selected) blue else pageGround()),
            LocalContentColor provides (if (selected) Color.White else LocalContentColor.current),
            LocalOnSelection provides selected,
        ) {
            Box(
                Modifier.fillMaxWidth().defaultMinSize(minHeight = LocalListMinRowHeight.current.dp).padding(padding),
                contentAlignment = Alignment.CenterStart,
            ) {
                for ((i, c) in n.children.withIndex()) key(childKey(c, i)) { IsoNode(c, boxChildModifier(c), bw, bh) }
            }
        }
    }
}

/** Whether what is drawn sits on a selected row's system-blue fill. */
private val LocalOnSelection = compositionLocalOf { false }

/** A colour as it reads on a selected row: white, at the colour's own
 *  opacity (a secondary line stays the lighter one, as iOS draws the text of
 *  a selected cell). The guest resolved it before the row was selected. */
@Composable
private fun onSelection(color: Color): Color =
    if (LocalOnSelection.current) Color.White.copy(alpha = color.alpha) else color

/** The ground of the row being drawn (what a swipe row's content slides on). */
private val LocalRowContainer = compositionLocalOf { Color.Unspecified }

/** The row's padding, taken by a swipe row's sliding content instead of the
 *  cell (so the whole cell slides). */
private val LocalSwipePadding = compositionLocalOf { PaddingValues(0.dp) }

/** Whether a list's style is a grouped one: anything but plain and the
 *  sidebar's (SwiftUI's automatic style on a phone is inset grouped). */
internal fun isGroupedList(params: JSONObject?): Boolean {
    val style = params?.optString("listStyle") ?: ""
    return style != "plain" && style != "sidebar"
}

/** Each row's place in its group: headers (a section's start) and footers
 *  (its end) end one. */
private fun groupPlaces(rows: List<UNode>): List<RowPlace?> {
    fun cell(c: UNode) = c.json.optJSONObject("params")?.optString("cell") ?: ""
    fun bounds(c: UNode) = cell(c).let { it == "header" || it == "footer" }
    val out = ArrayList<RowPlace?>(rows.size)
    for (i in rows.indices) {
        if (bounds(rows[i])) {
            out.add(RowPlace(first = i == 0, last = false))
            continue
        }
        val first = i == 0 || bounds(rows[i - 1])
        val last = i == rows.size - 1 || bounds(rows[i + 1])
        out.add(RowPlace(first, last))
    }
    return out
}

/** The ground a pane shows behind its content: a backdrop the content
 *  draws, a grouped list's container tone, else the page's. */
@Composable
internal fun paneGround(node: UNode?): Color {
    backdropColor(node)?.let { return it }
    val content = if (node?.json?.optString("k") == "hostView" && node.json.optString("view") == "navstack")
        contentChildren(node).firstOrNull() else node
    val p = edgeScroll(content)?.json?.optJSONObject("params")
    if (p?.optString("list") == "1" && isGroupedList(p)) return groupedGround()
    return MaterialTheme.colorScheme.background
}

/** What a grouped list sits on: Material's container tone under its rows. */
@Composable
internal fun groupedGround(): Color = MaterialTheme.colorScheme.surfaceContainer

/** A grouped list's row: a segment of its group. */
@Composable
internal fun groupedRowContainer(): Color =
    if (isSystemInDarkTheme()) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest

@Composable
private fun GroupedRow(n: UNode, m: Modifier, params: JSONObject, place: RowPlace, bw: Boolean, bh: Boolean) {
    // A row with a view behind it (`.listRowBackground(view)`) draws its
    // own ground and selection: the segment is its shape alone.
    val ownBg = params.optString("rowOwnBg") == "1"
    val selected = params.optString("selected") == "1" && !ownBg
    val outer = 20.dp
    val inner = 4.dp
    val shape = RoundedCornerShape(
        topStart = if (place.first) outer else inner, topEnd = if (place.first) outer else inner,
        bottomStart = if (place.last) outer else inner, bottomEnd = if (place.last) outer else inner,
    )
    // `.listRowBackground`, or the selection, or the segment's tone.
    val rowBg = params.optString("rowBg").takeIf { it.isNotEmpty() }?.let { hex ->
        runCatching { Color(android.graphics.Color.parseColor(if (hex.startsWith("#")) hex else "#$hex")) }.getOrNull()
    }
    // Selected: the system blue, its text white (the selected row just
    // changes its background colour to the system blue).
    val container = when {
        ownBg -> Color.Transparent
        selected -> if (isSystemInDarkTheme()) Color(0xFF0A84FF) else Color(0xFF007AFF)
        rowBg != null -> rowBg
        else -> groupedRowContainer()
    }
    // Material's list item metrics, unless the app set its own
    // (`.listRowInsets`).
    val rowPadding = rowInsetsPadding(params, 12f, 16f)
    // A swipe row slides the whole segment: it takes the padding.
    val swipes = n.children.singleOrNull()?.json?.optJSONObject("params")?.optString("swipe")?.isNotEmpty() == true
    Box(
        m.fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, bottom = if (place.last) 0.dp else 2.dp)
            .clip(shape)
            .background(container)
    ) {
        CompositionLocalProvider(
            LocalRowContainer provides container,
            LocalSwipePadding provides (if (swipes) rowPadding else PaddingValues(0.dp)),
            LocalContentColor provides (if (selected) Color.White else LocalContentColor.current),
            LocalOnSelection provides selected,
        ) {
            // The row's own background (`.listRowBackground(view)`) fills the
            // segment, padding and all; the content sits in the padding.
            fun layer(c: UNode) = c.json.optJSONObject("params")?.optString("layer") ?: ""
            Box(Modifier.fillMaxWidth()) {
                for (c in n.children) if (layer(c) == "background") IsoLayer(c, bw, bh)
                Box(
                    Modifier.fillMaxWidth()
                        .defaultMinSize(minHeight = LocalListMinRowHeight.current.dp)
                        .then(if (swipes) Modifier else Modifier.padding(rowPadding)),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    for ((i, c) in n.children.withIndex()) if (layer(c).isEmpty()) key(childKey(c, i)) {
                        IsoNode(c, if (swipes) Modifier.fillMaxWidth() else boxChildModifier(c), bw, bh)
                    }
                }
                for (c in n.children) if (layer(c) == "overlay") IsoLayer(c, bw, bh)
            }
        }
    }
}

/** Whether the list being drawn shows lines between its rows (the list's
 *  `separators` param; rows can still hide their own). */
private val LocalListSeparators = compositionLocalOf { true }

/** The least a row of the list being drawn is tall: the platform's 44, or
 *  the list's `\.defaultMinListRowHeight` (its `minRowHeight` param). */
private val LocalListMinRowHeight = compositionLocalOf { 44f }

/** Whether the subtree holds the view `.id(target)` names. */
private fun holdsScrollTarget(n: UNode, target: String): Boolean {
    if (n.json.optJSONObject("params")?.optString("vid") == target) return true
    return n.children.any { holdsScrollTarget(it, target) }
}

/** The tree's root: the app's content, and any presentations over it.
 *  With a sheet or alert up the guest wraps the content in a layer stack
 *  beside them; the content is drawn from the same place either way, so it
 *  keeps its state (the pane a compact split shows, a list's scroll) while
 *  something is presented over it. Presentations draw in their own windows. */
// Safe areas and chrome insets (docs/renderer_layers.md, "bars"), as on the
// web: the app draws edge to edge; chrome at an edge (a navigation stack's
// bar, a `.safeAreaInset` bar) takes that edge's safe area (the status bar;
// the navigation bar or keyboard) and pins over the content; the screen's
// outermost vertical scroll flows beneath it, taking the chrome as its
// content padding, so it still scrolls fully to its first and last rows.

internal data class EdgeInsets(val top: Dp = 0.dp, val bottom: Dp = 0.dp)

/** The device's safe area not yet taken by chrome. */
internal val LocalSafeArea = compositionLocalOf { EdgeInsets() }

/** Chrome pinned over the content, for the screen's edge scroll to inset by. */
internal val LocalChrome = compositionLocalOf { EdgeInsets() }

/** The scroll that takes `LocalChrome` (compared by identity). */
internal val LocalEdgeScroll = compositionLocalOf<UNode?> { null }

private fun contentChildren(n: UNode): List<UNode> =
    n.children.filter { (it.json.optJSONObject("params")?.optString("layer") ?: "").isEmpty() }

/** The fill of the backdrop the content paints behind itself (a Form's
 *  grouped ground: a full-bleed shape under the scroll in a ZStack), found
 *  through plain wrappers and a navigation stack; null when it paints none. */
internal fun backdropColor(start: UNode?): Color? {
    var node = start
    repeat(32) {
        val n = node ?: return null
        val j = n.json
        val ch = contentChildren(n)
        when {
            j.optString("k") == "hostView" && j.optString("view") == "navstack" -> node = ch.firstOrNull()
            j.optString("k") == "stack" && j.optString("axis") == "z" -> {
                val first = ch.firstOrNull() ?: return null
                if (first.json.optString("k") != "shape" || !first.json.optBoolean("expandH")) return null
                return colorOf(first.json, "fill")
            }
            (j.optString("k") == "box" || (j.optString("k") == "stack" && j.optString("axis") == "v")) && ch.size == 1 -> node = ch[0]
            else -> return null
        }
    }
    return null
}

/** The outermost vertical scroll the content reaches through plain wrappers
 *  (boxes, single-child columns, a backdrop's ZStack, an inset stack's
 *  content side), or null when the content is not a scroll. */
internal fun edgeScroll(start: UNode?): UNode? {
    var node = start
    // Deep enough for a screen's modifiers: at ten wrappers, Visor 0.29's
    // thread (an overlay more) was not found, and its bar lost the colour
    // it takes with content under it.
    repeat(32) {
        val n = node ?: return null
        val j = n.json
        val kind = j.optString("k")
        if (kind == "scroll") return if (j.optString("axis") == "h") null else n
        val inset = j.optJSONObject("params")?.optString("inset") ?: ""
        val ch = contentChildren(n)
        node = when {
            kind == "stack" && inset.isNotEmpty() && ch.size == 2 -> ch[if (inset == "top") 1 else 0]
            kind == "stack" && j.optString("axis") == "z" -> ch.filter { it.json.optString("k") != "shape" && it.json.optString("k") != "gradient" }.singleOrNull() ?: return null
            (kind == "box" || (kind == "stack" && j.optString("axis") == "v")) && ch.size == 1 -> ch[0]
            else -> return null
        }
    }
    return null
}

/** Whether the content has chrome (or an edge scroll) that takes the safe
 *  area at the top or the bottom edge; the screen pads the edges it doesn't. */
private fun takesEdge(n: UNode?, top: Boolean): Boolean {
    n ?: return false
    val j = n.json
    val kind = j.optString("k")
    val view = j.optString("view")
    val inset = j.optJSONObject("params")?.optString("inset") ?: ""
    val ch = contentChildren(n)
    return when {
        kind == "hostView" && view == "navstack" ->
            top || takesEdge(if (j.optJSONObject("params")?.optString("principalContent") == "1") ch.firstOrNull() else ch.singleOrNull(), false)
        kind == "hostView" && view == "navsplit" -> ch.isNotEmpty() && ch.all { takesEdge(it, top) }
        kind == "hostView" && view == "tabs" -> !top || (ch.isNotEmpty() && ch.all { takesEdge(it, true) })
        kind == "scroll" -> !top && j.optString("axis") != "h"
        kind == "stack" && inset.isNotEmpty() && ch.size == 2 ->
            if ((inset == "top") == top) true else takesEdge(ch[if (inset == "top") 1 else 0], top)
        kind == "stack" && j.optString("axis") == "z" ->
            takesEdge(ch.filter { it.json.optString("k") != "shape" && it.json.optString("k") != "gradient" }.singleOrNull(), top)
        (kind == "box" || (kind == "stack" && j.optString("axis") == "v")) && ch.size == 1 -> takesEdge(ch[0], top)
        else -> false
    }
}

/** A screen's content, edge to edge: the safe area goes to the chrome that
 *  takes it, and the screen pads the edges nothing takes. Its sides keep
 *  clear of a navigation bar beside the screen (three-button navigation in
 *  landscape) and of a display cutout there, as SwiftUI's safe area keeps
 *  content from a phone's sides in landscape; the page's ground runs on
 *  under them. */
@Composable
internal fun SafeAreaScreen(content: UNode, body: @Composable () -> Unit) {
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val status = with(density) { WindowInsets.statusBars.getTop(density).toDp() }
    val bottom = with(density) { maxOf(WindowInsets.navigationBars.getBottom(density), WindowInsets.ime.getBottom(density)).toDp() }
    val sides = WindowInsets.navigationBars.union(WindowInsets.displayCutout)
    val left = with(density) { sides.getLeft(density, direction).toDp() }
    val right = with(density) { sides.getRight(density, direction).toDp() }
    val top = takesEdge(content, true)
    val below = takesEdge(content, false)
    Box(Modifier.fillMaxSize().background(pageGround()).absolutePadding(left = left, right = right)
        .padding(top = if (top) 0.dp else status, bottom = if (below) 0.dp else bottom)) {
        CompositionLocalProvider(LocalSafeArea provides EdgeInsets(if (top) status else 0.dp, if (below) bottom else 0.dp)) {
            body()
        }
    }
}

/** `.safeAreaInset(edge:)`: the bar pinned at that edge over the content,
 *  in the edge's safe area (on the keyboard when it is up); the content's
 *  edge scroll takes the bar's height as its inset. */
@Composable
private fun IsoInsetStack(n: UNode, m: Modifier, bw: Boolean, bh: Boolean) {
    // A screen's `.bottomBar` toolbar (iOS 26's floating bar of a search
    // field and a button) in Material's shapes, when it is only those.
    if (MaterialBottomBar(n, m, bw, bh)) return
    val atTop = n.json.optJSONObject("params")?.optString("inset") == "top"
    val main = n.children[if (atTop) 1 else 0]
    val bar = n.children[if (atTop) 0 else 1]
    val safe = LocalSafeArea.current
    val chrome = LocalChrome.current
    val density = LocalDensity.current
    val target = edgeScroll(main)
    // Over a scroll the bar (a composer) is on the page's ground, opaque:
    // the rows pass under it out of sight, as under a Material bottom bar.
    val ground = backdropColor(main) ?: pageGround()
    // The bar is measured first and the content composed with its height in
    // the same pass (as Scaffold does): a height learned after the frame
    // (onSizeChanged) reached the content's inset a frame late, and a thread
    // opened with its last rows under the composer for that frame.
    SubcomposeLayout(m) { constraints ->
        val barPlaceables = subcompose("bar") {
            Box(
                // As tall as its content (measured without the screen's
                // height, which a greedy view in it would otherwise take whole).
                Modifier.fillMaxWidth()
                    .wrapContentHeight(unbounded = true)
                    .then(if (target != null) Modifier.background(ground) else Modifier)
                    .padding(top = if (atTop) safe.top else 0.dp, bottom = if (atTop) 0.dp else safe.bottom)
            ) {
                // (Only a scroll passes under the bar: see IsoNavStack.)
                CompositionLocalProvider(LocalSafeArea provides EdgeInsets(), LocalChrome provides EdgeInsets(), LocalEdgeScroll provides null) {
                    IsoNode(bar, Modifier.fillMaxWidth(), bw, false)
                }
            }
        }.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
        val barPx = barPlaceables.maxOfOrNull { it.height } ?: 0
        val barHeight = with(density) { barPx.toDp() }
        val inner = if (atTop) EdgeInsets(barHeight, chrome.bottom) else EdgeInsets(chrome.top, barHeight)
        val mainPlaceables = subcompose("main") {
            CompositionLocalProvider(
                LocalSafeArea provides (if (atTop) safe.copy(top = 0.dp) else safe.copy(bottom = 0.dp)),
                LocalChrome provides (if (target != null) inner else EdgeInsets()),
                LocalEdgeScroll provides target,
            ) {
                Box(Modifier.fillMaxSize()
                    .then(if (target != null) Modifier else Modifier.padding(top = inner.top, bottom = inner.bottom))) {
                    IsoNode(main, Modifier.fillMaxSize(), bw, bh)
                }
            }
        }.map { it.measure(constraints) }
        val width = maxOf(constraints.minWidth, mainPlaceables.maxOfOrNull { it.width } ?: 0)
        val height = maxOf(constraints.minHeight, mainPlaceables.maxOfOrNull { it.height } ?: 0)
        layout(width, height) {
            mainPlaceables.forEach { it.place(0, 0) }
            // Over the content, at its edge.
            barPlaceables.forEach { it.place((width - it.width) / 2, if (atTop) 0 else height - it.height) }
        }
    }
}

/** A `.bottomBar` toolbar that is a search field and a button (with spacers)
 *  as Android draws them: the field a Material search bar at the top of the
 *  screen, under its title; the button a floating action button at the
 *  bottom end, with its label when it has one (Gmail's Compose). Anything
 *  else in the bar keeps iOS's row (false). */
@Composable
private fun MaterialBottomBar(n: UNode, m: Modifier, bw: Boolean, bh: Boolean): Boolean {
    val params = n.json.optJSONObject("params") ?: return false
    val kinds = params.optString("bottomBar").takeIf { it.isNotEmpty() }?.split("\n") ?: return false
    if (params.optString("inset") != "bottom" || n.children.size != 2) return false
    if (kinds.any { it !in setOf("search", "button", "fixed", "flex") }) return false
    if (kinds.count { it == "search" } > 1 || kinds.count { it == "button" } > 1) return false
    // The row's views, in the kinds' order (a fixed spacer has none).
    val row = n.children[1].children.singleOrNull() ?: return false
    var next = 0
    var searchNode: UNode? = null
    var buttonNode: UNode? = null
    for (kind in kinds) {
        if (kind == "fixed") continue
        val view = row.children.getOrNull(next++) ?: return false
        if (kind == "search") searchNode = view
        if (kind == "button") buttonNode = view
    }
    val field = searchNode?.let { findKind(it, "textField") }
    if (searchNode != null && field == null) return false
    val tap = buttonNode?.let { findTap(it) }
    if (buttonNode != null && tap == null) return false
    val main = n.children[0]
    val safe = LocalSafeArea.current
    val chrome = LocalChrome.current
    val target = edgeScroll(main)
    // The content clears the button: its scroll runs on under it.
    val fabRoom = if (tap != null) 88.dp else 0.dp
    Box(m.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            if (field != null) MaterialSearchBar(field, Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp))
            Box(Modifier.weight(1f).fillMaxWidth()) {
                val inner = EdgeInsets(chrome.top, safe.bottom + fabRoom)
                CompositionLocalProvider(
                    LocalSafeArea provides safe.copy(bottom = 0.dp),
                    LocalChrome provides (if (target != null) inner else EdgeInsets()),
                    LocalEdgeScroll provides target,
                ) {
                    Box(Modifier.fillMaxSize().then(if (target != null) Modifier else Modifier.padding(bottom = inner.bottom))) {
                        IsoNode(main, Modifier.fillMaxSize(), bw, bh)
                    }
                }
            }
        }
        if (tap != null && buttonNode != null) {
            val symbol = findSymbol(buttonNode)
            val label = findLabel(buttonNode)
            val icon: @Composable () -> Unit = {
                Symbols.table[symbol]?.let { Icon(symbolVector(it), contentDescription = if (label.isEmpty()) null else label, modifier = Modifier.size(24.dp)) }
            }
            val place = Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 16.dp + safe.bottom)
            if (label.isNotEmpty()) {
                ExtendedFloatingActionButton(onClick = { sendEvent(tap, "") }, modifier = place, icon = icon, text = { Text(label) })
            } else {
                FloatingActionButton(onClick = { sendEvent(tap, "") }, modifier = place) { icon() }
            }
        }
    }
    return true
}

/** Material's search bar (a full-width pill in the high container tone)
 *  around the guest's search field. */
@Composable
private fun MaterialSearchBar(field: UNode, modifier: Modifier) {
    val j = field.json
    val value = j.optString("v")
    Row(
        modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(12.dp))
        Box(Modifier.weight(1f)) {
            CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
                IsoTextField(
                    id = j.optString("id"), value = value, placeholder = j.optString("placeholder"),
                    editID = j.optString("edit"), search = true, modifier = Modifier, plain = true,
                    focusID = j.optJSONObject("params")?.optString("focusId") ?: "",
                    focusWanted = j.optJSONObject("params")?.optString("focus") == "1",
                    submitID = j.optJSONObject("params")?.optString("submit") ?: "",
                )
            }
        }
        if (value.isNotEmpty()) {
            IconButton(onClick = { sendEvent(j.optString("edit"), "") }) {
                Icon(Icons.Filled.Close, contentDescription = "Clear the search", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            Spacer(Modifier.width(12.dp))
        }
    }
}

/** The first node of a kind in a subtree. */
private fun findKind(n: UNode, kind: String): UNode? {
    if (n.json.optString("k") == kind) return n
    for (c in n.children) findKind(c, kind)?.let { return it }
    return null
}

/** The first tap action in a subtree (a button's). */
private fun findTap(n: UNode): String? {
    n.json.optString("tap").takeIf { it.isNotEmpty() }?.let { return it }
    for (c in n.children) findTap(c)?.let { return it }
    return null
}

/** The first symbol a subtree draws (an icon button's glyph). */
private fun findSymbol(n: UNode): String {
    n.json.optJSONObject("params")?.optString("symbol")?.takeIf { it.isNotEmpty() }?.let { return it }
    for (c in n.children) findSymbol(c).takeIf { it.isNotEmpty() }?.let { return it }
    return ""
}

/** What a subtree is called (its accessibility label: an icon-only
 *  Label's title). */
private fun findLabel(n: UNode): String {
    val p = n.json.optJSONObject("params")
    if (p != null && p.has("a11yLabel")) return p.optString("a11yLabel")
    for (c in n.children) findLabel(c).takeIf { it.isNotEmpty() }?.let { return it }
    return ""
}

@Composable
fun IsoRoot(root: UNode) {
    val presented = root.json.optString("k") == "stack" && root.json.optString("axis") == "z" &&
        root.children.size > 1 && root.children.drop(1).all { it.json.optString("k") == "presentation" }
    val content = if (presented) root.children[0] else root
    SafeAreaScreen(content) { IsoNode(content, Modifier, boundedH = true) }
    if (presented) {
        for ((i, p) in root.children.drop(1).withIndex()) key(childKey(p, i + 1)) { IsoNode(p, Modifier, boundedH = true) }
    }
}

/** `pointerInput` that also takes a pointer outside this node's bounds when
 *  it lands on a descendant drawn there (moved or zoomed by `.offset` /
 *  `.scaleEffect`), as SwiftUI's gestures do. Compose skips an ancestor's
 *  pointer handler out of its bounds unless the node intercepts. */
private fun Modifier.pointerInputOverChildren(key: String, handler: suspend PointerInputScope.() -> Unit): Modifier =
    this then OverChildrenPointerElement(key, handler)

private class OverChildrenPointerElement(
    val key: String,
    val handler: suspend PointerInputScope.() -> Unit,
) : ModifierNodeElement<OverChildrenPointerNode>() {
    override fun create() = OverChildrenPointerNode(handler)
    override fun update(node: OverChildrenPointerNode) { node.inner.pointerInputHandler = handler }
    // Handlers only name ids, so the key alone decides a restart.
    override fun equals(other: Any?) = other is OverChildrenPointerElement && other.key == key
    override fun hashCode() = key.hashCode()
}

private class OverChildrenPointerNode(handler: suspend PointerInputScope.() -> Unit) : DelegatingNode(), PointerInputModifierNode {
    val inner = delegate(SuspendingPointerInputModifierNode(handler))
    override fun onPointerEvent(pointerEvent: PointerEvent, pass: PointerEventPass, bounds: IntSize) =
        inner.onPointerEvent(pointerEvent, pass, bounds)
    override fun onCancelPointerInput() = inner.onCancelPointerInput()
    override fun interceptOutOfBoundsChildEvents() = true
}

/** `onTapGesture(count: 2)`: two taps close in time and place. Unlike
 *  detectTapGestures it keeps a pointer outside the node's own bounds, so a
 *  view drawn moved or zoomed inside it (`.offset`/`.scaleEffect`) takes the
 *  taps wherever it is drawn, as SwiftUI hit-tests it. A tap that turns into
 *  a drag or pinch (consumed by guestGestures) doesn't count. */
private fun Modifier.doubleTap(id: String): Modifier = pointerInputOverChildren(id) {
    suspend fun AwaitPointerEventScope.tapUp(down: PointerInputChange): Boolean {
        while (true) {
            val event = awaitPointerEvent()
            if (event.changes.any { it.isConsumed }) return false
            if ((event.changes[0].position - down.position).getDistance() > viewConfiguration.touchSlop) return false
            if (event.changes.none { it.pressed }) return true
        }
    }
    awaitEachGesture {
        val first = awaitFirstDown(requireUnconsumed = false)
        if (!tapUp(first)) return@awaitEachGesture
        val second = withTimeoutOrNull(viewConfiguration.doubleTapTimeoutMillis) {
            awaitFirstDown(requireUnconsumed = false)
        } ?: return@awaitEachGesture
        if ((second.position - first.position).getDistance() > viewConfiguration.touchSlop * 4) return@awaitEachGesture
        if (tapUp(second)) sendEvent(id, "")
    }
}

/** Tracks a view's `.gesture`: once the fingers move past the touch slop
 *  (or pinch), the running translation (in points) goes to the drag handler
 *  and the magnification to the pinch handler, and "ended" to both when
 *  the last finger lifts. The gesture then owns the pointers (as a SwiftUI
 *  gesture does over a scroll view it sits in). */
private fun Modifier.guestGestures(dragID: String, magnifyID: String): Modifier = pointerInputOverChildren(dragID + "|" + magnifyID) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        var zoom = 1f
        var pan = androidx.compose.ui.geometry.Offset.Zero
        var active = false
        do {
            val event = awaitPointerEvent()
            zoom *= event.calculateZoom()
            pan += event.calculatePan()
            if (!active) {
                val pinching = magnifyID.isNotEmpty() && kotlin.math.abs(zoom - 1f) > 0.02f
                val dragging = dragID.isNotEmpty() && pan.getDistance() > viewConfiguration.touchSlop
                active = pinching || dragging
            }
            if (active) {
                if (magnifyID.isNotEmpty()) sendEvent(magnifyID, "changed:$zoom")
                if (dragID.isNotEmpty()) sendEvent(dragID, "changed:${pan.x / density},${pan.y / density}")
                event.changes.forEach { it.consume() }
            }
        } while (event.changes.any { it.pressed })
        if (active) {
            if (magnifyID.isNotEmpty()) sendEvent(magnifyID, "ended:$zoom")
            if (dragID.isNotEmpty()) sendEvent(dragID, "ended:${pan.x / density},${pan.y / density}")
        }
    }
}
