import 'package:flutter/services.dart';

import 'notifications.dart';

/// What the on-device model proposes for a conversation. Any field may be
/// null; the UI always asks before saving any of it.
class Suggestion {
  const Suggestion({this.nickname, this.note, this.category});

  /// A group's main topic ("Soccer carpool"), or for a raw-number 1:1 the
  /// person's own name when they state it (also offered as a new contact).
  /// Never set for a saved contact, whose name already shows.
  final String? nickname;

  /// What the chat is about, e.g. "Picking next month's book".
  final String? note;

  /// One of the user's existing category names (never a new one).
  final String? category;

  bool get isEmpty => nickname == null && note == null && category == null;
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
      );
      return s.isEmpty ? null : s;
    } on PlatformException {
      return null;
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
