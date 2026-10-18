/// Who belongs in the "To reply" tab. Threadly can't see messages the user
/// sends from Google Messages, so "replied" is approximate: a chat leaves the
/// tab when Threadly sees the user's reply (an inline reply from the
/// notification, or Ask Threadly opening a reply), or when the user swipes it
/// Done. A newer message brings it back.
library;

/// How far back the tab looks.
const replyWindow = Duration(days: 7);

/// Per-conversation reply bookkeeping (the `reply_state` table).
class ReplyState {
  const ReplyState({this.doneAtMs, this.verdictAtMs, this.needsReply});

  /// The conversation's last activity when the user marked it done (or
  /// replied through Threadly). Done while no newer message has arrived.
  final int? doneAtMs;

  /// The last activity the AI verdict [needsReply] was made for.
  final int? verdictAtMs;
  final bool? needsReply;

  static const none = ReplyState();
}

/// A message that's just a reaction to another ("👍 to “See you there”").
/// The reaction is an emoji, never a word, so "Talk to “Mom”" doesn't count.
bool looksLikeReaction(String text) =>
    RegExp(r'^[^\p{L}\p{N}\s]{1,8} to [“"]', unicode: true)
        .hasMatch(text.trim());

/// Whether a conversation shows in "To reply". Until the AI has judged the
/// newest message, it gets the benefit of the doubt (shown).
bool belongsInToReply({
  required DateTime lastActivity,
  required bool lastFromMe,
  required String? preview,
  required ReplyState state,
  required DateTime now,
}) {
  if (lastFromMe) return false;
  if (preview == null || preview.trim().isEmpty) return false;
  if (looksLikeReaction(preview)) return false;
  if (now.difference(lastActivity) > replyWindow) return false;
  final at = lastActivity.millisecondsSinceEpoch;
  if (state.doneAtMs != null && state.doneAtMs! >= at) return false;
  if (state.verdictAtMs == at && state.needsReply == false) return false;
  return true;
}

/// Whether the AI still needs to judge this conversation's newest message.
bool needsVerdict({
  required DateTime lastActivity,
  required ReplyState state,
}) =>
    state.verdictAtMs != lastActivity.millisecondsSinceEpoch;
