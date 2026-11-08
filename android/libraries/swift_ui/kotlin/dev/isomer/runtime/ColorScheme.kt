package dev.isomer.runtime

// The Material colour scheme Isomer's Android apps draw in, compiled (IsoTree)
// or remote (IsomerRemote) alike: Swift-free, with the interpreter.

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/** The Material scheme for the system's appearance, as Swift is told it:
 * Material 3's tonal roles (its surfaces and containers, not iOS's white and
 * grey), seeded from the accent SwiftUI resolves (`Color.accentColor`, the
 * system blue) so Material's own controls and the app's tinted views agree.
 * Swift's named grounds (a grouped list's, a cell's, a sheet's) are drawn in
 * these roles too (`MaterialGrounds`). */
fun isoColorScheme(dark: Boolean): ColorScheme =
    if (dark) darkColorScheme(
        primary = Color(0xFF9ECAFF), onPrimary = Color(0xFF003258),
        primaryContainer = Color(0xFF00497D), onPrimaryContainer = Color(0xFFD1E4FF),
        secondary = Color(0xFFBBC7DB), onSecondary = Color(0xFF253140),
        secondaryContainer = Color(0xFF3B4858), onSecondaryContainer = Color(0xFFD7E3F7),
        tertiary = Color(0xFFD6BEE4), onTertiary = Color(0xFF3B2948),
        tertiaryContainer = Color(0xFF523F5F), onTertiaryContainer = Color(0xFFF2DAFF),
        background = Color(0xFF111418), onBackground = Color(0xFFE1E2E8),
        surface = Color(0xFF111418), onSurface = Color(0xFFE1E2E8),
        surfaceVariant = Color(0xFF42474E), onSurfaceVariant = Color(0xFFC2C7CF),
        surfaceContainerLowest = Color(0xFF0C0E13), surfaceContainerLow = Color(0xFF191C20),
        surfaceContainer = Color(0xFF1D2024), surfaceContainerHigh = Color(0xFF282A2F),
        surfaceContainerHighest = Color(0xFF33353A), surfaceBright = Color(0xFF37393E), surfaceDim = Color(0xFF111418),
        outline = Color(0xFF8C9199), outlineVariant = Color(0xFF42474E),
        inverseSurface = Color(0xFFE1E2E8), inverseOnSurface = Color(0xFF2E3135), inversePrimary = Color(0xFF0061A4),
    )
    else lightColorScheme(
        primary = Color(0xFF0061A4), onPrimary = Color(0xFFFFFFFF),
        primaryContainer = Color(0xFFD1E4FF), onPrimaryContainer = Color(0xFF001D36),
        secondary = Color(0xFF535F70), onSecondary = Color(0xFFFFFFFF),
        secondaryContainer = Color(0xFFD7E3F7), onSecondaryContainer = Color(0xFF101C2B),
        tertiary = Color(0xFF6B5778), onTertiary = Color(0xFFFFFFFF),
        tertiaryContainer = Color(0xFFF2DAFF), onTertiaryContainer = Color(0xFF251431),
        background = Color(0xFFF8F9FF), onBackground = Color(0xFF191C20),
        surface = Color(0xFFF8F9FF), onSurface = Color(0xFF191C20),
        surfaceVariant = Color(0xFFDFE2EB), onSurfaceVariant = Color(0xFF42474E),
        surfaceContainerLowest = Color(0xFFFFFFFF), surfaceContainerLow = Color(0xFFF2F3FA),
        surfaceContainer = Color(0xFFECEEF4), surfaceContainerHigh = Color(0xFFE6E8EE),
        surfaceContainerHighest = Color(0xFFE0E2E8), surfaceBright = Color(0xFFF8F9FF), surfaceDim = Color(0xFFD8DAE0),
        outline = Color(0xFF73777F), outlineVariant = Color(0xFFC2C7CF),
        inverseSurface = Color(0xFF2E3135), inverseOnSurface = Color(0xFFEFF0F7), inversePrimary = Color(0xFF9ECAFF),
    )
