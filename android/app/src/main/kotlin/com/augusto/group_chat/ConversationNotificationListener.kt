package com.augusto.group_chat

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.os.Build
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
 * can reopen that exact thread in Google Messages — no phone numbers required.
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
        markRead(this, id)
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
        // Accumulate member numbers across notifications (a single notification
        // may only name the latest sender), so the conversation keeps the full
        // roster we've ever seen.
        val members = LinkedHashSet<String>()
        convos.optJSONObject(id)?.optString("members", "")
            ?.split(",")?.forEach { if (it.isNotEmpty()) members.add(it) }
        members.addAll(extractNumbers(extras))
        // Accumulate distinct sender names too (separated by \u0001 since names
        // can contain commas); the app resolves them to numbers via contacts
        // when the notification didn't carry tel: numbers directly.
        val senders = LinkedHashSet<String>()
        convos.optJSONObject(id)?.optString("senders", "")
            ?.split("\u0001")?.forEach { if (it.isNotEmpty()) senders.add(it) }
        senders.addAll(extractSenders(extras))
        val entry = JSONObject()
            .put("title", title)
            .put("ts", sbn.postTime)
            .put("group", isGroup)
            .put("members", members.joinToString(","))
            .put("senders", senders.joinToString("\u0001"))
        convos.put(id, entry)
        store.edit().putString(KEY_CONVOS, convos.toString()).apply()
    }

    /** Distinct sender display names from the bundled MessagingStyle messages. */
    @Suppress("DEPRECATION")
    private fun extractSenders(extras: Bundle): List<String> {
        val out = LinkedHashSet<String>()
        extras.getParcelableArray("android.messages")?.forEach { m ->
            val b = m as? Bundle ?: return@forEach
            b.getCharSequence("sender")?.toString()?.trim()
                ?.let { if (it.isNotEmpty()) out.add(it) }
        }
        return out.toList()
    }

    /**
     * Member phone numbers carried by the notification — from the legacy
     * EXTRA_PEOPLE uri array, the EXTRA_PEOPLE_LIST [android.app.Person]s, and
     * each message's sender Person. Only `tel:` uris yield a number (a contact
     * `content://` uri can't be turned into a number here).
     */
    @Suppress("DEPRECATION")
    private fun extractNumbers(extras: Bundle): List<String> {
        val uris = mutableListOf<String>()
        extras.getStringArray("android.people")?.forEach { if (it != null) uris.add(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            extras.getParcelableArrayList<android.app.Person>("android.people.list")
                ?.forEach { p -> p.uri?.let { uris.add(it) } }
            extras.getParcelableArray("android.messages")?.forEach { m ->
                val b = m as? Bundle ?: return@forEach
                (b.getParcelable("sender_person") as? android.app.Person)
                    ?.uri?.let { uris.add(it) }
            }
        }
        val numbers = LinkedHashSet<String>()
        for (u in uris) {
            if (!u.startsWith("tel:")) continue
            val cleaned = u.removePrefix("tel:").filter { it.isDigit() || it == '+' }
            if (cleaned.count { it.isDigit() } >= 7) numbers.add(cleaned)
        }
        return numbers.toList()
    }

    /**
     * Decide whether a notification is a group chat and pick the best title.
     *
     * Google Messages sets EXTRA_TITLE to the latest *sender* even for groups,
     * so a group can masquerade as a 1:1. We instead consult the MessagingStyle:
     * its group flag, distinct senders, and conversation title (the group's
     * name / participant list), which is also the better label to show.
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

        // Distinct senders from the bundled MessagingStyle history
        // (EXTRA_MESSAGES = "android.messages"): each entry is a Bundle whose
        // "sender" is the message author. More than one means a group.
        val senders = HashSet<String>()
        val messages = extras.getParcelableArray("android.messages")
        if (messages != null) {
            for (p in messages) {
                val b = p as? Bundle ?: continue
                val sender = b.getCharSequence("sender")?.toString()?.trim()
                if (!sender.isNullOrEmpty()) senders.add(sender)
            }
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

        private fun markRead(ctx: Context, id: String) {
            // Active set is rewritten from activeIntents on every change; nothing
            // else to do here beyond dropping the intent (done by caller).
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
                        .put("unread", active.contains(id))
                        .put("members", e.optString("members", ""))
                        .put("senders", e.optString("senders", ""))
                )
            }
            out.sortByDescending { it.optLong("ts") }
            val arr = org.json.JSONArray()
            out.forEach { arr.put(it) }
            return arr.toString()
        }

        /**
         * Open the *exact* conversation thread via the live notification's
         * contentIntent. Returns true only if that intent was sent — this is the
         * one route that's unambiguous even for two groups with identical
         * members. If there's no active notification, returns false so the caller
         * can fall back (sms: deep link, then [openMessagesApp]).
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
