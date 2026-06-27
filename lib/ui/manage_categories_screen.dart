import 'package:flutter/material.dart';

import '../data/organizer_store.dart';
import '../messaging.dart';
import '../models/category.dart';
import 'edit_category_screen.dart';
import 'organize_sheet.dart';

/// Create, edit, and delete categories. Tapping a category opens the editor
/// (name, color, members); the + creates a new one.
class ManageCategoriesScreen extends StatefulWidget {
  final OrganizerStore store;
  final List<Person> people;
  const ManageCategoriesScreen({
    super.key,
    required this.store,
    required this.people,
  });

  @override
  State<ManageCategoriesScreen> createState() => _ManageCategoriesScreenState();
}

class _ManageCategoriesScreenState extends State<ManageCategoriesScreen> {
  List<Category> _categories = const [];
  Map<int, Set<String>> _memberships = const {};
  bool _loading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final categories = await widget.store.categories();
    final memberships = await widget.store.allMemberships();
    setState(() {
      _categories = categories;
      _memberships = memberships;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final result = await promptNewCategory(context);
    if (result == null) return;
    await widget.store.createCategory(result.$1, result.$2);
    _changed = true;
    await _load();
  }

  Future<void> _delete(Category c) async {
    await widget.store.deleteCategory(c.id);
    _changed = true;
    await _load();
  }

  Future<void> _edit(Category c) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditCategoryScreen(
          store: widget.store,
          category: c,
          people: widget.people,
          initialMembers: _memberships[c.id] ?? const {},
        ),
      ),
    );
    if (changed == true) {
      _changed = true;
      await _load();
    }
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
        floatingActionButton: FloatingActionButton(
          onPressed: _add,
          child: const Icon(Icons.add),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _categories.isEmpty
                ? const Center(
                    child: Text('No categories yet. Tap + to create one.'))
                : ListView(
                    children: [
                      for (final c in _categories)
                        ListTile(
                          leading: CircleAvatar(backgroundColor: Color(c.color)),
                          title: Text(c.name),
                          subtitle: Text(
                              pluralPeople(_memberships[c.id]?.length ?? 0)),
                          onTap: () => _edit(c),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.forum_outlined),
                                tooltip: 'Text everyone',
                                onPressed: (_memberships[c.id]?.isEmpty ?? true)
                                    ? null
                                    : () => launchGroupText(
                                        context, _memberships[c.id]!.toList()),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(c),
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
