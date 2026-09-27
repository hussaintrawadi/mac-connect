package com.androidbridge.ui.onboarding

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.view.Gravity
import android.view.accessibility.AccessibilityManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.androidbridge.R
import com.androidbridge.ui.MainActivity

class OnboardingActivity : AppCompatActivity() {

    private val steps = mutableListOf<PermissionStep>()
    private var currentStep = 0
    private lateinit var titleText: TextView
    private lateinit var descText: TextView
    private lateinit var actionButton: Button
    private lateinit var skipButton: Button
    private lateinit var stepIndicator: TextView

    data class PermissionStep(
        val title: String,
        val description: String,
        val check: () -> Boolean,
        val request: () -> Unit
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showPrivacyIntro()
    }

    /** Transparent, reassuring intro: explains WHY permissions are needed and that
     *  everything is local — no cloud, no accounts, no data leaves the network. */
    private fun showPrivacyIntro() {
        val colBackground = ContextCompat.getColor(this, R.color.background)
        val colOnSurface = ContextCompat.getColor(this, R.color.on_surface)
        val colSecondary = ContextCompat.getColor(this, R.color.text_secondary)
        val colOnPrimary = ContextCompat.getColor(this, R.color.on_primary)
        val colGreen = 0xFF30D158.toInt()

        val scroll = ScrollView(this).apply {
            setBackgroundColor(colBackground)
            isFillViewport = true
        }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(56), dp(28), dp(32))
        }

        val logoFrame = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            setBackgroundResource(R.drawable.bg_logo_glow)
            val s = dp(84)
            layoutParams = LinearLayout.LayoutParams(s, s).apply {
                gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(20)
            }
        }
        logoFrame.addView(ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52))
        })
        layout.addView(logoFrame)

        layout.addView(TextView(this).apply {
            text = "Private by design"
            textSize = 25f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colOnSurface)
            gravity = Gravity.CENTER
            layoutParams = lp().apply { bottomMargin = dp(10) }
        })

        layout.addView(TextView(this).apply {
            text = "Mac Connect links your phone and Mac directly over your own Wi-Fi."
            textSize = 15f
            setTextColor(colSecondary)
            gravity = Gravity.CENTER
            setLineSpacing(dp(4).toFloat(), 1f)
            layoutParams = lp().apply { bottomMargin = dp(22) }
        })

        // No-cloud highlight card
        val cloudCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card)
            setPadding(dp(20), dp(18), dp(20), dp(18))
            layoutParams = lp().apply { bottomMargin = dp(20) }
        }
        val cloudHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = lp().apply { bottomMargin = dp(6) }
        }
        cloudHeader.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_shield_check)
            setColorFilter(colGreen)
            layoutParams = LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(10) }
        })
        cloudHeader.addView(TextView(this).apply {
            text = "No cloud. No accounts. No tracking."
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colGreen)
        })
        cloudCard.addView(cloudHeader)
        cloudCard.addView(TextView(this).apply {
            text = "Nothing is ever uploaded or stored on a server. Your messages, calls, files and screen never leave your local network — they go straight to your Mac and nowhere else."
            textSize = 13f
            setTextColor(colSecondary)
            setLineSpacing(dp(4).toFloat(), 1f)
        })
        layout.addView(cloudCard)

        layout.addView(TextView(this).apply {
            text = "Why the permissions?"
            textSize = 13f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colSecondary)
            letterSpacing = 0.08f
            gravity = Gravity.START
            layoutParams = lp().apply { bottomMargin = dp(10) }
        })

        val reasons = listOf(
            Triple(R.drawable.ic_perm_messages, "Messages & Contacts", "So you can read and reply to texts (with names) from your Mac."),
            Triple(R.drawable.ic_perm_phone, "Phone & Call Log", "So incoming calls pop up on your Mac and you can dial from it."),
            Triple(R.drawable.ic_perm_notifications, "Notifications & Accessibility", "To mirror notifications and let you control the phone from your Mac."),
            Triple(R.drawable.ic_perm_files, "Files & Storage", "To browse and transfer files and photos between the two devices.")
        )
        for ((icon, t, d) in reasons) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setBackgroundResource(R.drawable.bg_card)
                setPadding(dp(16), dp(12), dp(16), dp(12))
                layoutParams = lp().apply { bottomMargin = dp(8) }
            }
            row.addView(ImageView(this).apply {
                setImageResource(icon)
                setColorFilter(colOnSurface)
                layoutParams = LinearLayout.LayoutParams(dp(22), dp(22)).apply { rightMargin = dp(14) }
            })
            val texts = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            texts.addView(TextView(this).apply {
                text = t; textSize = 14f; setTypeface(null, Typeface.BOLD); setTextColor(colOnSurface)
            })
            texts.addView(TextView(this).apply {
                text = d; textSize = 12f; setTextColor(colSecondary); setLineSpacing(dp(3).toFloat(), 1f)
            })
            row.addView(texts)
            layout.addView(row)
        }

        layout.addView(TextView(this).apply {
            text = "You're always in control — you can skip any permission you're not comfortable with."
            textSize = 12f
            setTextColor(colSecondary)
            gravity = Gravity.CENTER
            setLineSpacing(dp(3).toFloat(), 1f)
            layoutParams = lp().apply { topMargin = dp(14); bottomMargin = dp(20) }
        })

        layout.addView(Button(this).apply {
            text = "Continue"
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colOnPrimary)
            setBackgroundResource(R.drawable.bg_button_primary)
            isAllCaps = false
            stateListAnimator = null
            setPadding(0, dp(16), 0, dp(16))
            layoutParams = lp()
            setOnClickListener { showPermissionFlow() }
        })

        scroll.addView(layout)
        setContentView(scroll)
    }

    private fun lp() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT
    )

    private fun showPermissionFlow() {
        val colBackground = ContextCompat.getColor(this, R.color.background)
        val colOnSurface = ContextCompat.getColor(this, R.color.on_surface)
        val colSecondary = ContextCompat.getColor(this, R.color.text_secondary)
        val colTertiary = ContextCompat.getColor(this, R.color.text_tertiary)
        val colOnPrimary = ContextCompat.getColor(this, R.color.on_primary)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(64), dp(28), dp(32))
            setBackgroundColor(colBackground)
        }

        // Branded logo inside a rounded backdrop
        val logoFrame = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            setBackgroundResource(R.drawable.bg_logo_glow)
            val size = dp(84)
            layoutParams = LinearLayout.LayoutParams(size, size).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(18)
            }
        }
        val logo = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52))
        }
        logoFrame.addView(logo)
        layout.addView(logoFrame)

        val appName = TextView(this).apply {
            text = "Mac Connect"
            textSize = 24f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colOnSurface)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(8) }
        }
        layout.addView(appName)

        val subtitle = TextView(this).apply {
            text = "Let's set up a few permissions"
            textSize = 14f
            setTextColor(colSecondary)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(36) }
        }
        layout.addView(subtitle)

        // Card containing the current step
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundResource(R.drawable.bg_card)
            setPadding(dp(24), dp(28), dp(24), dp(28))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(24) }
        }

        titleText = TextView(this).apply {
            textSize = 19f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colOnSurface)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(10) }
        }
        card.addView(titleText)

        descText = TextView(this).apply {
            textSize = 14f
            setTextColor(colSecondary)
            gravity = Gravity.CENTER
            setLineSpacing(6f, 1f)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        card.addView(descText)
        layout.addView(card)

        actionButton = Button(this).apply {
            text = "Grant Permission"
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(colOnPrimary)
            setBackgroundResource(R.drawable.bg_button_primary)
            isAllCaps = false
            stateListAnimator = null
            setPadding(0, dp(16), 0, dp(16))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(8) }
        }
        layout.addView(actionButton)

        skipButton = Button(this).apply {
            text = "Skip"
            textSize = 14f
            setTextColor(colSecondary)
            setBackgroundColor(0x00000000)
            isAllCaps = false
            stateListAnimator = null
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(20) }
        }
        layout.addView(skipButton)

        stepIndicator = TextView(this).apply {
            textSize = 12f
            setTextColor(colTertiary)
            letterSpacing = 0.05f
            gravity = Gravity.CENTER
        }
        layout.addView(stepIndicator)

        setContentView(layout)

        buildSteps()
        showCurrentStep()

        actionButton.setOnClickListener { steps[currentStep].request() }
        skipButton.setOnClickListener { nextStep() }
    }

    override fun onResume() {
        super.onResume()
        if (currentStep < steps.size && steps[currentStep].check()) {
            nextStep()
        }
    }

    private fun buildSteps() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            steps.add(PermissionStep(
                "Notifications",
                "Allow Mac Connect to post notifications so you can see connection status.",
                { ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED },
                { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100) }
            ))
        }

        // Camera permission for QR scanning
        steps.add(PermissionStep(
            "Camera",
            "Required to scan the QR code displayed on your Mac for pairing.",
            { ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED },
            { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 104) }
        ))

        steps.add(PermissionStep(
            "SMS Access",
            "Read and send SMS messages from your Mac.",
            { ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED },
            { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS), 101) }
        ))

        steps.add(PermissionStep(
            "Contacts",
            "Show contact names for calls and messages.",
            { ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED },
            { ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CONTACTS), 102) }
        ))

        steps.add(PermissionStep(
            "Phone & Calls",
            "Make and receive calls from your Mac.",
            { ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED },
            {
                val perms = mutableListOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.RECORD_AUDIO, Manifest.permission.CALL_PHONE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) perms.add(Manifest.permission.ANSWER_PHONE_CALLS)
                ActivityCompat.requestPermissions(this, perms.toTypedArray(), 103)
            }
        ))

        // Photos & media — REQUIRED for the gallery to load (Android 13+ split perms).
        steps.add(PermissionStep(
            "Photos & Media",
            "View your phone's photos and videos in the Mac gallery.",
            { mediaPermissions().all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED } },
            { ActivityCompat.requestPermissions(this, mediaPermissions(), 105) }
        ))

        // Storage access for Android 11+ (full file manager browsing)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            steps.add(PermissionStep(
                "Storage Access",
                "Browse and transfer all files (not just media) between your phone and Mac.",
                { Environment.isExternalStorageManager() },
                {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                }
            ))
        }

        steps.add(PermissionStep(
            "Notification Access",
            "Mirror your phone's notifications to Mac. This opens system settings — enable Mac Connect in the list.",
            { isNotificationListenerEnabled() },
            { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
        ))

        steps.add(PermissionStep(
            "Accessibility Service",
            "Required for screen mirroring touch control. Enable Mac Connect in Accessibility settings.",
            { isAccessibilityEnabled() },
            { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        ))

        steps.add(PermissionStep(
            "Keep Screen Awake",
            "Keeps mirroring working when your phone would otherwise sleep or lock. Enable “Display over other apps” for Mac Connect.",
            { Settings.canDrawOverlays(this) },
            { startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))) }
        ))
    }

    private fun showCurrentStep() {
        if (currentStep >= steps.size) {
            finishOnboarding()
            return
        }

        val step = steps[currentStep]
        titleText.text = step.title
        descText.text = step.description
        stepIndicator.text = "Step ${currentStep + 1} of ${steps.size}"

        if (step.check()) {
            actionButton.text = "Already Granted"
            actionButton.isEnabled = false
            actionButton.setBackgroundResource(R.drawable.bg_button_disabled)
            actionButton.setTextColor(ContextCompat.getColor(this, R.color.text_secondary))
        } else {
            actionButton.text = "Grant Permission"
            actionButton.isEnabled = true
            actionButton.setBackgroundResource(R.drawable.bg_button_primary)
            actionButton.setTextColor(ContextCompat.getColor(this, R.color.on_primary))
        }
    }

    private fun mediaPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_AUDIO
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun nextStep() {
        currentStep++
        showCurrentStep()
    }

    private fun finishOnboarding() {
        getSharedPreferences("androidbridge", MODE_PRIVATE)
            .edit().putBoolean("onboarding_complete", true).apply()

        startActivity(Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        })
        finish()
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val listeners = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        return listeners.contains(ComponentName(this, "com.androidbridge.features.notifications.BridgeNotificationListener").flattenToString())
    }

    private fun isAccessibilityEnabled(): Boolean {
        val am = getSystemService(ACCESSIBILITY_SERVICE) as AccessibilityManager
        val services = am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        return services.any { it.resolveInfo.serviceInfo.packageName == packageName }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            nextStep()
        }
    }
}
