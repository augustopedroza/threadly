package com.augusto.group_chat

import android.content.ComponentName
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "threadly/notifications"
    private val chipChannel = "threadly/return_chip"

    override fun onResume() {
        super.onResume()
        // We're back: the "return to Threadly" chip has done its job.
        ReturnChip.hide()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, chipChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(
                        mapOf(
                            "granted" to ReturnChip.granted(this),
                            "enabled" to ReturnChip.enabled(this),
                            "nudged" to ReturnChip.nudged(this),
                        )
                    )
                    "setEnabled" -> {
                        ReturnChip.setEnabled(this, call.argument<Boolean>("on") == true)
                        result.success(null)
                    }
                    "markNudged" -> {
                        ReturnChip.markNudged(this)
                        result.success(null)
                    }
                    "openSettings" -> {
                        ReturnChip.openSettings(this)
                        result.success(null)
                    }
                    "show" -> result.success(ReturnChip.show(this))                    "hide" -> {
                        ReturnChip.hide()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "permissionGranted" -> result.success(isListenerEnabled())
                    "openSettings" -> {
                        startActivity(
                            android.content.Intent(
                                Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
                            )
                        )
                        result.success(null)
                    }
                    "conversations" ->
                        result.success(
                            ConversationNotificationListener.conversationsJson(this)
                        )
                    "launch" -> {
                        val id = call.argument<String>("id")
                        if (id == null) {
                            result.error("no_id", "Missing conversation id", null)
                        } else {
                            result.success(
                                ConversationNotificationListener.launch(this, id)
                            )
                        }
                    }
                    "openMessagesApp" ->
                        result.success(
                            ConversationNotificationListener.openMessagesApp(this)
                        )
                    "forget" -> {
                        val id = call.argument<String>("id")
                        if (id == null) {
                            result.error("no_id", "Missing conversation id", null)
                        } else {
                            ConversationNotificationListener.forget(this, id)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** True if the user has granted Threadly notification access. */
    private fun isListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners"
        ) ?: return false
        val component = ComponentName(
            this, ConversationNotificationListener::class.java
        ).flattenToString()
        return flat.split(":").any { entry ->
            entry.equals(component, ignoreCase = true) ||
                entry.startsWith("$packageName/")
        }
    }
}
