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
 *  - the best fit among the user's existing categories;
 *  - a reminder: a date/time someone mentions for an upcoming plan or
 *    deadline. The model only *copies* the date words ("Saturday at 9am") and
 *    says what they're for; turning them into a date is deterministic Dart
 *    (`lib/models/due_date.dart`), anchored to when that message was sent —
 *    small models copy text well but get date arithmetic wrong.
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
     * Suggest for one conversation: `{"nickname", "note", "category",
     * "dueText", "dueWhat", "dueRef"}` (each may be absent; `dueRef` is the
     * epoch ms of the message the date words came from, as a string), or null
     * for nothing useful / AI unavailable / dismissed.
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
                    maxOutputTokens = 96
                }
            )
            parse(
                response.candidates.firstOrNull()?.text.orEmpty(),
                title, isGroup, wantName, categories, messages,
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
        messages: List<RecentMessage>,
    ): String {
        val lines = messages.joinToString("\n") { m ->
            val who = m.sender.ifEmpty { if (isGroup) "Someone" else title }
            "$who: ${m.text.take(300).replace('\n', ' ')}"
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
            "NICKNAME: Book club\nNOTE: Picking next month's book\nCATEGORY: NONE\n" +
                "REMIND: Thursday at 7pm | Book club meeting"
        } else {
            "NICKNAME: NONE\nNOTE: Questions about rent and repairs\nCATEGORY: NONE\n" +
                "REMIND: NONE"
        }
        return buildString {
            appendLine("You help organize a phone's text conversations.")
            appendLine("This is $kind shown as \"$title\". Recent messages, oldest first:")
            appendLine(lines)
            appendLine()
            appendLine(
                "Fill in this template. Keep the four labels exactly. Write NONE for " +
                    "anything you can't tell from the messages."
            )
            appendLine("NICKNAME: $nicknameHint")
            appendLine(
                "NOTE: <3-8 specific words on what this chat is about, naming the topic " +
                    "(a sport, rent, a trip, a project)>"
            )
            appendLine("CATEGORY: $categoryHint")
            appendLine(
                "REMIND: <for an upcoming plan, event, or deadline: the date/time words " +
                    "copied exactly as written in a message (e.g. Saturday at 9am, Oct 20, " +
                    "tomorrow at noon), then | and what it is in 2-5 words. NONE if no " +
                    "message mentions a future date or time>"
            )
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
        messages: List<RecentMessage>,
    ): Map<String, String> {
        val fields = readFields(raw, listOf("NICKNAME", "NOTE", "CATEGORY", "REMIND"))
        fun field(key: String) = fields[key]
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
        // "Saturday at 9am | Practice". Keep the words only if they really
        // appear in a message (no invented dates), and pass along when that
        // message was sent: relative words resolve against it in Dart.
        field("REMIND")?.let { v ->
            val words = v.substringBefore('|').trim().trim('"', '\'', '.', ' ')
            val what = v.substringAfter('|', "").trim().trim('"', '\'', '.', ' ')
            if (words.isEmpty() || words.length > 40) return@let
            val norm = { t: String -> t.lowercase().replace(Regex("\\s+"), " ") }
            val source = messages.lastOrNull { norm(it.text).contains(norm(words)) }
                ?: return@let
            out["dueText"] = words
            if (what.isNotEmpty() && what.length <= 40 &&
                !what.equals("none", ignoreCase = true)
            ) {
                out["dueWhat"] = what
            }
            out["dueRef"] = (if (source.time > 0) source.time else System.currentTimeMillis())
                .toString()
        }
        return out
    }

    /**
     * "LABEL: value" lines from a template answer, by label, with NONE-ish
     * values dropped. Gemini Nano sometimes drops the labels; then exactly
     * [keys].size bare lines are read in template order.
     */
    private fun readFields(raw: String, keys: List<String>): Map<String, String> {
        val lines = raw.lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList()
        val labeled = lines.any { l -> keys.any { l.startsWith("$it:", ignoreCase = true) } }
        val out = HashMap<String, String>()
        for ((i, key) in keys.withIndex()) {
            val line = if (labeled) {
                lines.firstOrNull { it.startsWith("$key:", ignoreCase = true) }
                    ?.substringAfter(':')
            } else {
                lines.takeIf { it.size == keys.size }?.get(i)
            } ?: continue
            val v = line.trim().trim('"', '\'', '*', '.', '<', '>', ' ')
            // "NONE", but also "NONE - NONE", "NONE | NONE" and the like.
            val rest = v.replace(Regex("(?i)\\bnone\\b"), "")
                .trim(' ', '-', '/', ',', '|', '\u2013')
            if (v.isNotEmpty() && rest.isNotEmpty()) out[key] = v
        }
        return out
    }

    // --- "To reply" -------------------------------------------------------------

    /**
     * Whether the conversation's newest message needs an answer from the
     * user (a question, request, invitation…) — the "To reply" tab's filter.
     * `"yes"` / `"no"`, or null when the model can't run right now (the tab
     * then keeps the chat, giving it the benefit of the doubt).
     */
    suspend fun needsReply(ctx: Context, id: String, title: String, isGroup: Boolean): String? {
        val messages = ConversationNotificationListener.recentMessages(ctx, id)
        val last = messages.lastOrNull() ?: return null
        if (last.sender == "Me") return "no"
        // A reaction ("👍 to “…”": an emoji, never a word) never needs one.
        if (Regex("^[^\\p{L}\\p{N}\\s]{1,8} to [“\"]").containsMatchIn(last.text.trim())) return "no"
        return try {
            if (!ready()) return null
            val response = model.generateContent(
                generateContentRequest(TextPart(replyPrompt(title, isGroup, messages))) {
                    temperature = 0.0f
                    topK = 1
                    maxOutputTokens = 4
                }
            )
            val answer = response.candidates.firstOrNull()?.text.orEmpty().uppercase()
            when {
                "YES" in answer -> "yes"
                "NO" in answer -> "no"
                else -> null
            }
        } catch (e: GenAiException) {
            android.util.Log.w(TAG, "needsReply: ${e.errorCode} ${e.message}")
            null
        }
    }

    private fun replyPrompt(title: String, isGroup: Boolean, messages: List<RecentMessage>): String {
        val lines = messages.takeLast(6).joinToString("\n") { m ->
            val who = m.sender.ifEmpty { if (isGroup) "Someone" else title }
            "$who: ${m.text.take(300).replace('\n', ' ')}"
        }
        val kind = if (isGroup) "a group chat" else "a one-on-one chat"
        return buildString {
            appendLine("You sort a phone owner's text messages. \"Me\" is the owner.")
            appendLine("This is $kind shown as \"$title\". Recent messages, oldest first:")
            appendLine(lines)
            appendLine()
            appendLine(
                "Does the newest message need an answer from the owner? Questions, " +
                    "requests, invitations, and things to confirm do. Thanks, okays, " +
                    "FYIs, updates, and messages meant for someone else in a group don't."
            )
            appendLine("Answer with one word: YES or NO.")
            appendLine()
            appendLine("\"Can you pick up Ava at 5?\" -> YES")
            appendLine("\"ok thanks!\" -> NO")
            appendLine("\"Are we still on for Saturday?\" -> YES")
            appendLine("\"Running 10 minutes late\" -> NO")
            append("Answer:")
        }
    }

    // --- "Ask Threadly" -------------------------------------------------------

    /**
     * Interpret a typed or dictated instruction about one conversation ("forward
     * this to Steve Winters, say it's from Adam") into a single action the UI
     * confirms: `{"action": FORWARD|REPLY|REMIND|FILE, "to", "text", "when",
     * "category", "nickname"}`. `to` is a name as said, or THIS for the
     * conversation itself. The model only *copies* names, dates, and
     * categories; the Dart side resolves them (contacts, `parseDueDate`, the
     * category list), so nothing it invents can go unchecked.
     * `{"error": "unavailable"|"busy"}` when the model can't run, `{}` when
     * the instruction wasn't understood.
     */
    suspend fun interpret(
        title: String,
        isGroup: Boolean,
        command: String,
        categories: List<String>,
    ): Map<String, String> {
        if (command.isBlank()) return emptyMap()
        return try {
            if (!ready()) return mapOf("error" to "unavailable")
            val response = model.generateContent(
                generateContentRequest(
                    TextPart(commandPrompt(title, isGroup, command.take(300), categories))
                ) {
                    temperature = 0.1f
                    topK = 5
                    maxOutputTokens = 120
                }
            )
            parseCommand(response.candidates.firstOrNull()?.text.orEmpty(), categories)
        } catch (e: GenAiException) {
            android.util.Log.w(TAG, "interpret: ${e.errorCode} ${e.message}")
            mapOf("error" to "busy")
        }
    }

    private val commandKeys = listOf("ACTION", "TO", "TEXT", "WHEN", "CATEGORY", "NICKNAME")

    private fun commandPrompt(
        title: String,
        isGroup: Boolean,
        command: String,
        categories: List<String>,
    ): String {
        val kind = if (isGroup) "a group chat" else "a one-on-one chat"
        val cats = if (categories.isEmpty()) "(none)" else categories.joinToString(", ")
        // Few-shot: one example per action. Gemini Nano follows a literal
        // template far better than a description of one.
        return buildString {
            appendLine("You turn a short instruction about a text conversation into one action.")
            appendLine("The conversation is $kind shown as \"$title\". \"This\" means its latest message.")
            appendLine("Categories: $cats")
            appendLine()
            appendLine("Answer with exactly these six lines. Write NONE when a line doesn't apply.")
            appendLine("ACTION: FORWARD, REPLY, REMIND, FILE, or NONE")
            appendLine("TO: for FORWARD or REPLY, the person's name exactly as said; THIS for this conversation itself")
            appendLine(
                "TEXT: FORWARD: a short lead-in naming who it's from if asked (e.g. From Adam); " +
                    "REPLY: the message to send, worded as the user would send it; " +
                    "REMIND: what to be reminded about"
            )
            appendLine("WHEN: REMIND: the date/time words copied exactly from the instruction")
            appendLine("CATEGORY: FILE: one category from the list, copied exactly")
            appendLine("NICKNAME: FILE: the new name for this conversation, if one is given")
            appendLine()
            appendLine("Instruction: forward this to Maria Lopez and say it's from the coach")
            appendLine("ACTION: FORWARD\nTO: Maria Lopez\nTEXT: From the coach\nWHEN: NONE\nCATEGORY: NONE\nNICKNAME: NONE")
            appendLine()
            appendLine("Instruction: tell them I'll be 10 minutes late")
            appendLine("ACTION: REPLY\nTO: THIS\nTEXT: I'll be 10 minutes late\nWHEN: NONE\nCATEGORY: NONE\nNICKNAME: NONE")
            appendLine()
            appendLine("Instruction: text Joe that the game moved to Sunday")
            appendLine("ACTION: REPLY\nTO: Joe\nTEXT: The game moved to Sunday\nWHEN: NONE\nCATEGORY: NONE\nNICKNAME: NONE")
            appendLine()
            appendLine("Instruction: remind me about this Friday at 5")
            appendLine("ACTION: REMIND\nTO: NONE\nTEXT: NONE\nWHEN: Friday at 5\nCATEGORY: NONE\nNICKNAME: NONE")
            appendLine()
            appendLine("Instruction: file this under Work and call it budget team")
            appendLine("ACTION: FILE\nTO: NONE\nTEXT: NONE\nWHEN: NONE\nCATEGORY: Work\nNICKNAME: budget team")
            appendLine()
            append("Instruction: $command")
        }
    }

    private fun parseCommand(raw: String, categories: List<String>): Map<String, String> {
        val f = readFields(raw, commandKeys)
        val action = f["ACTION"]?.uppercase()?.trim()
            ?.takeIf { it in setOf("FORWARD", "REPLY", "REMIND", "FILE") }
            ?: return emptyMap()
        val out = HashMap<String, String>()
        out["action"] = action
        f["TO"]?.let { to ->
            out["to"] = if (to.equals("THIS", ignoreCase = true) ||
                to.equals("them", ignoreCase = true)
            ) "THIS" else to.take(60)
        }
        f["TEXT"]?.let { out["text"] = it.take(300) }
        f["WHEN"]?.let { out["when"] = it.take(60) }
        // Only ever one of the user's own categories, in its exact spelling.
        f["CATEGORY"]?.let { v ->
            categories.firstOrNull { it.equals(v, ignoreCase = true) }?.let { out["category"] = it }
        }
        f["NICKNAME"]?.let { if (it.length <= 40) out["nickname"] = it }
        return out
    }
}
