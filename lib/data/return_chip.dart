import 'package:flutter/services.dart';

/// The optional "back to Threadly" chip: a small floating button Android draws
/// over Google Messages after a handoff, so one tap returns here (Back goes
/// through the Messages inbox instead). Needs the "Display over other apps"
/// permission, granted once in system settings. Wraps `ReturnChip.kt`.
class ReturnChipService {
  static const _ch = MethodChannel('threadly/return_chip');

  Future<ReturnChipStatus> status() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('status');
      return ReturnChipStatus(
        granted: m?['granted'] == true,
        enabled: m?['enabled'] == true,
        nudged: m?['nudged'] == true,
      );
    } on PlatformException {
      return const ReturnChipStatus(
        granted: false,
        enabled: false,
        nudged: true,
      );
    }
  }

  /// The user's on/off preference (independent of the permission).
  Future<void> setEnabled(bool on) async {
    try {
      await _ch.invokeMethod<void>('setEnabled', {'on': on});
    } on PlatformException {
      // best effort
    }
  }

  /// Record that the one-time "turn this on?" offer was shown.
  Future<void> markNudged() async {
    try {
      await _ch.invokeMethod<void>('markNudged');
    } on PlatformException {
      // best effort
    }
  }

  /// Open the system page where the overlay permission is granted.
  Future<void> openSettings() async {
    try {
      await _ch.invokeMethod<void>('openSettings');
    } on PlatformException {
      // best effort
    }
  }

  /// Whether the user just came back by tapping the chip (as opposed to Back
  /// or the launcher). Read-once: the flag clears.
  Future<bool> consumeTapped() async {
    try {
      return await _ch.invokeMethod<bool>('consumeTapped') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Draw the chip now (after a handoff). False when not granted or disabled.
  Future<bool> show() async {
    try {
      return await _ch.invokeMethod<bool>('show') ?? false;
    } on PlatformException {
      return false;
    }
  }
}

class ReturnChipStatus {
  const ReturnChipStatus({
    required this.granted,
    required this.enabled,
    required this.nudged,
  });

  final bool granted;
  final bool enabled;
  final bool nudged;

  /// Whether the chip will actually appear after a handoff.
  bool get active => granted && enabled;
}
