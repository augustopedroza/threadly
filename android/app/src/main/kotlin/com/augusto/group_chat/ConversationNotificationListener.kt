package com.augusto.group_chat

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/**
 * Bridge-free conversation feed.
 *
 * Threadly's "no-server" mode doesn't read message content; it only needs to
 * know, per conversation, that it exists, when it last received a message, and
 * whether it's unread. The only on-device source for RCS (which no app can read)
 * is Google Messages' own notifications, so this [NotificationListenerService]
 * observes them.
 *
 * It persists a small record per conversation in SharedPreferences (title +
 * last-activity timestamp + group flag) so the list survives dismissals and
 * restarts, and tracks which conversations currently have an active (= unread)
 * notification. It also holds each active notification's contentIntent so the UI
 * can reopen that exact thread in Google Messages while it's still showing.
 */
class ConversationNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        // Seed unread state from whatever is already showing.
        activeIntents.clear()
        try {
            activeNotifications?.forEach { record(it) }
        } catch (_: SecurityException) {
            // Not yet granted / race on connect.
        }
        persistActive(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        record(sbn)
        persistActive(this)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn ?: return
        if (sbn.packageName != MESSAGES_PKG) return
        val id = conversationId(sbn) ?: return
        // Removal in Google Messages means the user has seen it: now read.
        activeIntents.remove(id)
        persistActive(this)
    }

    /** Parse and persist a single Google Messages notification. */
    private fun record(sbn: StatusBarNotification) {
        if (sbn.packageName != MESSAGES_PKG) return
        val n = sbn.notification ?: return
        // Skip the group-summary roll-up — it isn't a conversation.
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val id = conversationId(sbn) ?: return
        val extras = n.extras ?: return

        val (isGroup, title) = parseGroupAndTitle(extras)
        if (title.isEmpty()) return

        n.contentIntent?.let { activeIntents[id] = it }

        val store = prefs(this)
        val convos = JSONObject(store.getString(KEY_CONVOS, "{}") ?: "{}")
        // The last-message preview. This is the only message *content* Threadly
        // keeps, and it comes straight from the notification (so it works for RCS
        // too — no message store is read). If this notification carries no text
        // (e.g. a collapsed "N new messages" summary), keep whatever we last had.
        var preview = parsePreview(extras)
        if (preview.isEmpty()) {
            preview = convos.optJSONObject(id)?.optString("preview").orEmpty()
        }
        val entry = JSONObject()
            .put("title", title)
            .put("ts", sbn.postTime)
            .put("group", isGroup)
            .put("preview", preview)
        convos.put(id, entry)
        store.edit().putString(KEY_CONVOS, convos.toString()).apply()
    }

    /**
     * The latest message's text for the preview line. Prefers the newest entry in
     * the bundled MessagingStyle history (`android.messages`), falling back to the
     * flat notification body (`EXTRA_TEXT`). Works regardless of transport
     * (SMS/MMS/RCS) because it's the notification's own text, not the message
     * store. Only *incoming* messages post notifications, so this reflects the
     * last received message, not one you sent.
     */
    @Suppress("DEPRECATION")
    private fun parsePreview(extras: Bundle): String {
        var bestTime = Long.MIN_VALUE
        var bestText = ""
        extras.getParcelableArray("android.messages")?.forEach { m ->
            val b = m as? Bundle ?: return@forEach
            val text = b.getCharSequence("text")?.toString()?.trim().orEmpty()
            if (text.isEmpty()) return@forEach
            val time = b.getLong("time", 0L)
            if (time >= bestTime) {
                bestTime = time
                bestText = text
            }
        }
        if (bestText.isNotEmpty()) return bestText
        return extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?.trim().orEmpty()
    }

    /**
     * Decide whether a notification is a group chat and pick the best title.
     *
     * Google Messages sets EXTRA_TITLE to the latest *sender* even for groups,
     * so a group can masquerade as a 1:1. We instead consult the group flag, the
     * conversation title (the group's name, also the better label), and whether
     * the bundled message history names more than one sender.
     */
    @Suppress("DEPRECATION")
    private fun parseGroupAndTitle(extras: Bundle): Pair<Boolean, String> {
        val senderTitle = extras.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()?.trim().orEmpty()
        // EXTRA_CONVERSATION_TITLE = "android.conversationTitle" (API 24+).
        val convTitle = extras.getCharSequence("android.conversationTitle")
            ?.toString()?.trim()
        // EXTRA_IS_GROUP_CONVERSATION = "android.isGroupConversation".
        var isGroup = extras.getBoolean("android.isGroupConversation", false)

        // Distinct senders in the bundled MessagingStyle history: more than one
        // means a group.
        val senders = HashSet<String>()
        extras.getParcelableArray("android.messages")?.forEach { m ->
            val b = m as? Bundle ?: return@forEach
            b.getCharSequence("sender")?.toString()?.trim()
                ?.let { if (it.isNotEmpty()) senders.add(it) }
        }
        if (senders.size > 1) isGroup = true
        // Google Messages doesn't set a conversation title for 1:1 chats.
        if (!convTitle.isNullOrEmpty()) isGroup = true

        val title = if (!convTitle.isNullOrEmpty()) convTitle else senderTitle
        return Pair(isGroup, title)
    }

    companion object {
        private const val MESSAGES_PKG = "com.google.android.apps.messaging"
        private const val PREFS = "threadly_notifications"
        private const val KEY_CONVOS = "conversations"
        private const val KEY_ACTIVE = "active"

        /** id -> contentIntent for currently-active notifications. */
        private val activeIntents = HashMap<String, PendingIntent>()

        private fun prefs(ctx: Context) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** A stable per-conversation id: Google Messages uses the tag. */
        private fun conversationId(sbn: StatusBarNotification): String? =
            sbn.tag ?: sbn.key

        private fun persistActive(ctx: Context) {
            prefs(ctx).edit()
                .putStringSet(KEY_ACTIVE, HashSet(activeIntents.keys))
                .apply()
        }

        /**
         * The conversation list for Flutter: a JSON array of
         * {id, title, ts, group, unread}, newest activity first.
         */
        fun conversationsJson(ctx: Context): String {
            val store = prefs(ctx)
            val convos = JSONObject(store.getString(KEY_CONVOS, "{}") ?: "{}")
            val active = store.getStringSet(KEY_ACTIVE, emptySet()) ?: emptySet()
            val out = ArrayList<JSONObject>()
            for (id in convos.keys()) {
                val e = convos.getJSONObject(id)
                out.add(
                    JSONObject()
                        .put("id", id)
                        .put("title", e.optString("title"))
                        .put("ts", e.optLong("ts"))
                        .put("group", e.optBoolean("group", false))
                        .put("preview", e.optString("preview"))
                        .put("unread", active.contains(id))
                )
            }
            out.sortByDescending { it.optLong("ts") }
            val arr = org.json.JSONArray()
            out.forEach { arr.put(it) }
            return arr.toString()
        }

        /**
         * Open the *exact* conversation thread via the live notification's
         * contentIntent. Returns true only if that intent was sent. If there's no
         * active notification, returns false so the caller can fall back (sms:
         * deep link, then [openMessagesApp]).
         */
        fun launch(ctx: Context, id: String): Boolean {
            val pi = activeIntents[id] ?: return false
            return try {
                pi.send()
                true
            } catch (_: PendingIntent.CanceledException) {
                false
            }
        }

        /**
         * Forget a conversation: drop it from the persisted store so it leaves
         * the list. It reappears only if a new message later arrives for it.
         */
        fun forget(ctx: Context, id: String) {
            val store = prefs(ctx)
            val convos = JSONObject(store.getString(KEY_CONVOS, "{}") ?: "{}")
            convos.remove(id)
            activeIntents.remove(id)
            store.edit()
                .putString(KEY_CONVOS, convos.toString())
                .putStringSet(KEY_ACTIVE, HashSet(activeIntents.keys))
                .apply()
        }

        /** Open Google Messages (its inbox) as a last resort. */
        fun openMessagesApp(ctx: Context): Boolean {
            val intent = ctx.packageManager.getLaunchIntentForPackage(MESSAGES_PKG)
                ?: return false
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            return true
        }
    }
}
