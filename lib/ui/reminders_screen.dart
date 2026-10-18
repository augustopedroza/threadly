import 'package:flutter/material.dart';

import '../data/notifications.dart';
import '../format.dart';
import 'later_picker.dart';

/// One conversation's reminder, as the reminders screen shows it.
typedef ReminderEntry = ({
  Conversation conversation,
  String title,
  String? nickname,
  String? what,
  DateTime when,
});

/// Every reminder in one place: what's due (past, newest first) on top,
/// then upcoming (soonest first). Tap opens the conversation in Messages;
/// each row can be snoozed or cleared. The home screen owns the data — this
/// re-reads [entries] after every change it makes.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({
    super.key,
    required this.entries,
    required this.setReminder,
    required this.open,
  });

  final List<ReminderEntry> Function() entries;

  /// Move ([when]) or clear (null) a conversation's reminder.
  final Future<void> Function(Conversation c, DateTime? when) setReminder;
  final Future<void> Function(Conversation c) open;

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  Future<void> _snooze(ReminderEntry e) async {
    final when = await pickLater(context,
        title: 'Snooze until', current: e.when);
    if (when == null || !mounted) return;
    await widget.setReminder(e.conversation, when);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Snoozed until ${formatDue(when)}')),
    );
  }

  Future<void> _clear(ReminderEntry e) async {
    await widget.setReminder(e.conversation, null);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Reminder for ${e.title} cleared'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            // Only restore a time still ahead; a past one has fired.
            if (!e.when.isAfter(DateTime.now())) return;
            await widget.setReminder(e.conversation, e.when);
            if (mounted) setState(() {});
          },
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final all = widget.entries();
    final due = [for (final e in all) if (!e.when.isAfter(now)) e]
      ..sort((a, b) => b.when.compareTo(a.when));
    final upcoming = [for (final e in all) if (e.when.isAfter(now)) e]
      ..sort((a, b) => a.when.compareTo(b.when));
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: all.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No reminders.\n\nSwipe a conversation to the right to save '
                  'it for later, or set a reminder from its sheet.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                if (due.isNotEmpty) ...[
                  _header('Due'),
                  for (final e in due) _row(e, overdue: true),
                ],
                if (upcoming.isNotEmpty) ...[
                  _header('Upcoming'),
                  for (final e in upcoming) _row(e, overdue: false),
                ],
              ],
            ),
    );
  }

  Widget _header(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );

  Widget _row(ReminderEntry e, {required bool overdue}) {
    final theme = Theme.of(context);
    final color = overdue ? theme.colorScheme.error : theme.colorScheme.primary;
    final details = [?e.nickname, ?e.what].join(' · ');
    return Dismissible(
      key: ValueKey('reminder-${e.conversation.id}-${e.when.millisecondsSinceEpoch}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.secondaryContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.done, color: theme.colorScheme.onSecondaryContainer),
      ),
      onDismissed: (_) => _clear(e),
      child: ListTile(
        leading: Icon(overdue ? Icons.alarm_on : Icons.alarm, color: color),
        title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (details.isNotEmpty)
              Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(
              overdue ? 'Was due ${formatDue(e.when)}' : formatDue(e.when),
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Snooze',
              icon: const Icon(Icons.snooze),
              onPressed: () => _snooze(e),
            ),
            IconButton(
              tooltip: overdue ? 'Done' : 'Clear',
              icon: Icon(overdue ? Icons.done : Icons.close),
              onPressed: () => _clear(e),
            ),
          ],
        ),
        onTap: () => widget.open(e.conversation),
      ),
    );
  }
}
