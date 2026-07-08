import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../models/category.dart';
import 'people_picker.dart';

/// Manually attach the full member list to a group conversation.
///
/// Notifications never reveal a group's membership, so incoming groups can't
/// be deep-linked — tapping them only opens the Messages inbox. Once the user
/// hand-picks the complete roster here (2+ people, saved via
/// [OrganizerStore.setGroupRecipients]), tapping the group opens the exact
/// thread via the sms: deep link. Offered right after returning from the
/// inbox (see ConversationsScreen), while the group's members are fresh on
/// screen.
class AttachRosterScreen extends StatefulWidget {
  final String title;
  final String conversationId;
  final List<Person> people;
  final OrganizerStore store;

  const AttachRosterScreen({
    super.key,
    required this.title,
    required this.conversationId,
    required this.people,
    required this.store,
  });

  @override
  State<AttachRosterScreen> createState() => _AttachRosterScreenState();
}

class _AttachRosterScreenState extends State<AttachRosterScreen> {
  final Set<String> _selected = {};

  Future<void> _save() async {
    await widget.store
        .setGroupRecipients(widget.conversationId, _selected.toList());
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _selected.length >= 2;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? 'Group members' : widget.title),
      ),
      body: widget.people.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No contacts found.\n\nThreadly picks group members from '
                  'your phone’s contacts.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Pick everyone in this group (except you). The list must be '
                  'complete — a partial one would open the wrong conversation. '
                  'In Google Messages, the group’s details screen lists its '
                  'members.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                PeoplePicker(
                  people: widget.people,
                  selected: _selected,
                  onChanged: (phone, on) => setState(
                    () => on ? _selected.add(phone) : _selected.remove(phone),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: canSave ? _save : null,
            icon: const Icon(Icons.link),
            label: Text(
              canSave
                  ? 'Save members (${_selected.length})'
                  : 'Select 2+ people',
            ),
          ),
        ),
      ),
    );
  }
}
