import 'package:flutter/material.dart';

import '../messaging.dart';
import '../models/category.dart';
import 'people_picker.dart';

/// Pick people, then hand off to the native Messages app to start the group
/// text. Threadly doesn't own the group — "creating a group" just opens the
/// native group composer (sms:n1,n2,…). The group then shows up in the list on
/// its own once it receives a message.
class NewGroupScreen extends StatefulWidget {
  final List<Person> people;
  const NewGroupScreen({super.key, required this.people});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final canStart = _selected.length >= 2;
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: widget.people.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No contacts found.\n\nSave the people in your phone’s '
                  'contacts to start a group text with them.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Pick at least two people. This opens Google Messages to '
                  'start the group text — nothing is sent from Threadly.',
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
            onPressed: canStart
                ? () async {
                    await launchGroupText(context, _selected.toList());
                    if (context.mounted) Navigator.of(context).pop();
                  }
                : null,
            icon: const Icon(Icons.open_in_new),
            label: Text(
              canStart
                  ? 'Start group text (${_selected.length})'
                  : 'Select 2+ people',
            ),
          ),
        ),
      ),
    );
  }
}
