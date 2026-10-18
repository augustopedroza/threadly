package com.augusto.group_chat

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.provider.ContactsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private val channel = "threadly/notifications"
    private val chipChannel = "threadly/return_chip"
    private val suggestChannel = "threadly/suggest"

    /** For suggestions: AICore only serves the app on screen, so they run
     *  in the activity's lifetime. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onResume() {
        super.onResume()
        // We're back: the "return to Threadly" chip has done its job.
        ReturnChip.hide()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, suggestChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "suggest" -> {
                        val id = call.argument<String>("id")
                        if (id == null) {
                            result.error("no_id", "Missing conversation id", null)
                            return@setMethodCallHandler
                        }
                        scope.launch {
                            result.success(
                                ConversationSuggester.suggest(
                                    this@MainActivity,
                                    id,
                                    call.argument<String>("title").orEmpty(),
                                    call.argument<Boolean>("isGroup") == true,
                                    call.argument<Boolean>("wantName") == true,
                                    call.argument<List<String>>("categories").orEmpty(),
                                    call.argument<Boolean>("force") == true,
                                )
                            )
                        }
                    }
                    "dismiss" -> {
                        call.argument<String>("id")?.let { ConversationSuggester.dismiss(this, it) }
                        result.success(null)
                    }
                    "saveContact" -> result.success(
                        openNewContact(
                            call.argument<String>("name").orEmpty(),
                            call.argument<String>("phone").orEmpty(),
                        )
                    )
                    else -> result.notImplemented()
                }
            }
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
                    "show" -> result.success(ReturnChip.show(this))
                    "consumeReturnTarget" -> result.success(ReturnChip.consumeReturnTarget())
                    "hide" -> {
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

    /**
     * Open the system "new contact" editor prefilled with [name] and [phone].
     * The user confirms (and picks the account) there, so Threadly needs no
     * WRITE_CONTACTS and stays read-only on contacts. Launched from the
     * activity so Back / Save returns here.
     */
    private fun openNewContact(name: String, phone: String): Boolean {
        val intent = Intent(ContactsContract.Intents.Insert.ACTION).apply {
            type = ContactsContract.RawContacts.CONTENT_TYPE
            putExtra(ContactsContract.Intents.Insert.NAME, name)
            putExtra(ContactsContract.Intents.Insert.PHONE, phone)
            // Ask the editor to come straight back after Save.
            putExtra("finishActivityOnSaveCompleted", true)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
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
