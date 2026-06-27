import 'package:flutter/material.dart';

import '../data/contact_labels.dart';
import '../data/organizer_store.dart';
import '../models/category.dart';
import '../models/thread.dart';

/// Per-conversation organizing editor: color + note, category membership, and
/// Contacts-label membership — all in one sheet. Performs the writes on save
/// and returns true if anything changed (so the caller can reload).
Future<bool> showOrganizeSheet(
  BuildContext context, {
  required MessageThread thread,
  required OrganizerStore store,
  required ContactsLabelService contactsService,
  required List<Category> categories,
  required Set<int> threadCategoryIds,
  required ConversationAnnotation? annotation,
  required ContactsSnapshot contacts,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _OrganizeSheet(
      thread: thread,
      store: store,
      contactsService: contactsService,
      categories: categories,
      threadCategoryIds: threadCategoryIds,
      annotation: annotation,
      contacts: contacts,
    ),
  );
  return changed ?? false;
}

class _OrganizeSheet extends StatefulWidget {
  final MessageThread thread;
  final OrganizerStore store;
  final ContactsLabelService contactsService;
  final List<Category> categories;
  final Set<int> threadCategoryIds;
  final ConversationAnnotation? annotation;
  final ContactsSnapshot contacts;

  const _OrganizeSheet({
    required this.thread,
    required this.store,
    required this.contactsService,
    required this.categories,
    required this.threadCategoryIds,
    required this.annotation,
    required this.contacts,
  });

  @override
  State<_OrganizeSheet> createState() => _OrganizeSheetState();
}

class _OrganizeSheetState extends State<_OrganizeSheet> {
  late int? _color = widget.annotation?.color;
  late final TextEditingController _name =
      TextEditingController(text: widget.annotation?.name ?? '');
  late final TextEditingController _note =
      TextEditingController(text: widget.annotation?.note ?? '');

  late List<Category> _categories = [...widget.categories];
  late final Set<int> _selectedCategories = {...widget.threadCategoryIds};

  late List<ContactLabel> _labels = [...widget.contacts.labels];
  late final Set<String> _selectedLabels = {
    for (final l in widget.contacts.labels)
      if (widget.contacts
          .labelsForThread(widget.thread)
          .map((n) => n.toLowerCase())
          .contains(l.name.toLowerCase()))
        l.id,
  };

  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contacts.titleFor(widget.thread),
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),

            // --- Name ---
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Maria - Insurance',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // --- Color ---
            Text('Color', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _ColorDot(
                  color: null,
                  selected: _color == null,
                  onTap: () => setState(() => _color = null),
                ),
                for (final c in kLabelPalette)
                  _ColorDot(
                    color: Color(c),
                    selected: _color == c,
                    onTap: () => setState(() => _color = c),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // --- Note ---
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Note',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            // --- Categories ---
            _sectionHeader('Categories', onAdd: _newCategory),
            for (final c in _categories)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(c.name),
                secondary: CircleAvatar(
                    radius: 8, backgroundColor: Color(c.color)),
                value: _selectedCategories.contains(c.id),
                onChanged: (v) => setState(() => v == true
                    ? _selectedCategories.add(c.id)
                    : _selectedCategories.remove(c.id)),
              ),
            if (_categories.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('No categories yet — tap + to add one.'),
              ),
            const SizedBox(height: 8),

            // --- Contacts labels ---
            _sectionHeader('Labels (Contacts)',
                onAdd: widget.contacts.available ? _newLabel : null),
            if (!widget.contacts.available)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('Contacts not available on this device.'),
              )
            else ...[
              for (final l in _labels)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(l.name),
                  value: _selectedLabels.contains(l.id),
                  onChanged: (v) => setState(() => v == true
                      ? _selectedLabels.add(l.id)
                      : _selectedLabels.remove(l.id)),
                ),
              if (_labels.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('No labels yet — tap + to add one.'),
                ),
            ],
            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onAdd}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        if (onAdd != null)
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New',
            onPressed: onAdd,
          ),
      ],
    );
  }

  Future<void> _newCategory() async {
    final result = await promptNewCategory(context);
    if (result == null) return;
    final c = await widget.store.createCategory(result.$1, result.$2);
    setState(() {
      // createCategory is idempotent by name, so it may return an existing one.
      if (!_categories.any((x) => x.id == c.id)) {
        _categories = [..._categories, c]
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }
      _selectedCategories.add(c.id);
    });
  }

  Future<void> _newLabel() async {
    final name = await _promptText(context, 'New label', 'Label name');
    if (name == null || name.trim().isEmpty) return;
    final id = await widget.contactsService.createLabel(name);
    if (id == null) return;
    setState(() {
      _labels = [..._labels, ContactLabel(id: id, name: name.trim())];
      _selectedLabels.add(id);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // Name + color + note.
    await widget.store.setAnnotation(
      widget.thread.participantKey,
      name: _name.text,
      color: _color,
      note: _note.text,
    );
    // Categories: apply membership for every participant.
    for (final c in _categories) {
      final shouldBe = _selectedCategories.contains(c.id);
      final wasIn = widget.threadCategoryIds.contains(c.id);
      if (shouldBe == wasIn) continue;
      for (final phone in widget.thread.participants) {
        await widget.store
            .setMembership(c.id, normalizePhone(phone), shouldBe);
      }
    }
    // Contacts labels.
    if (widget.contacts.available) {
      final initial = {
        for (final l in widget.contacts.labels)
          if (widget.contacts
              .labelsForThread(widget.thread)
              .map((n) => n.toLowerCase())
              .contains(l.name.toLowerCase()))
            l.id,
      };
      for (final l in _labels) {
        final shouldBe = _selectedLabels.contains(l.id);
        if (shouldBe == initial.contains(l.id)) continue;
        await widget.contactsService.setLabelForThread(
          label: l,
          thread: widget.thread,
          snapshot: widget.contacts,
          member: shouldBe,
        );
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }
}

class _ColorDot extends StatelessWidget {
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorDot(
      {required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: color == null
            ? const Icon(Icons.block, size: 18)
            : (selected ? const Icon(Icons.check, color: Colors.white, size: 18) : null),
      ),
    );
  }
}

/// Dialog returning (name, colorValue) for a new category.
Future<(String, int)?> promptNewCategory(BuildContext context) async {
  final controller = TextEditingController();
  int color = kLabelPalette.first;
  return showDialog<(String, int)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('New category'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'e.g. LDS'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                for (final c in kLabelPalette)
                  _ColorDot(
                    color: Color(c),
                    selected: color == c,
                    onTap: () => setState(() => color = c),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context, (name, color));
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> _promptText(
    BuildContext context, String title, String hint) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Create'),
        ),
      ],
    ),
  );
}
