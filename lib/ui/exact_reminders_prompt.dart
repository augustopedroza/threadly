import 'package:flutter/material.dart';

import '../data/reminders.dart';

bool _askedThisRun = false;

/// After saving a reminder: if Threadly can't schedule exact alarms, offer
/// (once per app run) to open "Alarms & reminders" so reminders arrive at
/// the minute set rather than within Android's hour-wide window. Returning
/// from Settings re-schedules upcoming reminders (the home screen notices
/// the change), so the one just saved becomes exact too.
Future<void> offerExactReminders(
  BuildContext context,
  ReminderService reminders,
) async {
  if (_askedThisRun || await reminders.canScheduleExact()) return;
  _askedThisRun = true;
  if (!context.mounted) return;
  final allow = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.alarm),
      title: const Text('Get reminders on time?'),
      content: const Text(
        'Android may deliver Threadly’s reminders up to an hour late. Allow '
        '“Alarms & reminders” for Threadly so they arrive at the exact time '
        'you set.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  if (allow == true) await reminders.requestExact();
}
