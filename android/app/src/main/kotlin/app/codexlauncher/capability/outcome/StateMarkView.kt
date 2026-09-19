package app.codexlauncher.capability.outcome

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.codexlauncher.appearance.theme.QuietInstrumentTokens
import app.codexlauncher.appearance.theme.QuietPalette

/*
 * Checked the current Compose drawing/accessibility API against the official
 * docs (developer.android.com/develop/ui/compose, via the context7 MCP
 * server) before writing this: Canvas + DrawScope.drawCircle/drawPath/
 * drawArc/drawLine/drawRect, and Modifier.semantics { contentDescription = }
 * for attaching an accessibility label to a composable that carries no text
 * of its own.
 */

/** Resolves a [MarkTone] against the palette that is on screen right now. */
private fun MarkTone.resolve(palette: QuietPalette): Long =
    when (this) {
        MarkTone.SIGNAL -> palette.signal
        MarkTone.WARNING -> palette.warning
        MarkTone.MUTED -> palette.mutedText
        MarkTone.ERROR -> palette.error
    }

/**
 * Draws one [StateMark] beside its label.
 *
 * DESIGN.md: "Both carry their words." A shape by itself is not a state, so
 * this composable is the only place a [MarkShape] gets drawn, and it always
 * lays the shape out next to [StateMark.label] — there is no way to call
 * this and get the glyph without the words.
 *
 * [tappableRow] should be true when this mark sits inside a row the user can
 * tap (e.g. a task row that opens the task), so the whole thing — glyph plus
 * label — meets [QuietInstrumentTokens.minimumTouchTargetDp]. Leave it false
 * when the mark is purely informational and sits inside a larger control
 * that already owns the touch target, so this composable does not silently
 * inflate that control's hit area.
 *
 * [label] overrides the words bonded to the glyph. It defaults to
 * [StateMark.label], and every caller that shows a mark's own name leaves it
 * unset. DESIGN.md gives one mark different words on different surfaces — the
 * Unverified mark reads "Unverified" beside a capability but "Couldn't confirm
 * that happened" beside a task — so the task surface passes its own phrase
 * here. The shape still never renders without words: [label] can only swap
 * which words, never remove them.
 */
