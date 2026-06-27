import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../models/category.dart';

/// Lightweight category management for the bridge-free home: add, rename,
/// recolor, and delete categories. (Membership is set per-conversation from the
/// organize sheet, so this screen is just the categories themselves.) Returns
/// true if anything changed.
class CategoryManagerScreen extends StatefulWidget {
  final OrganizerStore store;
  const CategoryManagerScreen({super.key, required this.store});

  @override
  State<CategoryManagerScreen> createState() => _CategoryManagerScreenState();
}

class _CategoryManagerScreenState extends State<CategoryManagerScreen> {
  List<Category> _categories = const [];
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cats = await widget.store.categories();
    if (mounted) setState(() => _categories = cats);
  }

  Future<void> _edit({Category? existing}) async {
    final result = await showDialog<({String name, int color})>(
      context: context,
      builder: (_) => _CategoryDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      await widget.store.createCategory(result.name, result.color);
    } else {
      await widget.store.updateCategory(existing.id, result.name, result.color);
    }
    _changed = true;
    await _load();
  }

  Future<void> _delete(Category c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${c.name}”?'),
        content: const Text(
          'The category and its membership are removed. Your conversations '
          'and texts are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.deleteCategory(c.id);
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Categories')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('New'),
        ),
        body: _categories.isEmpty
            ? const Center(child: Text('No categories yet — tap New.'))
            : ListView(
                children: [
                  for (final c in _categories)
                    ListTile(
                      leading: CircleAvatar(backgroundColor: Color(c.color)),
                      title: Text(c.name),
                      onTap: () => _edit(existing: c),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () => _delete(c),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Name + color editor for a category.
class _CategoryDialog extends StatefulWidget {
  final Category? existing;
  const _CategoryDialog({this.existing});

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late int _color = widget.existing?.color ?? kColorPalette.first;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New category' : 'Edit category'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Family, U17 Team',
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in kColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32,
                    height: 32,
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, (name: name, color: _color));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
