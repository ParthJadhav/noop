package com.noop.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.noop.analytics.RouteMath

/** Draws a GPS route as a polyline on a blank canvas — no map tiles, fully offline. */
@Composable
fun RouteCanvas(polyline: String, modifier: Modifier = Modifier) {
    // PERF (#scroll-jank): the polyline decode ran every recomposition and the normalize + Path build ran
    // every frame. remember() the decode (keyed on the polyline) and hoist the normalize + Path into
    // drawWithCache (keyed on the points + the implicit size) so they tessellate ONCE and replay on scroll.
    // Pixel-identical: same normalizeToBox geometry, same stroke + endpoint markers.
    val points = remember(polyline) { RouteMath.decode(polyline) }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(180.dp)
            .drawWithCache {
                val screen = RouteMath.normalizeToBox(points, size.width, size.height)
                if (screen.size < 2) {
                    onDrawBehind { }
                } else {
                    val path = Path().apply {
                        moveTo(screen.first().first, screen.first().second)
                        screen.drop(1).forEach { (x, y) -> lineTo(x, y) }
                    }
                    val stroke = Stroke(width = 6f)
                    val start = Offset(screen.first().first, screen.first().second)
                    val end = Offset(screen.last().first, screen.last().second)
                    onDrawBehind {
                        drawPath(path, color = Palette.accent, style = stroke)
                        drawCircle(Palette.accent, radius = 9f, center = start)
                        drawCircle(Palette.statusCritical, radius = 9f, center = end)
                    }
                }
            },
    )
}
