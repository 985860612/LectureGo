package com.aiyu.screenmon.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.Shapes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

/** Flat, low-glare palette with one cyan accent and no elevation/shadows. */
private val ScreenMonColors = darkColorScheme(
    primary = Color(0xFF4FC3F7),          // calm cyan accent
    onPrimary = Color(0xFF00131D),
    secondary = Color(0xFF4FC3F7),
    background = Color(0xFF0B0E11),        // near-black, easy on the eyes
    onBackground = Color(0xFFE3E6E8),
    surface = Color(0xFF161A1F),
    onSurface = Color(0xFFE3E6E8),
    surfaceVariant = Color(0xFF22272E),
    onSurfaceVariant = Color(0xFFB4BCC4),
    error = Color(0xFFEF5350),
    outline = Color(0xFF343A42),
)

private val FlatShapes = Shapes(
    extraSmall = RoundedCornerShape(3.dp),
    small = RoundedCornerShape(3.dp),
    medium = RoundedCornerShape(3.dp),
    large = RoundedCornerShape(3.dp),
    extraLarge = RoundedCornerShape(3.dp),
)

@Composable
fun ScreenMonTheme(content: @Composable () -> Unit) =
    MaterialTheme(colorScheme = ScreenMonColors, shapes = FlatShapes, content = content)
