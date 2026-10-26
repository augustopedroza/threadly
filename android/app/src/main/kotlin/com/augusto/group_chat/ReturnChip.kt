package com.augusto.group_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * The "back to Threadly" chip: a small draggable pill drawn over Google
 * Messages after a handoff — or after the user opens a conversation by
 * tapping Google Messages' own notification ([showForNotificationTap]) — so
 * one tap returns to Threadly. (Back can't do it:
 * GM's conversation screen always runs in GM's own task, so Back goes through
 * the GM inbox first.) Needs the "Display over other apps" permission, which
 * the user grants once in Settings; [show] is a no-op without it or when the
 * user turned the chip off.
 *
 * Hidden when Threadly resumes, on tap, when dragged onto the ✕ that appears
 * at the bottom of the screen during a drag, when the screen turns off, or
 * after [AUTO_HIDE_MS] so it never lingers over unrelated apps.
 * Process-lifetime state only: the overlay window keeps the process alive
 * while shown.
 */
object ReturnChip {
    private const val PREFS = "threadly_return_chip"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_NUDGED = "nudged"
    private const val KEY_X = "x"
    private const val KEY_Y = "y"
    private const val AUTO_HIDE_MS = 20L * 60 * 1000
    /** The drag-to-dismiss ✕: its circle's diameter, and how close (centre to
     *  centre) the chip has to come before it snaps on. */
    private const val DISMISS_TARGET_DP = 56
    private const val DISMISS_SNAP_DP = 80
    private const val TARGET_IDLE = 0xD9212121.toInt()
    private const val TARGET_ARMED = 0xF2B3261E.toInt() // M3 error red

    private var chip: View? = null
    /** The ✕ window, up only while the chip is being dragged. */
    private var dismissTarget: FrameLayout? = null
    private var screenOff: BroadcastReceiver? = null

    /** The conversation a notification tap opened, and when: Threadly blinks
     *  it (and offers suggestions) on the way back, like after a handoff. */
    private var returnTarget: Pair<String, Long>? = null

    /** When the chip was last tapped: a notification tap only counts if the
     *  user then came back *through the chip*, not via the launcher later. */
    private var chipTappedAt = 0L

    /**
     * The user tapped Google Messages' notification for [conversationId], so
     * Messages is opening that thread: float the chip over it and remember
     * the conversation. No-op (beyond remembering) without the overlay
     * permission or with the chip turned off.
     */
    fun showForNotificationTap(ctx: Context, conversationId: String) {
        returnTarget = conversationId to System.currentTimeMillis()
        show(ctx)
    }

    /**
     * Read-once: `{id, at}` for the conversation a notification tap opened,
     * if the user came back through the chip since (and within the chip's
     * lifetime). Any resume clears it, so it can't resurface later.
     */
    fun consumeReturnTarget(): Map<String, Any>? {
        val t = returnTarget ?: return null
        returnTarget = null
        val now = System.currentTimeMillis()
        if (chipTappedAt < t.second || now - t.second > AUTO_HIDE_MS) return null
        return mapOf("id" to t.first, "at" to t.second)
    }
    private val handler = Handler(Looper.getMainLooper())
    private val autoHide = Runnable { hide() }

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun granted(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

    /** User preference; defaults on (it only takes effect once granted). */
    fun enabled(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_ENABLED, true)

    fun setEnabled(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_ENABLED, on).apply()
        if (!on) hide()
    }

    /** Whether the one-time "turn this on?" nudge has been shown. */
    fun nudged(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_NUDGED, false)

    fun markNudged(ctx: Context) {
        prefs(ctx).edit().putBoolean(KEY_NUDGED, true).apply()
    }

    /**
     * The system page where the user grants "Display over other apps". Since
     * Android 11 this is always the full app list (the per-app page is
     * system-only), so the UI tells the user to find Threadly there. Launched
     * from the activity without NEW_TASK so Back returns to Threadly.
     */
    fun openSettings(ctx: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${ctx.packageName}")
        )
        if (ctx !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }

