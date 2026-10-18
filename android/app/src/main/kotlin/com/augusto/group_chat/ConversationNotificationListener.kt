package com.augusto.group_chat

import android.app.Notification
import android.content.Context
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/** One buffered message: who sent it ("Me" for the user, "" when unknown),
 *  its text, and when it was sent (epoch ms). See
 *  [ConversationNotificationListener.recentMessages]. */
data class RecentMessage(val sender: String, val text: String, val time: Long)

/**
 * The conversation feed.
 *
 * Threadly doesn't read message content; it only needs to
 * know, per conversation, that it exists, when it last received a message, and
 * whether it's unread. The only on-device source for RCS (which no app can read)
 * is Google Messages' own notifications, so this [NotificationListenerService]
 * observes them.
 *
 * It persists a small record per conversation in SharedPreferences (title +
 * last-activity timestamp + group flag + Google Messages' own conversation id)
 * so the list survives dismissals and restarts, and tracks which conversations
 * currently have an active (= unread) notification. The GM conversation id is
 * what lets [launch] open the exact thread later — see there.
 */
class ConversationNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        // Seed unread state from whatever is already showing.
        activeIds.clear()
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

    // The reason-carrying overload (API 26+, our minSdk); the shorter ones
    // aren't called once this is overridden.
    override fun onNotificationRemoved(
        sbn: StatusBarNotification?,
        rankingMap: RankingMap?,
        reason: Int,
    ) {
        sbn ?: return
        if (sbn.packageName != MESSAGES_PKG) return
        val id = conversationId(sbn) ?: return
        // Removal in Google Messages means the user has seen it: now read.
        activeIds.remove(id)
        persistActive(this)
        // Tapped (not swiped or read elsewhere): Messages is opening that
        // thread, so put Threadly one tap away over it.
        val summary = (sbn.notification?.flags ?: 0) and Notification.FLAG_GROUP_SUMMARY != 0
        if (reason == REASON_CLICK && !summary) {
            ReturnChip.showForNotificationTap(this, id)
        }
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
        if (title.isEmpty()) {
            // Android 15 hands *redacted* (title-less) copies to listeners it
            // doesn't trust with sensitive notifications. Happens when access
            // was granted via `cmd notification allow_listener` (adb) without
            // the RECEIVE_SENSITIVE_NOTIFICATIONS appop — see CLAUDE.md.
            android.util.Log.w(TAG, "empty title for $id — sensitive-notification redaction?")
            return
        }

        activeIds.add(id)

        val store = prefs(this)
        val convos = JSONObject(store.getString(KEY_CONVOS, "{}") ?: "{}")
        // Google Messages' own conversation id, needed by [launch]. It's the
        // notification's shortcutId (GM registers one sharing shortcut per
        // conversation, keyed by that id); the tag ends in the same number.
        var gmId = (if (android.os.Build.VERSION.SDK_INT >= 26) n.shortcutId else null)
            ?: gmIdFromTag(id).orEmpty()
        if (gmId.isEmpty()) {
            gmId = convos.optJSONObject(id)?.optString("gmId").orEmpty()
        }
        // The last-message preview, straight from the notification (so it works
        // for RCS too — no message store is read). If this notification carries
        // no text (e.g. a collapsed "N new messages" summary), keep what we had.
        var preview = parsePreview(extras)
        if (preview.isEmpty()) {
            preview = convos.optJSONObject(id)?.optString("preview").orEmpty()
        }
        val entry = JSONObject()
            .put("title", title)
            .put("ts", sbn.postTime)
            .put("group", isGroup)
            .put("preview", preview)
            .put("gmId", gmId)
        convos.put(id, entry)
        store.edit().putString(KEY_CONVOS, convos.toString()).apply()
        rememberRecent(this, id, extras)
    }

    /**
     * Merge this notification's bundled MessagingStyle history into the
     * conversation's small rolling buffer of recent messages — the on-device
     * input for organizing suggestions ([ConversationSuggester]). Each notification
     * re-bundles recent messages, so entries dedupe on (time, text). Only the
     * newest [RECENT_MAX] are kept, in their own prefs file, which (like all
     * prefs) is outside the auto-backup include list: they never leave the
     * phone.
     */
    @Suppress("DEPRECATION")
    private fun rememberRecent(ctx: Context, id: String, extras: Bundle) {
        val incoming = extras.getParcelableArray("android.messages")?.mapNotNull { m ->
            val b = m as? Bundle ?: return@mapNotNull null
            val text = b.getCharSequence("text")?.toString()?.trim().orEmpty()
            if (text.isEmpty()) return@mapNotNull null
            // A null sender is the user themselves (e.g. an inline reply).
            val sender = b.getCharSequence("sender")?.toString()?.trim()
            JSONObject()
                .put("t", b.getLong("time", 0L))
                .put("s", if (sender.isNullOrEmpty()) "Me" else sender)
                .put("x", text)
        }.orEmpty()
        if (incoming.isEmpty()) return
        val store = recentPrefs(ctx)
        val all = JSONObject(store.getString(KEY_RECENT, "{}") ?: "{}")
        val merged = LinkedHashMap<String, JSONObject>()
        val existing = all.optJSONArray(id)
        for (i in 0 until (existing?.length() ?: 0)) {
            val e = existing!!.getJSONObject(i)
            merged["${e.optLong("t")}|${e.optString("x")}"] = e
        }
        for (e in incoming) merged["${e.optLong("t")}|${e.optString("x")}"] = e
        val kept = merged.values.sortedBy { it.optLong("t") }.takeLast(RECENT_MAX)
        all.put(id, org.json.JSONArray(kept))
        store.edit().putString(KEY_RECENT, all.toString()).apply()
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
        private const val TAG = "ThreadlyListener"
        private const val MESSAGES_PKG = "com.google.android.apps.messaging"
        private const val PREFS = "threadly_notifications"
        private const val KEY_CONVOS = "conversations"
        private const val KEY_ACTIVE = "active"
        private const val RECENT_PREFS = "threadly_recent"
        private const val KEY_RECENT = "recent"
        private const val RECENT_MAX = 10

        /** Ids of conversations with a currently-active (= unread) notification. */
        private val activeIds = HashSet<String>()

        /** GM's conversation-list activity; its LAUNCHER intent takes a
         *  `conversation_id` extra that opens that thread (how GM's own
         *  per-conversation shortcuts work). */
        private const val MESSAGES_LIST_ACTIVITY =
            "com.google.android.apps.messaging.ui.ConversationListActivity"

        private fun prefs(ctx: Context) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun recentPrefs(ctx: Context) =
            ctx.getSharedPreferences(RECENT_PREFS, Context.MODE_PRIVATE)

        /**
         * The conversation's recent messages, oldest first — see
         * [rememberRecent]. Falls back to the stored preview alone (timed at
         * the conversation's last activity) when no bundle has been seen yet
         * (conversations from before this existed).
         */
        fun recentMessages(ctx: Context, id: String): List<RecentMessage> {
            val all = JSONObject(recentPrefs(ctx).getString(KEY_RECENT, "{}") ?: "{}")
            val arr = all.optJSONArray(id)
            if (arr != null && arr.length() > 0) {
                return (0 until arr.length()).map {
                    val e = arr.getJSONObject(it)
                    RecentMessage(e.optString("s"), e.optString("x"), e.optLong("t"))
                }
            }
            val convos = JSONObject(prefs(ctx).getString(KEY_CONVOS, "{}") ?: "{}")
            val entry = convos.optJSONObject(id)
            val preview = entry?.optString("preview").orEmpty()
            return if (preview.isEmpty()) emptyList()
            else listOf(RecentMessage("", preview, entry?.optLong("ts") ?: 0L))
        }

        /** Newest-message marker for [id], so suggestions can be cached until
         *  something new arrives. */
        fun lastActivity(ctx: Context, id: String): Long {
            val convos = JSONObject(prefs(ctx).getString(KEY_CONVOS, "{}") ?: "{}")
            return convos.optJSONObject(id)?.optLong("ts") ?: 0L
        }

        /** A stable per-conversation id: Google Messages uses the tag. */
        private fun conversationId(sbn: StatusBarNotification): String? =
            sbn.tag ?: sbn.key

        /** GM tags look like `<pkg>:incoming_message:<conversation id>`. */
        private fun gmIdFromTag(id: String): String? =
            Regex(""":(\d+)$""").find(id)?.groupValues?.get(1)

        private fun persistActive(ctx: Context) {
            prefs(ctx).edit()
                .putStringSet(KEY_ACTIVE, HashSet(activeIds))
                .apply()
        }

        /**
         * The conversation list for Flutter: a JSON array of
         * {id, title, ts, group, preview, unread}, newest activity first.
         */
        fun conversationsJson(ctx: Context): String {
            val store = prefs(ctx)
            val convos = JSONObject(store.getString(KEY_CONVOS, "{}") ?: "{}")
            val active = store.getStringSet(KEY_ACTIVE, emptySet()) ?: emptySet()
            val recent = JSONObject(recentPrefs(ctx).getString(KEY_RECENT, "{}") ?: "{}")
            val out = ArrayList<JSONObject>()
            for (id in convos.keys()) {
                val e = convos.getJSONObject(id)
                // The newest buffered message is the user's own (an inline
                // reply from the notification): they've answered.
                val buf = recent.optJSONArray(id)
                val lastFromMe = buf != null && buf.length() > 0 &&
                    buf.getJSONObject(buf.length() - 1).optString("s") == "Me"
                out.add(
                    JSONObject()
                        .put("id", id)
                        .put("title", e.optString("title"))
                        .put("ts", e.optLong("ts"))
                        .put("group", e.optBoolean("group", false))
                        .put("preview", e.optString("preview"))
                        .put("unread", active.contains(id))
                        .put("lastFromMe", lastFromMe)
                )
            }
            out.sortByDescending { it.optLong("ts") }
            val arr = org.json.JSONArray()
            out.forEach { arr.put(it) }
            return arr.toString()
        }

        /**
         * Open the *exact* conversation thread in Google Messages — any kind,
         * incoming RCS groups included, whether or not its notification is still
         * showing.
         *
         * This replays what GM's own per-conversation sharing shortcut does: a
         * plain LAUNCHER intent to its conversation-list activity carrying the
         * conversation id (`dumpsys shortcut` shows the recipe). It's a
         * constructed intent, not a PendingIntent, so nothing expires; the only
         * thing we need is the id, captured from the notification. Relies on
         * undocumented GM extras (`conversation_id` must be a *String* — an int
         * lands in the inbox), so callers keep the `sms:` / inbox fallbacks.
         * Returns false if the id is unknown or the activity is gone.
         */
        fun launch(ctx: Context, id: String): Boolean {
            val convos = JSONObject(prefs(ctx).getString(KEY_CONVOS, "{}") ?: "{}")
            // Entries recorded before gmId was stored still carry it in the tag.
            val gmId = convos.optJSONObject(id)?.optString("gmId")
                ?.ifEmpty { null } ?: gmIdFromTag(id) ?: return false
            val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_LAUNCHER)
                .setClassName(MESSAGES_PKG, MESSAGES_LIST_ACTIVITY)
                .putExtra("conversation_id", gmId)
                .putExtra("mapi_conversation_kind", 1)
                .putExtra("via_shortcut", true)
                // CLEAR_TASK matters: if GM's inbox is already alive the intent
                // is otherwise delivered via onNewIntent, which ignores the id.
                .addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK
                )
            return try {
                ctx.startActivity(intent)
                true
            } catch (_: android.content.ActivityNotFoundException) {
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
            activeIds.remove(id)
            store.edit()
                .putString(KEY_CONVOS, convos.toString())
                .putStringSet(KEY_ACTIVE, HashSet(activeIds))
                .apply()
            val recent = recentPrefs(ctx)
            val all = JSONObject(recent.getString(KEY_RECENT, "{}") ?: "{}")
            all.remove(id)
            recent.edit().putString(KEY_RECENT, all.toString()).apply()
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
