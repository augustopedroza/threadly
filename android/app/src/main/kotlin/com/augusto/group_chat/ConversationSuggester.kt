package com.augusto.group_chat

import android.content.Context
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * On-device organizing suggestions (Gemini Nano via ML Kit's Prompt API).
 *
 * Reads a conversation's recent messages (the small buffer the listener keeps
 * from notifications) and proposes:
 *  - a nickname: a group's main topic ("Soccer carpool"), or for a 1:1
 *    that's only a phone number, the person's name when they state it ("this
 *    is Ana Lima") — which the UI also offers as a new contact. A saved
 *    contact gets none (its name already shows);
 *  - a note on what the chat is about;
 *  - the best fit among the user's existing categories.
 * Nothing leaves the phone; there's no network permission. The UI always asks
 * before saving anything.
 *
 * Limits worth knowing: AICore only runs inference for the app on screen
 * (`BACKGROUND_USE_BLOCKED` otherwise), so this is called from the activity,
 * never the listener; it has a per-app quota (`BUSY` / battery quota); and
 * it's only on supported devices (recent Pixels and some flagships). Every
 * failure just means "no suggestion".
 */
object ConversationSuggester {
    private const val TAG = "ThreadlySuggest"
    private const val PREFS = "threadly_suggest"
    private const val KEY_DISMISSED = "dismissed"

    private val model by lazy { Generation.getClient() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile private var downloading = false

    /** id -> (inputs it was computed for, suggestion). */
    private val cache = HashMap<String, Pair<String, Map<String, String>>>()

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The user asked never to suggest for [id] again. */
    fun dismiss(ctx: Context, id: String) {
        val set = HashSet(prefs(ctx).getStringSet(KEY_DISMISSED, emptySet()) ?: emptySet())
        set.add(id)
        prefs(ctx).edit().putStringSet(KEY_DISMISSED, set).apply()
    }

    private fun dismissed(ctx: Context, id: String) =
        prefs(ctx).getStringSet(KEY_DISMISSED, emptySet())?.contains(id) == true

    /** Whether the model is ready; kicks off its (one-time) download if not. */
    private suspend fun ready(): Boolean {
        val status = model.checkStatus()
        if (status != FeatureStatus.AVAILABLE) {
            android.util.Log.i(TAG, "model not ready: status=$status (1=downloadable 2=downloading 0=unavailable)")
        }
        return when (status) {
            FeatureStatus.AVAILABLE -> true
            FeatureStatus.DOWNLOADABLE -> {
                startDownload()
                false
            }
            else -> false // DOWNLOADING, or UNAVAILABLE on this device
        }
    }

    private fun startDownload() {
        if (downloading) return
        downloading = true
        scope.launch {
            try {
                model.download().collect { status ->
                    if (status is DownloadStatus.DownloadFailed) {
                        android.util.Log.w(TAG, "model download failed: ${status.e}")
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w(TAG, "model download error", e)
            } finally {
                downloading = false
            }
        }
    }

    /**
     * Suggest for one conversation: `{"nickname", "note", "category"}` (each
     * may be absent), or null for nothing useful / AI unavailable / dismissed.
     * [categories] are the user's categories this conversation isn't in yet
     * (a suggestion is always one of them, never a new one). [wantName] marks
     * a raw-number 1:1, whose nickname is the person's name. [force] ignores
     * [dismiss] — for when the user opened the organize sheet themselves.
     */
    suspend fun suggest(
        ctx: Context,
        id: String,
        title: String,
        isGroup: Boolean,
        wantName: Boolean,
        categories: List<String>,
        force: Boolean,
    ): Map<String, String>? {
        if (!force && dismissed(ctx, id)) return null
        val stamp = "${ConversationNotificationListener.lastActivity(ctx, id)}|$wantName|" +
            categories.joinToString("\u0001")
        cache[id]?.let { (at, s) -> if (at == stamp) return s.ifEmpty { null } }
        val messages = ConversationNotificationListener.recentMessages(ctx, id)
        if (messages.isEmpty()) {
            android.util.Log.i(TAG, "suggest $id: no messages to go on")
            return null
        }
        val out = try {
            if (!ready()) return null
            val response = model.generateContent(
                generateContentRequest(
                    TextPart(prompt(title, isGroup, wantName, categories, messages))
                ) {
                    temperature = 0.2f
                    topK = 10
                    maxOutputTokens = 64
                }
            )
            parse(
                response.candidates.firstOrNull()?.text.orEmpty(),
                title, isGroup, wantName, categories,
            )
        } catch (e: GenAiException) {
            // BUSY / quota / background: no suggestion this time, try again later.
            android.util.Log.w(TAG, "suggest $id: ${e.errorCode} ${e.message}")
            return null
        }
        cache[id] = stamp to out
        return out.ifEmpty { null }
    }

    private fun prompt(
        title: String,
        isGroup: Boolean,
        wantName: Boolean,
        categories: List<String>,
        messages: List<Pair<String, String>>,
    ): String {
        val lines = messages.joinToString("\n") { (sender, text) ->
            val who = sender.ifEmpty { if (isGroup) "Someone" else title }
            "$who: ${text.take(300).replace('\n', ' ')}"
        }
        val kind = if (isGroup) "a group chat" else "a one-on-one chat"
        val nicknameHint = when {
            isGroup -> "<the group's main topic in 1-4 words, e.g. Soccer carpool, Book club>"
            wantName ->
                "<the other person's own name, only if they state it or sign with it " +
                    "(\"this is Ana Lima\", \"- Todd\"); never the name of the person " +
                    "they write to>"
            else -> "NONE"
        }
        val categoryHint = if (categories.isEmpty()) "NONE"
        else "<one of: ${categories.joinToString(", ")} - copied exactly>"
        // Gemini Nano is small: a literal template plus one example keeps the
        // labels in its answer. The example matches the chat type and avoids
        // categories and names, so it doesn't nudge toward guessing.
        val example = if (isGroup) {
            "NICKNAME: Book club\nNOTE: Picking next month's book\nCATEGORY: NONE"
        } else {
            "NICKNAME: NONE\nNOTE: Questions about rent and repairs\nCATEGORY: NONE"
        }
        return buildString {
            appendLine("You help organize a phone's text conversations.")
            appendLine("This is $kind shown as \"$title\". Recent messages, oldest first:")
            appendLine(lines)
            appendLine()
            appendLine(
                "Fill in this template. Keep the three labels exactly. Write NONE for " +
                    "anything you can't tell from the messages."
            )
            appendLine("NICKNAME: $nicknameHint")
            appendLine(
                "NOTE: <3-8 specific words on what this chat is about, naming the topic " +
                    "(a sport, rent, a trip, a project)>"
            )
            appendLine("CATEGORY: $categoryHint")
            appendLine()
            appendLine("Example answer:")
            append(example)
        }
    }

    private fun parse(
        raw: String,
        title: String,
        isGroup: Boolean,
        wantName: Boolean,
        categories: List<String>,
    ): Map<String, String> {
        val lines = raw.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
        val keys = listOf("NICKNAME", "NOTE", "CATEGORY")
        // The model sometimes drops the labels; three bare lines are then
        // read in template order.
        val labeled = lines.any { l -> keys.any { l.startsWith("$it:", ignoreCase = true) } }
        fun field(key: String): String? {
            val line = if (labeled) {
                lines.firstOrNull { it.startsWith("$key:", ignoreCase = true) }
                    ?.substringAfter(':')
            } else {
                lines.takeIf { it.size == keys.size }?.get(keys.indexOf(key))
            } ?: return null
            val v = line.trim().trim('"', '\'', '*', '.', '<', '>', ' ')
            // "NONE", but also "NONE - NONE" and the like.
            val rest = v.replace(Regex("(?i)\\bnone\\b"), "").trim(' ', '-', '/', ',', '\u2013')
            if (v.isEmpty() || rest.isEmpty()) return null
            return v
        }
        val out = HashMap<String, String>()
        field("NICKNAME")?.let { v ->
            val words = v.split(Regex("\\s+")).size
            when {
                // A group's topic: short, and not just its title again.
                isGroup -> if (v.length <= 40 && words <= 5 && !v.equals(title, ignoreCase = true)) {
                    out["nickname"] = v
                }
                // A person's name: a few words, no digits.
                wantName -> if (v.length <= 40 && words in 1..4 && v.none { it.isDigit() }) {
                    out["nickname"] = v
                }
                // A saved contact already shows its name.
            }
        }
        field("NOTE")?.let { note ->
            // Drop a leading "Title - " the model sometimes adds.
            val v = note.removePrefix(title).trimStart(' ', '-', ':', '\u2013', '\u2014')
            val words = v.split(Regex("\\s+")).size
            // 2+ words: a lone word is usually a placeholder ("Image").
            if (v.length <= 60 && words in 2..10) out["note"] = v
        }
        // Only ever one of the user's own categories, in its exact spelling.
        field("CATEGORY")?.let { v ->
            categories.firstOrNull { it.equals(v, ignoreCase = true) }
                ?.let { out["category"] = it }
        }
        return out
    }
}
