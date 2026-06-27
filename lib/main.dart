import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/bridge_config.dart';
import 'data/contacts.dart';
import 'data/gmessages_source.dart';
import 'data/organizer_store.dart';
import 'data/sms_source.dart';
import 'format.dart';
import 'messaging.dart';
import 'models/category.dart';
import 'models/thread.dart';
import 'ui/group_chat_editor_screen.dart';
import 'ui/manage_categories_screen.dart';
import 'ui/organize_sheet.dart';

void main() => runApp(const ThreadlyApp());

class ThreadlyApp extends StatelessWidget {
  const ThreadlyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Threadly',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const ThreadListScreen(),
    );
  }
}

class ThreadListScreen extends StatefulWidget {
  const ThreadListScreen({super.key});

  @override
  State<ThreadListScreen> createState() => _ThreadListScreenState();
}

class _ThreadListScreenState extends State<ThreadListScreen> {
  final SmsSource _source = BridgeConfig.useBridge
      ? GMessagesBridgeSource(
          homeserver: BridgeConfig.homeserver,
          user: BridgeConfig.user,
          password: BridgeConfig.password,
        )
      : AndroidSmsSource();
  final OrganizerStore _store = OrganizerStore();
  final ContactsService _contactsService = ContactsService();

  bool _loading = true;
  String? _error;

  List<MessageThread> _threads = const [];
  List<Category> _categories = const [];
  Map<int, Set<String>> _memberships = const {};
  Map<int, List<GroupChat>> _groupChatsByCategory = const {};
  Map<String, ConversationAnnotation> _annotations = const {};
  Map<String, int> _reads = const {};
  ContactsSnapshot _contacts = ContactsSnapshot.empty;

