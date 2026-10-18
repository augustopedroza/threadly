/// An "Ask Threadly" instruction after on-device interpretation
/// (`ConversationSuggester.interpret`): one action and the words it needs,
/// still unresolved — names go through contacts, dates through
/// `parseDueDate`, categories through the user's list.
library;

enum CommandAction { forward, reply, remind, file }

class ThreadlyCommand {
  const ThreadlyCommand({
    required this.action,
    this.to,
    this.text,
    this.when,
    this.category,
    this.nickname,
  });

  final CommandAction action;

  /// A person's name as said, or null for the conversation itself.
  final String? to;

  /// Forward: a lead-in like "From Adam". Reply: the message. Remind: what
  /// it's about.
  final String? text;

  /// Remind: date/time words copied from the instruction.
  final String? when;

  /// File: one of the user's category names, exactly.
  final String? category;

  /// File: a new nickname.
  final String? nickname;

  /// From the native channel's map, or null for an unknown action.
  static ThreadlyCommand? fromMap(Map<String, String> m) {
    final action = switch (m['action']) {
      'FORWARD' => CommandAction.forward,
      'REPLY' => CommandAction.reply,
      'REMIND' => CommandAction.remind,
      'FILE' => CommandAction.file,
      _ => null,
    };
    if (action == null) return null;
    final to = m['to'];
    return ThreadlyCommand(
      action: action,
      to: (to == null || to == 'THIS') ? null : to,
      text: m['text'],
      when: m['when'],
      category: m['category'],
      nickname: m['nickname'],
    );
  }
}

/// The text of a forwarded message: the user's lead-in if they gave one
/// ("From Adam: “…”"), else credit the original sender when known, else
/// "Fwd:".
String forwardBody(String message, {String? note, String? sender}) {
  final quoted = '“${message.trim()}”';
  final lead = note?.trim().replaceAll(RegExp(r'[:\s]+$'), '') ?? '';
  if (lead.isNotEmpty) {
    return '${lead[0].toUpperCase()}${lead.substring(1)}: $quoted';
  }
  final who = sender?.trim() ?? '';
  if (who.isNotEmpty && who != 'Me') return 'From $who: $quoted';
  return 'Fwd: $quoted';
}
