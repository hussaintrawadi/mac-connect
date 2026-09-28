package com.androidbridge.features.screenmirror

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.PointF
import android.os.Bundle
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.androidbridge.proto.Messages.*
import kotlin.math.hypot

class TouchInjectionService : AccessibilityService() {

    private var screenWidth = 0
    private var screenHeight = 0

    // Accumulates a gesture path between DOWN and UP so click-drag becomes a swipe
    // and a quick click becomes a tap.
    private val gesturePath = mutableListOf<PointF>()
    private var gestureStartTime = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used — we only need gesture dispatch and text injection
    }

    override fun onInterrupt() {
        Log.w(TAG, "Accessibility service interrupted")
    }

    private val clipboardHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val clipboardPoll = object : Runnable {
        override fun run() {
            // Accessibility services CAN read the clipboard in the background,
            // unlike the rest of the app — this is what makes phone→Mac copy work.
            try {
                com.androidbridge.features.clipboard.ClipboardBridge.instance?.pollClipboard()
            } catch (_: Exception) {}
            // 3s is plenty for clipboard sync and roughly halves the background
            // wakeups vs 1.5s — noticeably lighter on battery.
            clipboardHandler.postDelayed(this, 3000)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        updateScreenDimensions()
        instance = this
        clipboardHandler.post(clipboardPoll)
        Log.i(TAG, "TouchInjectionService connected (${screenWidth}x${screenHeight})")
    }

    override fun onDestroy() {
        instance = null
        clipboardHandler.removeCallbacks(clipboardPoll)
        super.onDestroy()
    }

    private fun updateScreenDimensions() {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        screenWidth = metrics.widthPixels
        screenHeight = metrics.heightPixels
    }

    // MARK: - Touch Events

    fun handleTouchEvent(event: TouchEvent) {
        // Coordinates are normalized 0.0–1.0 from Mac, scale to screen pixels
        val x = (event.x * screenWidth).coerceIn(0f, screenWidth - 1f)
        val y = (event.y * screenHeight).coerceIn(0f, screenHeight - 1f)

        when (event.action) {
            TouchEvent.TouchAction.DOWN -> {
                gesturePath.clear()
                gesturePath.add(PointF(x, y))
                gestureStartTime = SystemClock.uptimeMillis()
            }
            TouchEvent.TouchAction.MOVE -> {
                gesturePath.add(PointF(x, y))
            }
            TouchEvent.TouchAction.UP -> {
                gesturePath.add(PointF(x, y))
                dispatchAccumulatedGesture()
            }
            TouchEvent.TouchAction.LONG_PRESS -> injectLongPress(x, y)
            else -> {}
        }
    }

    private fun dispatchAccumulatedGesture() {
        if (gesturePath.isEmpty()) return

        val start = gesturePath.first()
        val end = gesturePath.last()
        val distance = hypot((end.x - start.x).toDouble(), (end.y - start.y).toDouble())
        val elapsed = (SystemClock.uptimeMillis() - gestureStartTime).coerceIn(1L, 3000L)

        // Barely moved → treat as a tap.
        if (distance < 15 && gesturePath.size <= 2) {
            injectTap(start.x, start.y)
            gesturePath.clear()
            return
        }

        // Build a path through all accumulated points → a swipe/drag.
        val path = Path().apply {
            moveTo(start.x, start.y)
            for (i in 1 until gesturePath.size) {
                lineTo(gesturePath[i].x, gesturePath[i].y)
            }
        }
        val duration = elapsed.coerceIn(40L, 1500L)
        try {
            val stroke = GestureDescription.StrokeDescription(path, 0, duration)
            dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        } catch (e: Exception) {
            Log.e(TAG, "Swipe dispatch failed", e)
        }
        gesturePath.clear()
    }

    fun handleScrollEvent(event: ScrollEvent) {
        val centerX = event.x * screenWidth
        val centerY = event.y * screenHeight
        val scrollDistance = event.dy * 300 // Scale scroll amount

        injectSwipe(
            centerX, centerY,
            centerX, centerY - scrollDistance,
            300
        )
    }

    fun handleKeyEvent(event: KeyEvent) {
        if (event.text.isNotEmpty()) {
            injectText(event.text)
        } else {
            handleSpecialKey(event.keyCode)
        }
    }

    // MARK: - Gesture Injection

    fun injectTap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 50)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                Log.d(TAG, "Tap at ($x, $y)")
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                Log.w(TAG, "Tap cancelled at ($x, $y)")
            }
        }, null)
    }

    fun injectSwipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long) {
        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, null, null)
    }

    fun injectLongPress(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 1000)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, null, null)
    }

    fun injectPinch(centerX: Float, centerY: Float, startSpan: Float, endSpan: Float, durationMs: Long) {
        val path1 = Path().apply {
            moveTo(centerX - startSpan / 2, centerY)
            lineTo(centerX - endSpan / 2, centerY)
        }
        val path2 = Path().apply {
            moveTo(centerX + startSpan / 2, centerY)
            lineTo(centerX + endSpan / 2, centerY)
        }

        val stroke1 = GestureDescription.StrokeDescription(path1, 0, durationMs)
        val stroke2 = GestureDescription.StrokeDescription(path2, 0, durationMs)
        val gesture = GestureDescription.Builder()
            .addStroke(stroke1)
            .addStroke(stroke2)
            .build()
        dispatchGesture(gesture, null, null)
    }

    // MARK: - Text Injection

    // Current selection bounds of a node, clamped to valid range. Falls back to
    // end-of-text when the field reports no selection.
    private fun selectionOf(node: AccessibilityNodeInfo, textLen: Int): Pair<Int, Int> {
        var start = node.textSelectionStart
        var end = node.textSelectionEnd
        if (start < 0 || start > textLen) start = textLen
        if (end < 0 || end > textLen) end = textLen
        return Pair(minOf(start, end), maxOf(start, end))
    }

    private fun setCursor(node: AccessibilityNodeInfo, pos: Int) {
        val args = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, pos)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, pos)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }

    private fun setText(node: AccessibilityNodeInfo, text: String) {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun injectText(text: String) {
        val node = findFocusedInputNode() ?: run {
            // Lock screen / app-lock PIN pads have no focused text field —
            // click the matching keypad buttons instead (works on keyguard).
            if (clickKeypadButtons(text)) return
            Log.w(TAG, "No focused input — cannot inject text")
            return
        }
        val existing = textOf(node)
        val (start, end) = selectionOf(node, existing.length)

        // Insert at the cursor, replacing any selected range.
        val newText = existing.substring(0, start) + text + existing.substring(end)
        setText(node, newText)
        setCursor(node, start + text.length)
        node.recycle()
    }

    /** The field's real text — empty while it is only showing its hint/placeholder
     *  (otherwise typing would append to the placeholder text). */
    private fun textOf(node: AccessibilityNodeInfo): String =
        if (node.isShowingHintText) "" else node.text?.toString() ?: ""

    private fun findFocusedInputNode(): AccessibilityNodeInfo? {
        return rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
    }

    /** Best-effort PIN entry on the lock screen / app-lock: click the keypad
     *  button whose label matches each typed character. */
    private fun clickKeypadButtons(text: String): Boolean {
        var clickedAny = false
        for (ch in text) {
            val target = findClickableByLabel(ch.toString())
            if (target != null) {
                target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                target.recycle()
                clickedAny = true
                try { Thread.sleep(60) } catch (_: InterruptedException) {}
            }
        }
        return clickedAny
    }

    private fun findClickableByLabel(label: String): AccessibilityNodeInfo? {
        val roots = mutableListOf<AccessibilityNodeInfo>()
        rootInActiveWindow?.let { roots.add(it) }
        try { windows?.forEach { w -> w.root?.let { roots.add(it) } } } catch (_: Exception) {}

        for (root in roots) {
            val matches = root.findAccessibilityNodeInfosByText(label) ?: continue
            for (m in matches) {
                val exact = m.text?.toString() == label || m.contentDescription?.toString() == label
                if (!exact) continue
                var n: AccessibilityNodeInfo? = m
                while (n != null && !n.isClickable) n = n.parent
                if (n != null) return n
            }
        }
        return null
    }

    // MARK: - Special Keys

    /** Wake the screen from the Mac so the user can reach the lock screen,
     *  swipe up, and type their PIN — all without touching the phone. */
    private fun wakeScreen() {
        try {
            val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(
                android.os.PowerManager.FULL_WAKE_LOCK or
                    android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    android.os.PowerManager.ON_AFTER_RELEASE,
                "MacConnect:wake"
            )
            wl.acquire(3000)
            Log.i(TAG, "Screen wake requested from Mac")
        } catch (e: Exception) {
            Log.e(TAG, "Wake failed", e)
        }
    }

    private fun handleSpecialKey(keyCode: Int) {
        when (keyCode) {
            KEY_BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            KEY_HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            KEY_RECENTS -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            KEY_NOTIFICATIONS -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            KEY_POWER -> performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
            KEY_WAKE -> wakeScreen()

            KEY_BACKSPACE -> {
                val node = findFocusedInputNode() ?: return
                val existing = textOf(node)
                val (start, end) = selectionOf(node, existing.length)
                if (start != end) {
                    // Delete the selection.
                    setText(node, existing.substring(0, start) + existing.substring(end))
                    setCursor(node, start)
                } else if (start > 0) {
                    // Delete the character before the cursor.
                    setText(node, existing.substring(0, start - 1) + existing.substring(start))
                    setCursor(node, start - 1)
                }
                node.recycle()
            }

            KEY_DELETE_FORWARD -> {
                val node = findFocusedInputNode() ?: return
                val existing = textOf(node)
                val (start, end) = selectionOf(node, existing.length)
                if (start != end) {
                    setText(node, existing.substring(0, start) + existing.substring(end))
                    setCursor(node, start)
                } else if (start < existing.length) {
                    setText(node, existing.substring(0, start) + existing.substring(start + 1))
                    setCursor(node, start)
                }
                node.recycle()
            }

            KEY_ARROW_LEFT -> moveCursorHorizontal(-1)
            KEY_ARROW_RIGHT -> moveCursorHorizontal(1)
            KEY_ARROW_UP -> moveCursorByLine(forward = false)
            KEY_ARROW_DOWN -> moveCursorByLine(forward = true)

            KEY_ENTER -> {
                val node = findFocusedInputNode() ?: return
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                } else {
                    injectText("\n")
                }
                node.recycle()
            }
            else -> Log.d(TAG, "Unhandled key code: $keyCode")
        }
    }

    private fun moveCursorHorizontal(delta: Int) {
        val node = findFocusedInputNode() ?: return
        val len = node.text?.toString()?.length ?: 0
        val (start, end) = selectionOf(node, len)
        // Collapse a selection toward the arrow direction; otherwise step one char.
        val pos = when {
            start != end && delta < 0 -> start
            start != end && delta > 0 -> end
            else -> (start + delta).coerceIn(0, len)
        }
        setCursor(node, pos)
        node.recycle()
    }

    private fun moveCursorByLine(forward: Boolean) {
        val node = findFocusedInputNode() ?: return
        val granularity = Bundle().apply {
            putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT,
                AccessibilityNodeInfo.MOVEMENT_GRANULARITY_LINE
            )
            putBoolean(AccessibilityNodeInfo.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN, false)
        }
        val action = if (forward)
            AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY
        else
            AccessibilityNodeInfo.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY
        node.performAction(action, granularity)
        node.recycle()
    }

    companion object {
        private const val TAG = "TouchInjection"
        var instance: TouchInjectionService? = null
            private set

        // Custom key codes for special keys sent from Mac
        const val KEY_BACK = 1
        const val KEY_HOME = 2
        const val KEY_RECENTS = 3
        const val KEY_NOTIFICATIONS = 4
        const val KEY_POWER = 5
        const val KEY_BACKSPACE = 6
        const val KEY_ENTER = 7
        const val KEY_ARROW_LEFT = 8
        const val KEY_ARROW_RIGHT = 9
        const val KEY_ARROW_UP = 10
        const val KEY_ARROW_DOWN = 11
        const val KEY_DELETE_FORWARD = 12
        const val KEY_WAKE = 13
    }
}