  bool _searching = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _stopSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_source.needsSmsPermission) {
        final status = await Permission.sms.request();
        if (!status.isGranted) {
          setState(() {
            _loading = false;
            _error = 'SMS permission is required to read your group texts.';
          });
          return;
        }
      }
      final threads = await _source.loadThreads();
      final categories = await _store.categories();
      final memberships = await _store.allMemberships();
      final groupChatsByCategory = <int, List<GroupChat>>{};
      for (final c in categories) {
        groupChatsByCategory[c.id] = await _store.groupChats(c.id);
      }
      final annotations = await _store.allAnnotations();
      final reads = await _store.allReads();
      ContactsSnapshot contacts = ContactsSnapshot.empty;
      try {
        contacts = await _contactsService.load();
      } catch (_) {
        contacts = ContactsSnapshot.empty;
      }
      setState(() {
        _threads = threads;
        _categories = categories;
        _memberships = memberships;
        _groupChatsByCategory = groupChatsByCategory;
        _annotations = annotations;
        _reads = reads;
        _contacts = contacts;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load messages: $e';
      });
    }
  }

  /// Category ids whose members include any participant of [t].
  Set<int> _categoryIdsFor(MessageThread t) {
    final phones = t.participants.map(normalizePhone).toSet();
    return {
      for (final c in _categories)
        if ((_memberships[c.id] ?? const {}).any(phones.contains)) c.id,
    };
  }

  /// A conversation is unread when its newest message is *incoming* and arrived
  /// after the user last opened the thread (see [_markThreadRead]). Outgoing
  /// last messages are never unread — the user is the one who sent them.
  bool _isUnread(MessageThread t) {
    final latest = t.latest;
    if (latest == null || !latest.isIncoming) return false;
    final lastRead = _reads[t.participantKey];
    return lastRead == null ||
        latest.date.millisecondsSinceEpoch > lastRead;
  }

  /// Record that the user has seen [t] up to its newest message, so it stops
  /// showing as unread. No-op if already marked at or past that point.
  Future<void> _markThreadRead(MessageThread t) async {
    final latest = t.latest;
    if (latest == null) return;
    final ms = latest.date.millisecondsSinceEpoch;
    final prev = _reads[t.participantKey];
    if (prev != null && prev >= ms) return;
    await _store.markRead(t.participantKey, ms);
    if (mounted) setState(() => _reads = {..._reads, t.participantKey: ms});
  }

  List<MessageThread> _threadsForCategory(int categoryId) {
    final members = _memberships[categoryId] ?? const {};
    return _threads
        .where((t) => t.participants.map(normalizePhone).any(members.contains))
        .toList();
  }

  /// Distinct people (by normalized phone) seen across all threads. Displays the
  /// saved contact name where known, otherwise the raw number.
  List<Person> _people() {
    final seen = <String>{};
    final out = <Person>[];
    for (final t in _threads) {
      for (final raw in t.participants) {
        final phone = normalizePhone(raw);
        if (phone.isEmpty || !seen.add(phone)) continue;
        out.add((phone: phone, display: _contacts.nameForPhone(raw) ?? raw));
      }
    }
    out.sort((a, b) => a.display.compareTo(b.display));
    return out;
  }

  Future<void> _openManageCategories() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            ManageCategoriesScreen(store: _store, people: _people()),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    // Tabs: "All" plus one per category. Keyed so the controller rebuilds when
    // the category set changes.
    final tabs = ['All', ..._categories.map((c) => c.name)];
    final ready = !_loading && _error == null;
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
                      hintText: 'Search name, number, note, message…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : const Text('Chats'),
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
                    if (ready)
                      IconButton(
                        tooltip: 'Search',
                        icon: const Icon(Icons.search),
                        onPressed: () => setState(() => _searching = true),
                      ),
                    IconButton(
                      tooltip: 'Manage categories',
                      icon: const Icon(Icons.folder_outlined),
                      onPressed: _openManageCategories,
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh),
                      onPressed: _load,
                    ),
                  ],
            bottom: _searching || !ready
                ? null
                : TabBar(
                    isScrollable: true,
                    tabs: [for (final t in tabs) Tab(text: t)],
                  ),
          ),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sms_failed_outlined, size: 48),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (_searching) return _searchView();
    return TabBarView(
      children: [
        _allView(),
        for (final c in _categories) _categoryView(c),
      ],
    );
  }

  /// Flat, cross-tab results while searching: matching group chats first, then
  /// matching conversations. Matches name/number/nickname/note/message text.
  Widget _searchView() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Search by name, number, nickname, note, or message text.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final qDigits = _query.replaceAll(RegExp(r'\D'), '');
    final groupChats = [
      for (final c in _categories)
        for (final gc in _groupChatsByCategory[c.id] ?? const <GroupChat>[])
          if (_groupChatMatches(gc, c, q, qDigits)) (gc, c),
    ]..sort((a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()));
    final threads = [
      for (final t in _threads)
        if (_threadMatches(t, q, qDigits)) t,
    ];
    if (groupChats.isEmpty && threads.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No matches for “${_query.trim()}”.',
              textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      children: [
        if (groupChats.isNotEmpty) ...[
          _subheader('Group chats'),
          for (final (gc, category) in groupChats)
            _groupChatTile(gc, category, showCategory: true),
        ],
        if (threads.isNotEmpty) ...[
          if (groupChats.isNotEmpty) _subheader('Conversations'),
          for (final t in threads) _threadTile(t),
        ],
      ],
    );
  }

  bool _threadMatches(MessageThread t, String q, String qDigits) {
    final ann = _annotations[t.participantKey];
    final hay = StringBuffer()
      ..write(_contacts.titleFor(t))
      ..write(' ')
      ..write(t.participants.join(' '));
    if (ann?.name != null) hay.write(' ${ann!.name}');
    if (ann?.note != null) hay.write(' ${ann!.note}');
    final body = t.latest?.body;
    if (body != null) hay.write(' $body');
    if (hay.toString().toLowerCase().contains(q)) return true;
    if (qDigits.isNotEmpty &&
        t.participants.map(normalizePhone).join(' ').contains(qDigits)) {
      return true;
    }
    return false;
  }

  bool _groupChatMatches(GroupChat gc, Category cat, String q, String qDigits) {
    final names =
        gc.members.map((m) => _contacts.nameForPhone(m) ?? m).join(' ');
    final text = '${gc.name} ${cat.name} $names'.toLowerCase();
    if (text.contains(q)) return true;
    if (qDigits.isNotEmpty && gc.members.join(' ').contains(qDigits)) {
      return true;
    }
    return false;
  }

  /// The "All" tab: every saved group chat (across all categories) first, then
  /// all conversations (including group SMS threads).
  Widget _allView() {
    final groupChats = [
      for (final c in _categories)
        for (final gc in _groupChatsByCategory[c.id] ?? const <GroupChat>[])
          (gc, c),
    ]..sort((a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()));

    if (groupChats.isEmpty && _threads.isEmpty) {
      return const Center(child: Text('No conversations here.'));
    }
    return ListView(
      children: [
        if (groupChats.isNotEmpty) ...[
          _subheader('Group chats'),
          for (final (gc, category) in groupChats)
            _groupChatTile(gc, category, showCategory: true),
          if (_threads.isNotEmpty) _subheader('Conversations'),
        ],
        for (final t in _threads) _threadTile(t),
      ],
    );
  }

  /// A category tab: its saved group chats first, then its conversations.
  Widget _categoryView(Category category) {
    final chats = _groupChatsByCategory[category.id] ?? const [];
    final threads = _threadsForCategory(category.id);
    if (chats.isEmpty && threads.isEmpty) {
      return const Center(child: Text('No conversations here.'));
    }
    return ListView(
      children: [
        if (chats.isNotEmpty) ...[
          _subheader('Group chats'),
          for (final gc in chats) _groupChatTile(gc, category),
          if (threads.isNotEmpty) _subheader('Conversations'),
        ],
        for (final t in threads) _threadTile(t),
      ],
    );
  }

  Widget _subheader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelMedium),
      );

  /// A saved group-chat roster row; tap (or the icon) starts a group text.
  /// [showCategory] adds a category chip (used on the "All" tab, where the
  /// category isn't otherwise implied by the surrounding tab).
  Widget _groupChatTile(GroupChat gc, Category category,
      {bool showCategory = false}) {
    return ListTile(
      isThreeLine: showCategory,
      leading: CircleAvatar(
        backgroundColor: Color(category.color),
        child: const Icon(Icons.forum, color: Colors.white),
      ),
      title: Text(gc.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(pluralPeople(gc.members.length)),
          if (showCategory)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _MiniChip(label: category.name, color: Color(category.color)),
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: 'Start group text',
        onPressed:
            gc.members.isEmpty ? null : () => launchGroupText(context, gc.members),
      ),
      onTap: gc.members.isEmpty ? null : () => launchGroupText(context, gc.members),
      onLongPress: () => _groupChatActions(gc),
    );
  }

  /// Long-press a saved group chat to edit its roster or delete it — actions
  /// that otherwise live only under Manage categories.
  Future<void> _groupChatActions(GroupChat gc) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit group chat'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete group chat'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => GroupChatEditorScreen(
            store: _store,
            categoryId: gc.categoryId,
            existing: gc,
            people: _people(),
            preselect: const {},
          ),
        ),
      );
      if (changed == true) _load();
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete group chat?'),
          content: Text(
              '“${gc.name}” will be removed. Your texts are not affected.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (ok == true) {
        await _store.deleteGroupChat(gc.id);
        _load();
      }
    }
  }

  Widget _threadTile(MessageThread t) {
    final ann = _annotations[t.participantKey];
    final categoryChips = [
      for (final c in _categories)
        if (_categoryIdsFor(t).contains(c.id)) c,
    ];
    final hasName = ann?.name?.isNotEmpty == true;
    final hasNote = ann?.note?.isNotEmpty == true;
    final unread = _isUnread(t);
    // The snippet shows the note if set, else the latest message body. Skip the
    // line entirely when there's nothing to show (e.g. a media-only message with
    // no text) so the category chips sit directly under the contact name.
    final snippet = hasNote ? ann!.note! : (t.latest?.body ?? '');
    final subtitleLines = <Widget>[
      if (hasName)
        Text(
          ann!.name!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      if (snippet.isNotEmpty)
        Text(
          snippet,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontStyle: hasNote ? FontStyle.italic : null,
            fontWeight: unread ? FontWeight.bold : null,
            color: unread ? Theme.of(context).colorScheme.onSurface : null,
          ),
        ),
      if (categoryChips.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final c in categoryChips)
                _MiniChip(label: c.name, color: Color(c.color)),
            ],
          ),
        ),
    ];
    final latest = t.latest;
    final photo = _contacts.photoForThread(t);
    return ListTile(
      isThreeLine: hasName || categoryChips.isNotEmpty,
      leading: CircleAvatar(
        backgroundColor: ann?.color != null ? Color(ann!.color!) : null,
        backgroundImage: photo != null ? MemoryImage(photo) : null,
        child: photo != null
            ? null
            : Icon(
                t.isGroup ? Icons.groups : Icons.person,
                color: ann?.color != null ? Colors.white : null,
              ),
      ),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              _contacts.titleFor(t),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: unread
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          ),
          if (latest != null) ...[
            const SizedBox(width: 8),
            Text(
              formatListTime(latest.date),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: unread
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: unread ? FontWeight.bold : null,
                  ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitleLines,
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
      onTap: () => _openThread(t),
      onLongPress: () => _quickCategorize(t),
    );
  }

  /// Long-press a conversation for a fast category toggle, with an "Organize…"
  /// tile that opens the full editor (nickname/color/note). Membership writes
  /// apply immediately so it feels like flipping switches.
  Future<void> _quickCategorize(MessageThread t) async {
    // No categories yet — skip straight to the full editor, which can make one.
    if (_categories.isEmpty) return _organizeThread(t);

    final selected = {..._categoryIdsFor(t)};
    var changed = false;
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('Add to category',
                    style: Theme.of(ctx).textTheme.labelMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(_contacts.titleFor(t),
                    style: Theme.of(ctx).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in _categories)
                      CheckboxListTile(
                        dense: true,
                        secondary: CircleAvatar(
                            radius: 8, backgroundColor: Color(c.color)),
                        title: Text(c.name),
                        value: selected.contains(c.id),
                        onChanged: (v) async {
                          final add = v == true;
                          for (final phone in t.participants) {
                            await _store.setMembership(
                                c.id, normalizePhone(phone), add);
                          }
                          changed = true;
                          setSheet(() =>
                              add ? selected.add(c.id) : selected.remove(c.id));
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Organize…'),
                subtitle: const Text('Nickname, color, note'),
                onTap: () => Navigator.pop(ctx, 'organize'),
              ),
            ],
          ),
        ),
      ),
    );
    if (changed) await _load();
    if (result == 'organize' && mounted) await _organizeThread(t);
  }

  /// Open the organize editor straight from the list (long-press) so
  /// categorizing/nicknaming a thread doesn't require entering it first.
  Future<void> _organizeThread(MessageThread t) async {
    final changed = await showOrganizeSheet(
      context,
      thread: t,
      store: _store,
      categories: _categories,
      threadCategoryIds: _categoryIdsFor(t),
      annotation: _annotations[t.participantKey],
      contacts: _contacts,
    );
    if (changed) _load();
  }

  Future<void> _openThread(MessageThread t) async {
    await _markThreadRead(t);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ThreadScreen(
          thread: t,
          store: _store,
          categories: _categories,
          threadCategoryIds: _categoryIdsFor(t),
          annotation: _annotations[t.participantKey],
          contacts: _contacts,
          onChanged: _load,
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color? color;
  const _MiniChip({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? Colors.grey).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (color != null)
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

/// A single conversation: messages, the native-app handoff, and the Organize
/// editor (nickname/color/note, categories).
class ThreadScreen extends StatelessWidget {
  final MessageThread thread;
  final OrganizerStore store;
  final List<Category> categories;
  final Set<int> threadCategoryIds;
  final ConversationAnnotation? annotation;
  final ContactsSnapshot contacts;
  final VoidCallback onChanged;

  const ThreadScreen({
    super.key,
    required this.thread,
    required this.store,
    required this.categories,
    required this.threadCategoryIds,
    required this.annotation,
    required this.contacts,
    required this.onChanged,
  });

  Future<void> _organize(BuildContext context) async {
    final changed = await showOrganizeSheet(
      context,
      thread: thread,
      store: store,
      categories: categories,
      threadCategoryIds: threadCategoryIds,
      annotation: annotation,
      contacts: contacts,
    );
    if (changed) onChanged();
  }

  /// Hand off to the native Messages app. Resolves bridge `gm:` ghosts back to
  /// real phone numbers first; if it can't, it warns instead of opening Messages
  /// on a bogus thread.
  void _handoff(BuildContext context, {String? body}) {
    final recipients = contacts.sendRecipients(thread);
    if (recipients == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Couldn't find a phone number for this conversation. Save the "
              'contact in your phone, then refresh and try again.'),
        ),
      );
      return;
    }
    openSmsCompose(recipients, body: body);
  }

  @override
  Widget build(BuildContext context) {
    final color =
        annotation?.color != null ? Color(annotation!.color!) : null;
    final photo = contacts.photoForThread(thread);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: color != null ? Colors.white : null,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: color != null ? Colors.white24 : null,
              backgroundImage: photo != null ? MemoryImage(photo) : null,
              child: photo != null
                  ? null
                  : Icon(
                      thread.isGroup ? Icons.groups : Icons.person,
                      color: color != null ? Colors.white : null,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(contacts.titleFor(thread),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (annotation?.name?.isNotEmpty == true)
                    Text(
                      annotation!.name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: color != null
                                ? Colors.white70
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Organize',
            icon: const Icon(Icons.tune),
            onPressed: () => _organize(context),
          ),
          IconButton(
            tooltip: 'Open in Messages',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _handoff(context),
          ),
        ],
      ),
      body: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(12),
        itemCount: thread.messages.length,
        itemBuilder: (context, i) {
          final m = thread.messages[i];
          return Align(
            alignment:
                m.isIncoming ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: const BoxConstraints(maxWidth: 280),
              decoration: BoxDecoration(
                color: m.isIncoming
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (thread.isGroup && m.isIncoming && m.address.isNotEmpty)
                    Text(
                      contacts.nameForPhone(m.address) ?? m.address,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  Text(m.body),
                  const SizedBox(height: 2),
                  Text(
                    formatMessageTime(m.date),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Builder(
          builder: (context) => _MessagesComposeBar(
            onSend: (text) => _handoff(context, body: text),
          ),
        ),
      ),
    );
  }
}

/// A compose row that drafts a message and hands it to the native Messages app
/// (it does not send directly — see the README/CLAUDE notes on why replies must
/// go through the default SMS app to appear in the user's real history).
class _MessagesComposeBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  const _MessagesComposeBar({required this.onSend});

  @override
  State<_MessagesComposeBar> createState() => _MessagesComposeBarState();
}

class _MessagesComposeBarState extends State<_MessagesComposeBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: 'Message (opens in Messages to send)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _send,
            child: const Icon(Icons.open_in_new),
          ),
        ],
      ),
    );
  }
}