    /** Draw the chip (or re-arm its auto-hide if already up). */
    fun show(ctx: Context): Boolean {
        val app = ctx.applicationContext
        if (!granted(app) || !enabled(app)) return false
        if (chip != null) {
            handler.removeCallbacks(autoHide)
            handler.postDelayed(autoHide, AUTO_HIDE_MS)
            return true
        }
        val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = build(app)
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.START
        // Default: hugging the right edge, above the middle (clear of GM's
        // title bar and compose bar). Last dragged spot wins, clamped to the
        // current panel (a foldable's displays differ).
        val m = app.resources.displayMetrics
        view.measure(
            View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED
        )
        val margin = dp(app, 12)
        val maxX = m.widthPixels - view.measuredWidth - margin
        val maxY = m.heightPixels - view.measuredHeight - margin
        val p = prefs(app)
        lp.x = p.getInt(KEY_X, maxX).coerceIn(margin, maxX)
        lp.y = p.getInt(KEY_Y, (m.heightPixels * 0.28f).roundToInt())
            .coerceIn(margin, maxY)
        attachDrag(view, wm, lp, app)
        view.setOnClickListener { open(app) }
        try {
            wm.addView(view, lp)
        } catch (_: Exception) {
            // BadTokenException / SecurityException: permission pulled under us.
            return false
        }
        chip = view
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) = hide()
        }
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            app.registerReceiver(receiver, filter)
        }
        screenOff = receiver
        handler.postDelayed(autoHide, AUTO_HIDE_MS)
        return true
    }

    fun hide() {
        hideDismissTarget()
        val view = chip ?: return
        chip = null
        handler.removeCallbacks(autoHide)
        val app = view.context.applicationContext
        screenOff?.let { app.unregisterReceiver(it) }
        screenOff = null
        try {
            (app.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .removeView(view)
        } catch (_: IllegalArgumentException) {
            // Already gone.
        }
    }

    /** Bring Threadly to the front, exactly as the launcher would. */
    private fun open(app: Context) {
        hide()
        chipTappedAt = System.currentTimeMillis()
        val intent = app.packageManager.getLaunchIntentForPackage(app.packageName)
            ?: return
        app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /**
     * Drag to move (position remembered); a touch that doesn't move is a tap.
     * While dragging, a ✕ appears at the bottom of the screen: the chip snaps
     * onto it when close, and letting go there dismisses the chip for now (the
     * ⋮ menu toggle is the permanent off).
     */
    private fun attachDrag(
        view: View, wm: WindowManager, lp: WindowManager.LayoutParams, app: Context
    ) {
        val slop = ViewConfiguration.get(app).scaledTouchSlop
        val snapRadius = dp(app, DISMISS_SNAP_DP)
        val loc = IntArray(2)
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        // Screen = layout + origin: the overlay frame starts below the status
        // bar, and the ✕ is hit-tested in screen coordinates.
        var originX = 0
        var originY = 0
        var moved = false
        var inZone = false
        view.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.rawX
                    downY = ev.rawY
                    startX = lp.x
                    startY = lp.y
                    v.getLocationOnScreen(loc)
                    originX = loc[0] - lp.x
                    originY = loc[1] - lp.y
                    moved = false
                    inZone = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX
                    val dy = ev.rawY - downY
                    if (!moved && hypot(dx, dy) > slop) {
                        moved = true
                        showDismissTarget(wm, app)
                    }
                    if (moved) {
                        lp.x = (startX + dx).roundToInt()
                        lp.y = (startY + dy).roundToInt()
                        val target = dismissTarget
                        val near = target != null && target.width > 0 && run {
                            target.getLocationOnScreen(loc)
                            val tcx = loc[0] + target.width / 2
                            val tcy = loc[1] + target.height / 2
                            val ccx = lp.x + originX + v.width / 2
                            val ccy = lp.y + originY + v.height / 2
                            val close = hypot(
                                (ccx - tcx).toFloat(), (ccy - tcy).toFloat()
                            ) < snapRadius
                            if (close) { // snap the chip onto the ✕
                                lp.x = tcx - v.width / 2 - originX
                                lp.y = tcy - v.height / 2 - originY
                            }
                            close
                        }
                        if (near != inZone) {
                            inZone = near
                            setDismissTargetArmed(near)
                            if (near) v.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                        }
                        wm.updateViewLayout(v, lp)
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    hideDismissTarget()
                    when {
                        !moved -> if (ev.actionMasked == MotionEvent.ACTION_UP) v.performClick()
                        inZone -> dismiss(v)
                        else -> prefs(app).edit().putInt(KEY_X, lp.x).putInt(KEY_Y, lp.y).apply()
                    }
                    true
                }
                else -> true
            }
        }
    }

    /** Dropped on the ✕: shrink the chip away and take it down (for now). */
    private fun dismiss(view: View) {
        handler.removeCallbacks(autoHide)
        view.animate().scaleX(0.2f).scaleY(0.2f).alpha(0f).setDuration(120)
            .withEndAction { hide() }.start()
    }

    /**
     * The ✕ at the bottom of the screen, shown once a drag starts. Its own
     * untouchable overlay window, a bit larger than the circle so the armed
     * (grown) state isn't clipped.
     */
    private fun showDismissTarget(wm: WindowManager, app: Context) {
        if (dismissTarget != null) return
        val size = dp(app, DISMISS_TARGET_DP)
        val circle = FrameLayout(app)
        circle.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(TARGET_IDLE)
            setStroke(dp(app, 1), 0x66FFFFFF)
        }
        circle.elevation = dp(app, 6).toFloat()
        val glyph = ImageView(app)
        glyph.setImageResource(R.drawable.ic_dismiss_target)
        val glyphSize = dp(app, 28)
        glyph.layoutParams = FrameLayout.LayoutParams(glyphSize, glyphSize, Gravity.CENTER)
        circle.addView(glyph)
        val outer = FrameLayout(app)
        outer.addView(circle, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
        val pad = dp(app, 12)
        val lp = WindowManager.LayoutParams(
            size + 2 * pad, size + 2 * pad,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        lp.y = dp(app, 40)
        try {
            wm.addView(outer, lp)
        } catch (_: Exception) {
            return // permission pulled under us; dragging still works
        }
        dismissTarget = outer
        circle.alpha = 0f
        circle.scaleX = 0.6f
        circle.scaleY = 0.6f
        circle.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(150).start()
    }

    /** Grow and redden the ✕ while the chip is over it. */
    private fun setDismissTargetArmed(armed: Boolean) {
        val circle = dismissTarget?.getChildAt(0) ?: return
        val scale = if (armed) 1.25f else 1f
        circle.animate().scaleX(scale).scaleY(scale).setDuration(100).start()
        (circle.background as? GradientDrawable)
            ?.setColor(if (armed) TARGET_ARMED else TARGET_IDLE)
    }

    private fun hideDismissTarget() {
        val target = dismissTarget ?: return
        dismissTarget = null
        try {
            (target.context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .removeView(target)
        } catch (_: IllegalArgumentException) {
            // Already gone.
        }
    }

    private fun build(ctx: Context): View {
        val row = LinearLayout(ctx)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        row.setPadding(dp(ctx, 10), dp(ctx, 8), dp(ctx, 14), dp(ctx, 8))
        row.background = GradientDrawable().apply {
            cornerRadius = dp(ctx, 24).toFloat()
            setColor(0xF2283593.toInt()) // indigo 800, matching the app's seed
            setStroke(dp(ctx, 1), 0x40FFFFFF)
        }
        row.elevation = dp(ctx, 6).toFloat()
        val icon = ImageView(ctx)
        icon.setImageResource(R.mipmap.ic_launcher)
        icon.layoutParams = LinearLayout.LayoutParams(dp(ctx, 24), dp(ctx, 24))
        val label = TextView(ctx)
        label.text = "Threadly"
        label.setTextColor(Color.WHITE)
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        label.typeface = Typeface.DEFAULT_BOLD
        label.setPadding(dp(ctx, 8), 0, 0, 0)
        row.addView(icon)
        row.addView(label)
        return row
    }

    private fun dp(ctx: Context, v: Int): Int =
        (v * ctx.resources.displayMetrics.density).roundToInt()
}
