import 'dart:convert';

import 'package:flutter/services.dart';

/// A conversation as seen through Google Messages' notifications — Threadly's
/// bridge-free "a new message arrived" signal. There is no message content here
/// (by design): just identity, recency, and unread state, enough to organize and
/// hand off to the native app.
class Conversation {
  /// Stable per-conversation id from the notification (used as the organizing
  /// key for nicknames/notes/categories).
  final String id;

  /// Display title from the notification: a contact name, a number, or a group
  /// name.
  final String title;

  /// When the most recent message arrived.
  final DateTime lastActivity;

  /// True while Google Messages still shows a notification for it (i.e. unread).
  final bool unread;

  final bool isGroup;

  /// Member phone numbers harvested from the notification, when available (used
  /// to reopen a group thread via the sms: deep link). May be empty.
  final List<String> members;

  const Conversation({
    required this.id,
    required this.title,
    required this.lastActivity,
    required this.unread,
    required this.isGroup,
    this.members = const [],
  });
}

/// Talks to the native [ConversationNotificationListener] over a method channel.
/// Android-only; the methods throw [MissingPluginException] elsewhere, which the
/// caller treats as "unsupported".
class NotificationConversationsService {
  static const MethodChannel _ch = MethodChannel('threadly/notifications');

  /// Whether the user has granted "notification access" to Threadly.
  Future<bool> permissionGranted() async {
    try {
      return await _ch.invokeMethod<bool>('permissionGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Open the system "notification access" settings so the user can grant it.
  Future<void> openSettings() => _ch.invokeMethod<void>('openSettings');

  /// All conversations the listener has recorded, newest activity first.
  Future<List<Conversation>> conversations() async {
    final raw = await _ch.invokeMethod<String>('conversations') ?? '[]';
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return [
      for (final m in list)
        Conversation(
          id: m['id'] as String,
          title: (m['title'] as String?)?.trim() ?? '',
          lastActivity: DateTime.fromMillisecondsSinceEpoch(
              (m['ts'] as num?)?.toInt() ?? 0),
          unread: (m['unread'] as bool?) ?? false,
          isGroup: (m['group'] as bool?) ?? false,
          members: ((m['members'] as String?) ?? '')
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
    ];
  }

  /// Open the *exact* [id] thread via the live notification's contentIntent.
  /// Returns false if there's no active notification (caller should fall back).
  Future<bool> launch(String id) async {
    try {
      return await _ch.invokeMethod<bool>('launch', {'id': id}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Google Messages (its inbox) as a last resort.
  Future<bool> openMessagesApp() async {
    try {
      return await _ch.invokeMethod<bool>('openMessagesApp') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
