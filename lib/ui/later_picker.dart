import 'package:flutter/material.dart';

import '../format.dart';
import '../models/later.dart';

/// A bottom sheet of quick "later" times (in 1 hour, this evening, tomorrow
/// morning, this weekend, next week) plus "Pick date & time…". Returns the
/// chosen moment, always in the future, or null if dismissed. Used for
/// "save for later", snoozing, and setting a reminder.
Future<DateTime?> pickLater(
  BuildContext context, {
  String title = 'Remind me',
  DateTime? current,
}) async {
  final now = DateTime.now();
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            for (final o in laterPresets(now))
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(o.label),
                trailing: Text(
                  formatDue(o.when),
                  style: theme.textTheme.bodySmall,
                ),
                onTap: () => Navigator.pop(ctx, o.when),
              ),
            ListTile(
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('Pick date & time…'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),
          ],
        ),
      );
    },
  );
  if (choice is DateTime) return choice;
  if (choice != 'custom' || !context.mounted) return null;
  return _pickDateTime(context, current);
}

/// Date then time pickers; null if dismissed or the moment isn't ahead.
Future<DateTime?> _pickDateTime(BuildContext context, DateTime? current) async {
  final now = DateTime.now();
  final initial = (current != null && current.isAfter(now))
      ? current
      : now.add(const Duration(hours: 1));
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: DateTime(now.year + 5),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null || !context.mounted) return null;
  final when = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!when.isAfter(DateTime.now())) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pick a time in the future.')),
    );
    return null;
  }
  return when;
}
