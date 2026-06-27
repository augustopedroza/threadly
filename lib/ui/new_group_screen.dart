import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../messaging.dart';
import '../models/category.dart';
import 'people_picker.dart';

/// Pick people (plus an optional Threadly name + category), then hand off to the
/// native Messages app to start the group text. Threadly doesn't own the group —
/// "creating a group" just opens the native group composer (sms:n1,n2,…). The
/// name/category are remembered and applied to the conversation once it appears
/// in the list (Google Messages can't be told the name; see OrganizerStore
/// pending groups).
class NewGroupScreen extends StatefulWidget {
  final List<Person> people;
  final List<Category> categories;
  final OrganizerStore store;

  const NewGroupScreen({
    super.key,
    required this.people,
    required this.categories,
    required this.store,
  });

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final Set<String> _selected = {};
  final TextEditingController _name = TextEditingController();
  int? _categoryId;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final members = _selected.toList();
    await widget.store.createPendingGroup(
      name: _name.text,
      categoryId: _categoryId,
      members: members,
    );
    if (!mounted) return;
    await launchGroupText(context, members);
    if (mounted) Navigator.of(context).pop();
  }

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
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Group name (shown in Threadly)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  initialValue: _categoryId,
                  decoration: const InputDecoration(
                    labelText: 'Category (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final c in widget.categories)
                      DropdownMenuItem<int?>(
                        value: c.id,
                        child: Text(c.name),
                      ),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'Pick at least two people. This opens Google Messages to '
                  'start the group text — nothing is sent from Threadly. The '
                  'name and category apply once the group appears here.',
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
            onPressed: canStart ? _start : null,
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
