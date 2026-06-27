import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../messaging.dart';
import '../models/category.dart';
import 'group_chat_editor_screen.dart';

/// Edit a category's name, color, and member list. Saves on "Save" and returns
/// true if anything changed.
class EditCategoryScreen extends StatefulWidget {
  final OrganizerStore store;
  final Category category;
  final List<Person> people;
  final Set<String> initialMembers; // normalized phones

  const EditCategoryScreen({
    super.key,
    required this.store,
    required this.category,
    required this.people,
    required this.initialMembers,
  });

  @override
  State<EditCategoryScreen> createState() => _EditCategoryScreenState();
}

class _EditCategoryScreenState extends State<EditCategoryScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.category.name);
  late int _color = widget.category.color;
  late final Set<String> _members = {...widget.initialMembers};
  bool _saving = false;
  List<GroupChat> _groupChats = const [];

  /// Whether anything changed here (category fields or its group chats) so the
  /// caller knows to reload even if the user backs out without tapping Save.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _loadGroupChats();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadGroupChats() async {
    final chats = await widget.store.groupChats(widget.category.id);
    if (mounted) setState(() => _groupChats = chats);
  }

  Future<void> _editGroupChat(GroupChat? existing) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GroupChatEditorScreen(
          store: widget.store,
          categoryId: widget.category.id,
          existing: existing,
          people: widget.people,
          preselect: _members,
        ),
      ),
    );
    if (changed == true) {
      _changed = true;
      await _loadGroupChats();
    }
  }

  Future<void> _deleteGroupChat(GroupChat gc) async {
    await widget.store.deleteGroupChat(gc.id);
    _changed = true;
    await _loadGroupChats();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    await widget.store.updateCategory(widget.category.id, name, _color);
    // Apply membership diffs.
    for (final person in widget.people) {
      final shouldBe = _members.contains(person.phone);
      final wasIn = widget.initialMembers.contains(person.phone);
      if (shouldBe != wasIn) {
        await widget.store
            .setMembership(widget.category.id, person.phone, shouldBe);
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit category'),
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
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Text('Color', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in kColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: _color == c
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Members', style: Theme.of(context).textTheme.labelLarge),
          if (widget.people.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No people found yet.'),
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

          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Group chats',
                  style: Theme.of(context).textTheme.labelLarge),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New group chat',
                onPressed: () => _editGroupChat(null),
              ),
            ],
          ),
          if (_groupChats.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('No group chats yet — tap + to create one.'),
            ),
          for (final gc in _groupChats)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.forum_outlined),
              title: Text(gc.name),
              subtitle: Text(pluralPeople(gc.members.length)),
              onTap: () => _editGroupChat(gc),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Start group text',
                    onPressed: gc.members.isEmpty
                        ? null
                        : () => launchGroupText(context, gc.members),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteGroupChat(gc),
                  ),
                ],
              ),
            ),
        ],
        ),
      ),
    );
  }
}
