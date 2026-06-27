import 'package:flutter/material.dart';

import '../data/contacts.dart';
import '../data/notifications.dart';
import '../data/organizer_store.dart';
import '../format.dart';
import '../messaging.dart';
import '../models/category.dart';
import 'category_manager_screen.dart';
import 'new_group_screen.dart';

/// Bridge-free home: a pure organizer + launcher over Google Messages.
///
/// Conversations come from the notification listener (no message content). The
/// app shows each with its contact avatar, a nickname/note/categories you set,
/// an unread dot, sorted by most recent activity. Tapping hands off to Google
/// Messages; organizing is app-owned (SQLite), keyed by the conversation id.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen>
    with WidgetsBindingObserver {
  final NotificationConversationsService _notifs =
      NotificationConversationsService();
  final OrganizerStore _store = OrganizerStore();
  final ContactsService _contactsService = ContactsService();

  bool _loading = true;
  bool _granted = false;

  List<Conversation> _conversations = const [];
  List<Category> _categories = const [];
  Map<int, Set<String>> _memberships = const {};
  Map<String, ConversationAnnotation> _annotations = const {};
  ContactsSnapshot _contacts = ContactsSnapshot.empty;
  List<({int id, String? name, int? categoryId, List<String> members})>
      _pendingGroups = const [];

  /// conversation id -> epoch-ms of the newest message marked read locally, so a
  /// tapped conversation clears its unread dot/bold immediately (without waiting
  /// for Google Messages to drop its notification).
  Map<String, int> _reads = const {};

  /// conversation id -> member numbers for groups we know (created here), so we
  /// can reopen the exact group thread via the sms: deep link.
  Map<String, List<String>> _groupRecipients = const {};

  bool _searching = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _stopSearch() => setState(() {
    _searching = false;
    _query = '';
    _searchController.clear();
  });

  /// Match a conversation by name, nickname, note, or category — never message
  /// content (there is none).
  bool _matches(Conversation c, String q) {
    final ann = _annotations[c.id];
    final hay = StringBuffer(c.title);
    if (ann?.name != null) hay.write(' ${ann!.name}');
    if (ann?.note != null) hay.write(' ${ann!.note}');
    for (final cat in _categories) {
      if (_categoryIdsFor(c).contains(cat.id)) hay.write(' ${cat.name}');
    }
    return hay.toString().toLowerCase().contains(q);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from Google Messages: re-pull so anything you just read there
    // (its notification removed) clears its unread dot.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final granted = await _notifs.permissionGranted();
    ContactsSnapshot contacts = ContactsSnapshot.empty;
    try {
      contacts = await _contactsService.load();
    } catch (_) {
      contacts = ContactsSnapshot.empty;
    }
    final conversations = granted
        ? await _notifs.conversations()
        : const <Conversation>[];
    final categories = await _store.categories();
    // Apply any pending group names/categories to groups that have now appeared
    // (which also removes the placeholder for that group).
    if (granted && conversations.isNotEmpty) {
      await _applyPendingGroups(conversations, contacts);
    }
    final pendingGroups = await _store.pendingGroups();
    final memberships = await _store.allMemberships();
    final annotations = await _store.allAnnotations();
    final reads = await _store.allReads();
    final groupRecipients = await _store.allGroupRecipients();
    // Learn group member numbers we don't yet have, so even purely-incoming
    // groups can be reopened via the sms: link. Prefer numbers the notification
    // carried directly (tel:), else resolve its sender names via contacts.
    for (final c in conversations) {
      if (!c.isGroup) continue;
      if (groupRecipients[c.id] != null && groupRecipients[c.id]!.isNotEmpty) {
        continue;
      }
      var nums = c.members;
      if (nums.isEmpty) {
        nums = [
          for (final s in c.senders)
            if (contacts.phoneForName(s) != null) contacts.phoneForName(s)!,
        ];
      }
      if (nums.isNotEmpty) {
        await _store.setGroupRecipients(c.id, nums);
        groupRecipients[c.id] = nums;
      }
    }
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _contacts = contacts;
      _conversations = conversations;
      _categories = categories;
      _pendingGroups = pendingGroups;
      _memberships = memberships;
      _annotations = annotations;
      _reads = reads;
      _groupRecipients = groupRecipients;
      _loading = false;
    });
  }

  /// Match pending group names/categories (set in the new-group composer) to
  /// group conversations that have now appeared, by checking that every member's
  /// contact name shows up in the conversation title. Applies then clears them.
  Future<void> _applyPendingGroups(
      List<Conversation> convos, ContactsSnapshot contacts) async {
    final pendings = await _store.pendingGroups();
    for (final pg in pendings) {
      final memberNames = [
        for (final m in pg.members) contacts.nameForPhone(m) ?? m,
      ];
      if (memberNames.isEmpty) continue;
      Conversation? match;
      for (final c in convos) {
        if (!c.isGroup) continue;
        final t = c.title.toLowerCase();
        final allPresent = memberNames.every((n) {
          final first = n.toLowerCase().trim().split(' ').first;
          return first.isNotEmpty && t.contains(first);
        });
        if (allPresent) {
          match = c;
          break;
        }
      }
      if (match == null) continue;
      if (pg.name != null && pg.name!.isNotEmpty) {
        await _store.setAnnotation(match.id, name: pg.name);
      }
      if (pg.categoryId != null) {
        await _store.setMembership(pg.categoryId!, match.id, true);
      }
      // Remember the members so the group can be reopened by sms: later.
      await _store.setGroupRecipients(match.id, pg.members);
      await _store.deletePendingGroup(pg.id);
    }
  }

  Set<int> _categoryIdsFor(Conversation c) => {
    for (final cat in _categories)
      if ((_memberships[cat.id] ?? const {}).contains(c.id)) cat.id,
  };

  List<Conversation> _forCategory(int categoryId) {
    final members = _memberships[categoryId] ?? const {};
    return _conversations.where((c) => members.contains(c.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ['All', ..._categories.map((c) => c.name)];
    return DefaultTabController(
      key: ValueKey(_categories.map((c) => c.id).join(',')),
      length: tabs.length,
      child: PopScope(
        canPop: !_searching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _stopSearch();
        },
        child: Scaffold(
          appBar: AppBar(
            leading: _searching
                ? IconButton(
                    tooltip: 'Close search',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _stopSearch,
                  )
                : null,
            title: _searching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search name, nickname, note, category…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : const Text('Chats'),
            bottom: (_searching || !_granted || _loading)
                ? null
                : TabBar(
                    isScrollable: true,
                    tabs: [for (final t in tabs) Tab(text: t)],
                  ),
            actions: _searching
                ? [
                    if (_query.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                  ]
                : [
                    if (_granted && _conversations.isNotEmpty)
                      IconButton(
                        tooltip: 'Search',
                        icon: const Icon(Icons.search),
                        onPressed: () => setState(() => _searching = true),
                      ),
                    IconButton(
                      tooltip: 'New group',
                      icon: const Icon(Icons.group_add_outlined),
                      onPressed: _newGroup,
                    ),
                    IconButton(
                      tooltip: 'Categories',
                      icon: const Icon(Icons.folder_outlined),
                      onPressed: _manageCategories,
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh),
                      onPressed: _load,
                    ),
                  ],
          ),
          body: _searching ? _searchView() : _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_granted) return _onboarding();
    if (_conversations.isEmpty && _pendingGroups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No conversations yet.\n\nThey appear here as new messages arrive '
            'in Google Messages.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return TabBarView(
      children: [
        _tab(_conversations, null),
        for (final c in _categories) _tab(_forCategory(c.id), c.id),
      ],
    );
  }

  /// A tab: groups you started (placeholders) first, then conversations. When
  /// [categoryId] is non-null, only that category's pending groups show.
  Widget _tab(List<Conversation> convos, int? categoryId) {
    final pending = categoryId == null
        ? _pendingGroups
        : [for (final p in _pendingGroups) if (p.categoryId == categoryId) p];
    if (pending.isEmpty && convos.isEmpty) {
      return const Center(child: Text('No conversations here.'));
    }
    return ListView(
      children: [
        for (final pg in pending) _pendingTile(pg),
        for (final c in convos) _tile(c),
      ],
    );
  }

  Widget _searchView() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Search by name, nickname, note, or category.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final results = [
      for (final c in _conversations)
        if (_matches(c, q)) c,
    ];
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No matches for “${_query.trim()}”.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return _list(results);
  }

  Widget _list(List<Conversation> items) {
    if (items.isEmpty) {
      return const Center(child: Text('No conversations here.'));
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) => _tile(items[i]),
    );
  }

  Widget _onboarding() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_active_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Let Threadly see new messages',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'To know when a conversation has a new message, Threadly needs '
              '“notification access” to read Google Messages’ notifications. '
              'It only reads them as a signal — it never shows notifications of '
              'its own, and never reads message content.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await _notifs.openSettings();
              },
              icon: const Icon(Icons.settings),
              label: const Text('Grant notification access'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _load,
              child: const Text('I’ve enabled it — refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Conversation c) {
    final ann = _annotations[c.id];
    final photo = c.isGroup ? null : _contacts.photoForTitle(c.title);
    final unread = _isUnread(c);
    final hasName = ann?.name?.isNotEmpty == true;
    final hasNote = ann?.note?.isNotEmpty == true;
    final chips = [
      for (final cat in _categories)
        if (_categoryIdsFor(c).contains(cat.id)) cat,
    ];
    final subtitle = <Widget>[
      if (hasName)
        Text(
          ann!.name!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      if (hasNote)
        Text(
          ann!.note!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      if (chips.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final cat in chips)
                _MiniChip(label: cat.name, color: Color(cat.color)),
            ],
          ),
        ),
    ];
    return Dismissible(
      key: ValueKey('conv-${c.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) => _confirmForget(c),
      onDismissed: (_) => _forget(c),
      child: ListTile(
        isThreeLine: subtitle.length > 1,
        leading: CircleAvatar(
        backgroundColor: ann?.color != null ? Color(ann!.color!) : null,
        backgroundImage: photo != null ? MemoryImage(photo) : null,
        child: photo != null
            ? null
            : Icon(
                c.isGroup ? Icons.groups : Icons.person,
                color: ann?.color != null ? Colors.white : null,
              ),
      ),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              c.title.isEmpty ? 'Unknown' : c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: unread
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatListTime(c.lastActivity),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: unread
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: unread ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: subtitle,
            ),
      trailing: unread
          ? Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            )
          : null,
        onTap: () => _open(c),
        onLongPress: () => _organize(c),
      ),
    );
  }

  /// Open the conversation in Google Messages. For a 1:1 with a resolvable
  /// number, the sms: deep link reliably lands on that exact thread (and doesn't
  /// depend on a live notification). Otherwise fall back to the notification's
  /// contentIntent / launching Messages. Warns if nothing could be opened.
  /// Unread when Google Messages still has a live notification *and* the user
  /// hasn't locally marked it read up to its latest activity (see [_markRead]).
  bool _isUnread(Conversation c) {
    if (!c.unread) return false;
    final lastRead = _reads[c.id];
    return lastRead == null ||
        c.lastActivity.millisecondsSinceEpoch > lastRead;
  }

  /// Mark [c] read locally up to its newest message so its dot/bold clear at
  /// once. Re-marks as unread only when a newer message later arrives.
  Future<void> _markRead(Conversation c) async {
    final ms = c.lastActivity.millisecondsSinceEpoch;
    final prev = _reads[c.id];
    if (prev != null && prev >= ms) return;
    await _store.markRead(c.id, ms);
    if (mounted) setState(() => _reads = {..._reads, c.id: ms});
  }

  Future<bool> _confirmForget(Conversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from list?'),
        content: Text(
            '“${c.title.isEmpty ? 'This conversation' : c.title}” will be '
            'removed from Threadly. Your texts aren’t affected, and it comes '
            'back if a new message arrives.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Drop a conversation from Threadly: forget it natively and clear its local
  /// organizing (annotation + category membership).
  Future<void> _forget(Conversation c) async {
    setState(() =>
        _conversations = [for (final x in _conversations) if (x.id != c.id) x]);
    await _notifs.forget(c.id);
    await _store.setAnnotation(c.id); // all-null clears the row
    for (final cat in _categories) {
      await _store.setMembership(cat.id, c.id, false);
    }
    if (mounted) _load();
  }

  Future<void> _open(Conversation c) async {
    await _markRead(c);
    // 1) Deep-link by number(s) — the reliable path: the contact's number for a
    //    1:1, or the saved/harvested member numbers for a group. (The
    //    notification contentIntent is a trampoline that Android 12+ blocks for
    //    other apps, so it can't be trusted as the primary route.)
    List<String>? recipients;
    if (c.isGroup) {
      recipients = _groupRecipients[c.id];
    } else {
      final number =
          _contacts.phoneForName(c.title) ?? _numberFromTitle(c.title);
      recipients = number != null ? [number] : null;
    }
    if (recipients != null &&
        recipients.isNotEmpty &&
        await openSmsCompose(recipients)) {
      return;
    }
    // 2) No number known (e.g. an incoming group we couldn't harvest numbers
    //    for): open Google Messages. We deliberately don't use the notification
    //    contentIntent — it's a trampoline Android 12+ blocks for other apps, so
    //    it silently does nothing and would swallow the tap.
    if (await _notifs.openMessagesApp()) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't open this conversation in Messages."),
        ),
      );
    }
  }

  /// If a conversation title is itself a phone number (unsaved contact), return
  /// it for the sms: handoff; otherwise null.
  String? _numberFromTitle(String title) {
    final digits = title.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 7 ? title : null;
  }

  /// A group the user started that hasn't received a message yet (so it has no
  /// real conversation). Shown as a launchable placeholder until it appears.
  Widget _pendingTile(
      ({int id, String? name, int? categoryId, List<String> members}) pg) {
    final title = (pg.name != null && pg.name!.isNotEmpty)
        ? pg.name!
        : pg.members.map((m) => _contacts.nameForPhone(m) ?? m).join(', ');
    Category? cat;
    for (final c in _categories) {
      if (c.id == pg.categoryId) {
        cat = c;
        break;
      }
    }
    final canLaunch = pg.members.isNotEmpty;
    return ListTile(
      isThreeLine: cat != null,
      leading: CircleAvatar(
        backgroundColor: cat != null ? Color(cat.color) : null,
        child: Icon(Icons.groups, color: cat != null ? Colors.white : null),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(title.isEmpty ? 'New group' : title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('NEW',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer)),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Group you started · ${pluralPeople(pg.members.length)}'),
          if (cat != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _MiniChip(label: cat.name, color: Color(cat.color)),
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: 'Start group text',
        onPressed: canLaunch ? () => launchGroupText(context, pg.members) : null,
      ),
      onTap: canLaunch ? () => launchGroupText(context, pg.members) : null,
      onLongPress: () => _pendingActions(pg),
    );
  }

  Future<void> _pendingActions(
      ({int id, String? name, int? categoryId, List<String> members}) pg) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Start group text'),
              onTap: () => Navigator.pop(ctx, 'start'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit name & category'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from list'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'start' && pg.members.isNotEmpty) {
      await launchGroupText(context, pg.members);
    } else if (action == 'edit') {
      final result = await showDialog<({String? name, int? categoryId})>(
        context: context,
        builder: (_) => _GroupDetailsDialog(
          categories: _categories,
          initialName: pg.name,
          initialCategoryId: pg.categoryId,
        ),
      );
      if (result == null) return;
      await _store.updatePendingGroup(pg.id,
          name: result.name, categoryId: result.categoryId);
      _load();
    } else if (action == 'remove') {
      await _store.deletePendingGroup(pg.id);
      _load();
    }
  }

  Future<void> _newGroup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewGroupScreen(
          people: _contacts.people,
          categories: _categories,
          store: _store,
        ),
      ),
    );
    // The group won't appear until it gets a message, but reload so a pending
    // entry is in place and the contacts list is fresh.
    if (mounted) _load();
  }

  Future<void> _manageCategories() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CategoryManagerScreen(store: _store)),
    );
    if (changed == true) _load();
  }

  Future<void> _organize(Conversation c) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _OrganizeSheet(
        store: _store,
        conversation: c,
        categories: _categories,
        selectedCategoryIds: _categoryIdsFor(c),
        annotation: _annotations[c.id],
      ),
    );
    // Toggles/notes persist live; reload to reflect them (also covers dismiss
    // without an explicit Save).
    if (mounted) _load();
  }
}

