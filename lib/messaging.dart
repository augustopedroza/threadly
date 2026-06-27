import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Conservative recipient count above which a group text is likely to fail or
/// split: group MMS is typically capped around this many. RCS groups can go
/// higher (~100), so this is a *warning* threshold, not a hard limit.
const int kGroupTextWarnLimit = 20;

/// Open the native Messages app composing to [recipients], optionally with a
/// draft [body]. With multiple recipients this starts a group text. Sending
/// happens in Messages so it lands in the user's real message history.
Future<bool> openSmsCompose(List<String> recipients, {String? body}) async {
  if (recipients.isEmpty) return false;
  final draft = body?.trim();
  final uri = Uri(
    scheme: 'sms',
    path: recipients.join(','),
    queryParameters:
        (draft != null && draft.isNotEmpty) ? {'body': draft} : null,
  );
  if (await canLaunchUrl(uri)) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  return false;
}

/// Launch a group text, warning first if the recipient count exceeds
/// [kGroupTextWarnLimit] (the user can still proceed — RCS may handle it).
Future<void> launchGroupText(
  BuildContext context,
  List<String> recipients, {
  String? body,
}) async {
  if (recipients.length > kGroupTextWarnLimit) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Large group'),
        content: Text(
          'This group has ${recipients.length} people. Group texts (MMS) are '
          'usually limited to about $kGroupTextWarnLimit recipients and may '
          'fail or split into separate threads unless everyone is on RCS.\n\n'
          'Send anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send anyway'),
          ),
        ],
      ),
    );
    if (proceed != true) return;
  }
  await openSmsCompose(recipients, body: body);
}
