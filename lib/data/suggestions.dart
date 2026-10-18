import 'package:flutter/services.dart';

import '../models/command.dart';
import '../models/due_date.dart';
import 'notifications.dart';

/// What the on-device model proposes for a conversation. Any field may be
/// null; the UI always asks before saving any of it.
class Suggestion {
  const Suggestion({
    this.nickname,
    this.note,
    this.category,
    this.remindAt,
    this.remindWhat,
  });

  /// A group's main topic ("Soccer carpool"), or for a raw-number 1:1 the
  /// person's own name when they state it (also offered as a new contact).
  /// Never set for a saved contact, whose name already shows.
  final String? nickname;

  /// What the chat is about, e.g. "Picking next month's book".
  final String? note;

  /// One of the user's existing category names (never a new one).
  final String? category;

  /// When to remind: an upcoming date/time mentioned in a message, resolved
  /// from its words (see `parseDueDate`). Always in the future.
  final DateTime? remindAt;

  /// What [remindAt] is for, e.g. "Soccer practice".
  final String? remindWhat;

  bool get isEmpty =>
      nickname == null && note == null && category == null && remindAt == null;

  Suggestion copyWith({
    bool dropNickname = false,
    bool dropNote = false,
    bool dropCategory = false,
    bool dropRemind = false,
  }) =>
      Suggestion(
        nickname: dropNickname ? null : nickname,
        note: dropNote ? null : note,
        category: dropCategory ? null : category,
        remindAt: dropRemind ? null : remindAt,
        remindWhat: dropRemind ? null : remindWhat,
      );
}

/// On-device organizing suggestions (Gemini Nano through Android's AICore;
/// see `ConversationSuggester.kt`). Free, offline, and private: message text
/// never leaves the phone. Only available on supported devices and only while
/// Threadly is on screen; anything else just yields no suggestion.
class SuggestionService {
  static const _ch = MethodChannel('threadly/suggest');

  /// Suggest for [c]. [categories] are names of categories it isn't in yet;
  /// [wantName] marks a raw-number 1:1 (nickname = name); [force] ignores
  /// "don't suggest for this one" (the user opened the organize sheet).
  Future<Suggestion?> suggest(
    Conversation c, {
    required List<String> categories,
    required bool wantName,
    bool force = false,
  }) async {
    try {
      final m = await _ch.invokeMapMethod<String, String>('suggest', {
        'id': c.id,
        'title': c.title,
        'isGroup': c.isGroup,
        'wantName': wantName,
        'categories': categories,
        'force': force,
      });
      if (m == null) return null;
      final s = Suggestion(
        nickname: m['nickname'],
        note: m['note'],
        category: m['category'],
        remindAt: _resolveDue(m['dueText'], m['dueRef']),
        remindWhat: m['dueWhat'],
      );
      return s.isEmpty ? null : s;
    } on PlatformException {
      return null;
    }
  }

  /// The model's copied date words, resolved against when that message was
  /// sent; only a moment in the coming year counts (past plans are moot).
  static DateTime? _resolveDue(String? words, String? refMs) {
    if (words == null) return null;
    final ref = int.tryParse(refMs ?? '');
    final due = parseDueDate(
      words,
      ref != null ? DateTime.fromMillisecondsSinceEpoch(ref) : DateTime.now(),
    );
    final now = DateTime.now();
    if (due == null ||
        !due.when.isAfter(now) ||
        due.when.isAfter(now.add(const Duration(days: 366)))) {
      return null;
    }
    return due.when;
  }

  /// Interpret an "Ask Threadly" instruction about [c] on the device. A
  /// [ThreadlyCommand] when understood; else [unavailable] says whether the
  /// model couldn't run at all (vs. didn't understand). [categories] are the
  /// categories [c] isn't in yet.
  Future<({ThreadlyCommand? command, bool unavailable})> interpret(
    Conversation c,
    String instruction, {
    required List<String> categories,
  }) async {
    try {
      final m = await _ch.invokeMapMethod<String, String>('interpret', {
        'title': c.title,
        'isGroup': c.isGroup,
        'command': instruction,
        'categories': categories,
      });
      if (m == null) return (command: null, unavailable: false);
      if (m['error'] != null) return (command: null, unavailable: true);
      return (command: ThreadlyCommand.fromMap(m), unavailable: false);
    } on PlatformException {
      return (command: null, unavailable: true);
    }
  }

  /// Whether [c]'s newest message needs an answer (on-device AI): true /
  /// false, or null when the model can't say right now.
  Future<bool?> needsReply(Conversation c) async {
    try {
      final r = await _ch.invokeMethod<String>('needsReply', {
        'id': c.id,
        'title': c.title,
        'isGroup': c.isGroup,
      });
      return switch (r) { 'yes' => true, 'no' => false, _ => null };
    } on PlatformException {
      return null;
    }
  }

  /// [id]'s buffered recent messages, newest first (on-device only).
  Future<List<({String sender, String text, DateTime time})>> recentMessages(
    String id,
  ) async {
    try {
      final list =
          await _ch.invokeListMethod<Map<Object?, Object?>>('recent', {'id': id});
      final out = [
        for (final m in list ?? const <Map<Object?, Object?>>[])
          (
            sender: (m['sender'] as String?) ?? '',
            text: (m['text'] as String?) ?? '',
            time: DateTime.fromMillisecondsSinceEpoch((m['time'] as int?) ?? 0),
          ),
      ];
      return out.reversed.where((m) => m.text.isNotEmpty).toList();
    } on PlatformException {
      return const [];
    }
  }

  /// Never offer suggestions for [id] on return from Messages again.
  Future<void> dismiss(String id) async {
    try {
      await _ch.invokeMethod<void>('dismiss', {'id': id});
    } on PlatformException {
      // best effort
    }
  }

  /// Open the system "new contact" screen prefilled with [name] and [phone];
  /// the user saves (and picks the account) there. False if no contacts app.
  Future<bool> saveContact(String name, String phone) async {
    try {
      return await _ch.invokeMethod<bool>(
              'saveContact', {'name': name, 'phone': phone}) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