/// Small category pill shown under a conversation.
class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: CircleAvatar(radius: 4, backgroundColor: color),
          ),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// Per-conversation organize editor: nickname, note, color, and category
/// toggles. Writes to [OrganizerStore] keyed by the conversation id.
class _OrganizeSheet extends StatefulWidget {
  final OrganizerStore store;
  final Conversation conversation;
  final List<Category> categories;
  final Set<int> selectedCategoryIds;
  final ConversationAnnotation? annotation;

  const _OrganizeSheet({
    required this.store,
    required this.conversation,
    required this.categories,
    required this.selectedCategoryIds,
    required this.annotation,
  });

  @override
  State<_OrganizeSheet> createState() => _OrganizeSheetState();
}

class _OrganizeSheetState extends State<_OrganizeSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.annotation?.name ?? '',
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.annotation?.note ?? '',
  );
  late int? _color = widget.annotation?.color;
  late List<Category> _categories = widget.categories;
  late final Set<int> _selected = {...widget.selectedCategoryIds};

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _toggleCategory(Category c, bool on) async {
    await widget.store.setMembership(c.id, widget.conversation.id, on);
    setState(() => on ? _selected.add(c.id) : _selected.remove(c.id));
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Family, U17 Team'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final cat = await widget.store.createCategory(name, kColorPalette.first);
    await _toggleCategory(cat, true);
    final cats = await widget.store.categories();
    if (mounted) setState(() => _categories = cats);
  }

  Future<void> _save() async {
    await widget.store.setAnnotation(
      widget.conversation.id,
      name: _name.text,
      color: _color,
      note: _note.text,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.conversation.title,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nickname (shown as a subtitle)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Note',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            Text('Color', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _colorDot(null),
                for (final c in kColorPalette) _colorDot(c),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Categories',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addCategory,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
                ),
              ],
            ),
            for (final c in _categories)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                secondary: CircleAvatar(
                  radius: 8,
                  backgroundColor: Color(c.color),
                ),
                title: Text(c.name),
                value: _selected.contains(c.id),
                onChanged: (v) => _toggleCategory(c, v == true),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorDot(int? value) {
    final selected = _color == value;
    return GestureDetector(
      onTap: () => setState(() => _color = value),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: value != null ? Color(value) : null,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: value == null
            ? const Icon(Icons.not_interested, size: 16)
            : null,
      ),
    );
  }
}

/// Edit a (pending) group's Threadly name and category.
class _GroupDetailsDialog extends StatefulWidget {
  final List<Category> categories;
  final String? initialName;
  final int? initialCategoryId;

  const _GroupDetailsDialog({
    required this.categories,
    this.initialName,
    this.initialCategoryId,
  });

  @override
  State<_GroupDetailsDialog> createState() => _GroupDetailsDialogState();
}

class _GroupDetailsDialogState extends State<_GroupDetailsDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName ?? '');
  late int? _categoryId =
      widget.categories.any((c) => c.id == widget.initialCategoryId)
          ? widget.initialCategoryId
          : null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit group'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Group name (shown in Threadly)',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int?>(
            initialValue: _categoryId,
            decoration: const InputDecoration(
              labelText: 'Category',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('None')),
              for (final c in widget.categories)
                DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
              context, (name: _name.text, categoryId: _categoryId)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
