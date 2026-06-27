import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../messaging.dart';
import '../models/category.dart';

/// Create or edit a named group-chat roster under a category. Members can be
/// anyone the user has texted; saves immediately and returns true if changed.
class GroupChatEditorScreen extends StatefulWidget {
  final OrganizerStore store;
  final int categoryId;
  final GroupChat? existing;
  final List<Person> people;

  /// Members to pre-check when creating a new roster (the category's members).
  final Set<String> preselect;

  const GroupChatEditorScreen({
    super.key,
    required this.store,
    required this.categoryId,
    required this.existing,
    required this.people,
    required this.preselect,
  });

  @override
  State<GroupChatEditorScreen> createState() => _GroupChatEditorScreenState();
}

class _GroupChatEditorScreenState extends State<GroupChatEditorScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final Set<String> _members = {
    ...(widget.existing?.members ?? widget.preselect),
  };
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _members.isEmpty) return;
    setState(() => _saving = true);
    final phones = _members.toList();
    if (widget.existing == null) {
      await widget.store.createGroupChat(widget.categoryId, name, phones);
    } else {
      await widget.store.updateGroupChat(widget.existing!.id, name, phones);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New group chat' : 'Edit group chat'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. U17 Parents Carpool',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('People', style: Theme.of(context).textTheme.labelLarge),
              Text('${_members.length} selected',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          if (_members.length > kGroupTextWarnLimit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Over $kGroupTextWarnLimit people — a group text (MMS) '
                      'may fail or split unless everyone is on RCS.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.people.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No people found yet — text someone first.'),
            ),
          for (final person in widget.people)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(person.display),
              value: _members.contains(person.phone),
              onChanged: (v) => setState(() => v == true
                  ? _members.add(person.phone)
                  : _members.remove(person.phone)),
            ),
        ],
      ),
    );
  }
}