@Composable
fun StateMark(
    mark: StateMark,
    modifier: Modifier = Modifier,
    tappableRow: Boolean = false,
    glyphSize: Dp = 20.dp,
    label: String = mark.label,
) {
    // There is no CompositionLocal for QuietPalette in this codebase yet
    // (QuietInstrumentTheme resolves it internally and only exposes the
    // derived MaterialTheme.colorScheme). Following system dark/light here
    // mirrors what QuietInstrumentTheme itself does for AppearanceMode
    // .FOLLOW_SYSTEM, which is the common case.
    val palette = if (isSystemInDarkTheme()) QuietInstrumentTokens.deepCharcoal else QuietInstrumentTokens.warmPaper
    // The Working mark breathes so a long pre-first-token wait reads as alive
    // rather than frozen; every other mark is a settled state and stays static.
    val glyphAlpha =
        if (mark == StateMark.WORKING) {
            val pulse = rememberInfiniteTransition(label = "working-mark")
            pulse.animateFloat(
                initialValue = 0.4f,
                targetValue = 1f,
                animationSpec =
                    infiniteRepeatable(
                        animation = tween(durationMillis = 900),
                        repeatMode = RepeatMode.Reverse,
                    ),
                label = "working-mark-alpha",
            ).value
        } else {
            1f
        }
    val toneColor = Color(mark.tone.resolve(palette)).copy(alpha = glyphAlpha)

    val touchTarget =
        if (tappableRow) {
            Modifier.sizeIn(
                minWidth = QuietInstrumentTokens.minimumTouchTargetDp.dp,
                minHeight = QuietInstrumentTokens.minimumTouchTargetDp.dp,
            )
        } else {
            Modifier
        }

    Row(
        modifier = modifier.then(touchTarget),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(QuietInstrumentTokens.spacingDp[1].dp),
    ) {
        Canvas(
            modifier =
                Modifier
                    .size(glyphSize)
                    // A screen reader reads the state off the glyph itself,
                    // the same words a sighted user reads off the label next
                    // to it.
                    .semantics { contentDescription = label },
        ) {
            drawStateMark(shape = mark.shape, fill = mark.fill, color = toneColor)
        }
        Text(text = label, color = LocalContentColor.current, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Draws [shape] filled or outlined per [fill], in [color], inside this DrawScope's bounds. */
private fun DrawScope.drawStateMark(shape: MarkShape, fill: MarkFill, color: Color) {
    val strokeWidth = size.minDimension * 0.1f
    val style = if (fill == MarkFill.SOLID) Fill else Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round)
    val inset = strokeWidth / 2f
    val topLeft = Offset(inset, inset)
    val boxSize = Size(size.width - inset * 2f, size.height - inset * 2f)
    val center = Offset(size.width / 2f, size.height / 2f)
    val radius = boxSize.minDimension / 2f

    when (shape) {
        MarkShape.CIRCLE ->
            drawCircle(color = color, radius = radius, center = center, style = style)

        MarkShape.DIAMOND -> {
            val path =
                Path().apply {
                    moveTo(center.x, topLeft.y)
                    lineTo(topLeft.x + boxSize.width, center.y)
                    lineTo(center.x, topLeft.y + boxSize.height)
                    lineTo(topLeft.x, center.y)
                    close()
                }
            drawPath(path, color = color, style = style)
        }

        MarkShape.HALF_CIRCLE ->
            drawArc(color = color, startAngle = 90f, sweepAngle = 180f, useCenter = true, topLeft = topLeft, size = boxSize, style = style)

        MarkShape.CIRCLE_WITH_CHECK -> {
            // Always outlined per DESIGN.md, regardless of the mark's own
            // fill — the check mark is drawn inside a ring, not a disc.
            drawCircle(color = color, radius = radius, center = center, style = Stroke(width = strokeWidth, cap = StrokeCap.Round))
            val check =
                Path().apply {
                    moveTo(center.x - radius * 0.45f, center.y)
                    lineTo(center.x - radius * 0.05f, center.y + radius * 0.4f)
                    lineTo(center.x + radius * 0.5f, center.y - radius * 0.35f)
                }
            drawPath(check, color = color, style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }

        MarkShape.SQUARE_WITH_X -> {
            drawRect(color = color, topLeft = topLeft, size = boxSize, style = Stroke(width = strokeWidth))
            val inX = boxSize.width * 0.22f
            val inY = boxSize.height * 0.22f
            drawLine(
                color = color,
                start = Offset(topLeft.x + inX, topLeft.y + inY),
                end = Offset(topLeft.x + boxSize.width - inX, topLeft.y + boxSize.height - inY),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = color,
                start = Offset(topLeft.x + boxSize.width - inX, topLeft.y + inY),
                end = Offset(topLeft.x + inX, topLeft.y + boxSize.height - inY),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
        }

        MarkShape.CIRCLE_WITH_EXIT_ARROW -> {
            drawCircle(color = color, radius = radius, center = center, style = Stroke(width = strokeWidth))
            // An arrow through the ring, tip pointing up and out past the
            // edge: the thing left, it did not just move around inside.
            val tail = Offset(center.x - radius * 0.4f, center.y + radius * 0.4f)
            val tip = Offset(center.x + radius * 0.65f, center.y - radius * 0.65f)
            drawLine(color = color, start = tail, end = tip, strokeWidth = strokeWidth, cap = StrokeCap.Round)
            val head =
                Path().apply {
                    moveTo(tip.x, tip.y)
                    lineTo(tip.x - radius * 0.4f, tip.y)
                    moveTo(tip.x, tip.y)
                    lineTo(tip.x, tip.y + radius * 0.4f)
                }
            drawPath(head, color = color, style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }

        MarkShape.CIRCLE_WITH_QUESTION_MARK -> {
            drawCircle(color = color, radius = radius, center = center, style = Stroke(width = strokeWidth))
            val hook =
                Path().apply {
                    addArc(
                        Rect(
                            left = center.x - radius * 0.35f,
                            top = center.y - radius * 0.55f,
                            right = center.x + radius * 0.35f,
                            bottom = center.y - radius * 0.05f,
                        ),
                        startAngleDegrees = -160f,
                        sweepAngleDegrees = 220f,
                    )
                    lineTo(center.x, center.y + radius * 0.15f)
                }
            drawPath(hook, color = color, style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round))
            drawCircle(color = color, radius = strokeWidth * 0.6f, center = Offset(center.x, center.y + radius * 0.55f))
        }
    }
}
