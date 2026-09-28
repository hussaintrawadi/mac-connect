package com.androidbridge.features.findphone

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The big "Mac Connect is finding your phone — Stop" screen. Shows over the lock
 * screen and turns the display on, so you can silence the alarm with one tap.
 */
class FindPhoneActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // If launched purely to stop (e.g. a stale intent), just silence and leave.
        if (intent?.action == ACTION_STOP) {
            FindPhoneAlarm.stop()
            finish()
            return
        }

        showOverLockScreen()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0A84FF"))
            setPadding(64, 64, 64, 64)
        }

        val emoji = TextView(this).apply {
            text = "🔊"   // 🔊
            textSize = 72f
            gravity = Gravity.CENTER
        }
        val title = TextView(this).apply {
            text = "Finding your phone"
            setTextColor(Color.WHITE)
            textSize = 26f
            gravity = Gravity.CENTER
            setPadding(0, 32, 0, 8)
        }
        val subtitle = TextView(this).apply {
            text = "Triggered from your Mac"
            setTextColor(Color.parseColor("#DDFFFFFF"))
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 48)
        }
        val stop = Button(this).apply {
            text = "Stop"
            textSize = 20f
            setOnClickListener {
                FindPhoneAlarm.stop()
                finish()
            }
        }

        root.addView(emoji)
        root.addView(title)
        root.addView(subtitle)
        root.addView(stop, LinearLayout.LayoutParams(
            (resources.displayMetrics.widthPixels * 0.6f).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

        setContentView(root)
    }

    override fun onDestroy() {
        // Closing the screen (back / swipe away) should also silence it.
        FindPhoneAlarm.stop()
        super.onDestroy()
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
    }

    companion object {
        const val ACTION_STOP = "com.androidbridge.STOP_FIND_ALARM"
    }
}
