package dev.isomer.runtime

// The chrome SwiftUI draws in glass on iOS 26 (bar items, the scroll edge
// under a bar, `Material` and `.glassEffect` fills) is Material's here: this
// renderer builds the UI from the platform's components, and Material has no
// blur. A bar is an opaque band in the page's colour that takes Material's
// "scrolled" container colour while content is under it; its items are plain
// icon and text buttons; a material fill is an opaque tonal surface.
//
// (Until 0.20 these were blurred: the content recorded itself into a graphics
// layer and each surface drew it through a RenderEffect. That cost a 2019
// mid-range phone's GPU about 20 ms on every frame the content changed.)

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/** Whether the screen's scroll has content under the bar pinned over it:
 *  written by the scroll, read by the bar's band. */
internal class BarScroll {
    var under by mutableStateOf(false)
}

/** The pinned bar's scroll report, for the scroll under it (null: no bar). */
internal val LocalBarScroll = compositionLocalOf<BarScroll?> { null }

/** The colour of what this subtree sits on when it is not the screen's
 *  background (a split view's sidebar, a sheet): what a bar over a scroll
 *  there is filled with. */
internal val LocalGround = compositionLocalOf { Color.Unspecified }

/** The ground here: `LocalGround`, else the theme's background. */
@Composable
internal fun pageGround(): Color =
    LocalGround.current.takeIf { it.isSpecified } ?: MaterialTheme.colorScheme.background

/** A bar item: an icon button (`icon`), or a text button in the bar's
 *  content colour. Disabled (`enabled` false: `.disabled(true)` on the
 *  item's button), it takes no press and its content is Material's
 *  disabled 38%. */
@Composable
internal fun BarButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: Boolean = false,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    if (icon) {
        IconButton(onClick = onClick, modifier = modifier, enabled = enabled) { content() }
    } else {
        val color = LocalContentColor.current
        TextButton(
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            colors = ButtonDefaults.textButtonColors(contentColor = color, disabledContentColor = color.copy(alpha = 0.38f)),
        ) { content() }
    }
}

/** SwiftUI's own material tints (white, and the dark scheme's grey: see
 *  Material.swift), as opposed to a colour the app tinted glass with. */
private fun isNeutralMaterial(tint: Color): Boolean {
    fun near(a: Float, b: Float) = abs(a - b) < 0.02f
    return (near(tint.red, 1f) && near(tint.green, 1f) && near(tint.blue, 1f)) ||
        (near(tint.red, 60f / 255f) && near(tint.green, 60f / 255f) && near(tint.blue, 67f / 255f))
}

/** A material fill (`.background(.thinMaterial, in:)`, `.glassEffect`) in
 *  `shape`: an opaque tonal surface (the container colour Material gives a
 *  text field or a search bar), or the app's tint over the surface. */
@Composable
internal fun MaterialSurface(
    shape: Shape,
    tint: Color,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val fill = if (isNeutralMaterial(tint)) scheme.surfaceContainerHigh else tint.compositeOver(scheme.surface)
    Box(modifier.clip(shape).background(fill), content = content)
}

/** The line under a hard scroll edge. */
internal val HardEdgeLine = 0.5.dp

/** What a bar pinned at the top of the screen sits on, from the screen's top
 *  to the bar's bottom: the page's `ground`, opaque, and Material's scrolled
 *  container colour while content is under it (a top app bar's "on scroll"
 *  state). `hard` (`.scrollEdgeEffectStyle(.hard)`): the ground throughout,
 *  ending in a line (the last `HardEdgeLine` of this box). */
@Composable
internal fun BarBand(ground: Color, scrolledUnder: Boolean, hard: Boolean, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val container by animateColorAsState(
        if (scrolledUnder && !hard) scheme.surfaceContainer else ground,
        spring(stiffness = Spring.StiffnessMediumLow),
        label = "bar",
    )
    val line = scheme.outlineVariant
    val linePx = with(LocalDensity.current) { HardEdgeLine.toPx() }
    Box(
        modifier.drawBehind {
            if (hard) {
                val lineTop = size.height - linePx
                drawRect(container, size = Size(size.width, lineTop))
                drawRect(line, topLeft = Offset(0f, lineTop), size = Size(size.width, size.height - lineTop))
            } else {
                drawRect(container)
            }
        },
    )
}
