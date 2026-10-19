import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/later.dart';
import 'organizer_store.dart';

const _snoozeHour = 'snooze_1h';
const _snoozeTomorrow = 'snooze_tomorrow';

/// A tap on the reminder's "Snooze 1 hour" / "Tomorrow morning" buttons.
/// They don't open Threadly, so the plugin runs this in a background isolate
/// (also wired for the foreground). Re-schedules the same reminder and moves
/// the stored time so the list and reminders screen agree.
@pragma('vm:entry-point')
Future<void> onReminderAction(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized();
  final action = response.actionId;
  if (action != _snoozeHour && action != _snoozeTomorrow) return;
  final payload = ReminderPayload.decode(response.payload);
  if (payload == null) return;
  final now = DateTime.now();
  final when =
      action == _snoozeHour ? snoozeAnHour(now) : snoozeTomorrow(now);
  await OrganizerStore().setReminder(payload.id, when.millisecondsSinceEpoch);
  await ReminderService().schedule(payload.id,
      title: payload.title, body: payload.body, when: when);
}

/// What a scheduled reminder carries, so a snooze can re-post it as is.
/// Older reminders carried just the conversation id.
class ReminderPayload {
  const ReminderPayload(this.id, this.title, this.body);

  final String id;
  final String title;
  final String? body;

  String encode() => jsonEncode({'id': id, 'title': title, 'body': body});

  static ReminderPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['id'] is String) {
        return ReminderPayload(m['id'] as String,
            (m['title'] as String?) ?? 'Conversation reminder', m['body'] as String?);
      }
    } on FormatException {
      // A plain conversation id.
    }
    return ReminderPayload(raw, 'Conversation reminder', null);
  }
}

/// Schedules the local "reminder" notifications the user sets on a
/// conversation — the only notifications Threadly ever posts (the listener
/// only *reads* Google Messages' notifications, and it filters to that
/// package, so our own reminders never loop back into the conversation list).
///
/// One reminder per conversation, keyed by the conversation id. Scheduled
/// notifications survive reboots via the plugin's boot receiver (see
/// AndroidManifest.xml). Android-only, like the rest of the notification path.
class ReminderService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    // tz.local stays UTC (we never set it), which is fine: reminders are
    // scheduled at an absolute instant, and TZDateTime.from preserves that.
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        // The launcher-icon foreground (Threadly bubble on transparency):
        // status-bar icons render as tinted silhouettes, so this shows the
        // app's own glyph where a full-color mipmap would be a gray square.
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      onDidReceiveNotificationResponse: onReminderAction,
      onDidReceiveBackgroundNotificationResponse: onReminderAction,
    );
    _initialized = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Ask for the Android 13+ notification-posting permission if needed.
  /// Returns whether reminders are allowed to show.
  Future<bool> ensurePermission() async {
    await init();
    final android = _android;
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }

  /// Whether reminders fire at the exact minute: the user allowed "Alarms &
  /// reminders" (off by default on Android 14+). Without it Android may
  /// deliver a reminder up to an hour late.
  Future<bool> canScheduleExact() async {
    await init();
    return await _android?.canScheduleExactNotifications() ?? false;
  }

  /// Open the system "Alarms & reminders" page for Threadly.
  Future<void> requestExact() async {
    await init();
    await _android?.requestExactAlarmsPermission();
  }

  /// Schedule (or replace) the reminder for [conversationId]. Exact when the
  /// user has allowed "Alarms & reminders", otherwise inexact (may be delayed
  /// a few minutes by the system). A [when] in the past is ignored.
  Future<void> schedule(
    String conversationId, {
    required String title,
    String? body,
    required DateTime when,
  }) async {
    await init();
    if (!when.isAfter(DateTime.now())) return;
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      _notificationId(conversationId),
      title,
      body,
      tz.TZDateTime.from(when, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'reminders',
          'Reminders',
          channelDescription: 'Conversation reminders you set in Threadly',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          // Full-color Threadly icon shown on the notification itself (the
          // small icon above is the tinted status-bar silhouette).
          largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          // Snooze without opening Threadly (handled by onReminderAction).
          actions: [
            AndroidNotificationAction(_snoozeHour, 'Snooze 1 hour',
                cancelNotification: true),
            AndroidNotificationAction(_snoozeTomorrow, 'Tomorrow morning',
                cancelNotification: true),
          ],
        ),
      ),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: ReminderPayload(conversationId, title, body).encode(),
    );
  }

  /// Cancel any pending reminder for [conversationId].
  Future<void> cancel(String conversationId) async {
    await init();
    await _plugin.cancel(_notificationId(conversationId));
  }

  /// Stable 31-bit notification id derived from the conversation id, so a
  /// re-schedule replaces the previous reminder for the same conversation.
  /// FNV-1a rather than String.hashCode, which isn't guaranteed stable across
  /// runs — the id must match in a later session to cancel/replace.
  int _notificationId(String conversationId) {
    var h = 0x811c9dc5;
    for (final unit in conversationId.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}
