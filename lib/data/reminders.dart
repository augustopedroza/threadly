import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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
        ),
      ),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: conversationId,
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
