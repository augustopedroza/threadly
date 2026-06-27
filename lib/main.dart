import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'data/contact_labels.dart';
import 'data/organizer_store.dart';
import 'data/sms_source.dart';
import 'messaging.dart';
import 'models/category.dart';
import 'models/thread.dart';
import 'ui/manage_categories_screen.dart';
import 'ui/organize_sheet.dart';

void main() => runApp(const GroupChatApp());

class GroupChatApp extends StatelessWidget {
  const GroupChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChatOrganizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
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
  final SmsSource _source = AndroidSmsSource();
  final OrganizerStore _store = OrganizerStore();
  final ContactsLabelService _contactsService = ContactsLabelService();

  bool _loading = true;
  String? _error;

  List<MessageThread> _threads = const [];
  List<Category> _categories = const [];
  Map<int, Set<String>> _memberships = const {};
  Map<int, List<GroupChat>> _groupChatsByCategory = const {};
  Map<String, ConversationAnnotation> _annotations = const {};
  ContactsSnapshot _contacts = ContactsSnapshot.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        setState(() {
          _loading = false;
          _error = 'SMS permission is required to read your group texts.';
        });
        return;
      }
      final threads = await _source.loadThreads();
      final categories = await _store.categories();
      final memberships = await _store.allMemberships();
      final groupChatsByCategory = <int, List<GroupChat>>{};
      for (final c in categories) {
        groupChatsByCategory[c.id] = await _store.groupChats(c.id);
      }
      final annotations = await _store.allAnnotations();
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
    return DefaultTabController(
      key: ValueKey(_categories.map((c) => c.id).join(',')),
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chats'),
          actions: [
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
          bottom: _loading || _error != null
              ? null
              : TabBar(
                  isScrollable: true,
                  tabs: [for (final t in tabs) Tab(text: t)],
                ),
        ),
        body: _buildBody(),
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
    return TabBarView(
      children: [
        _allView(),
        for (final c in _categories) _categoryView(c),
      ],
    );
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
    );
  }

  Widget _threadTile(MessageThread t) {
    final ann = _annotations[t.participantKey];
    final categoryChips = [
      for (final c in _categories)
        if (_categoryIdsFor(t).contains(c.id)) c,
    ];
    final labelNames = _contacts.labelsForThread(t);
    final hasName = ann?.name?.isNotEmpty == true;
    final subtitleLines = <Widget>[
      if (hasName)
        Text(
          ann!.name!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      Text(
        ann?.note?.isNotEmpty == true ? ann!.note! : (t.latest?.body ?? ''),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ann?.note?.isNotEmpty == true
            ? const TextStyle(fontStyle: FontStyle.italic)
            : null,
      ),
      if (categoryChips.isNotEmpty || labelNames.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final c in categoryChips)
                _MiniChip(label: c.name, color: Color(c.color)),
              for (final l in labelNames) _MiniChip(label: l, outlined: true),
            ],
          ),
        ),
    ];
    return ListTile(
      isThreeLine:
          hasName || categoryChips.isNotEmpty || labelNames.isNotEmpty,
      leading: CircleAvatar(
        backgroundColor: ann?.color != null ? Color(ann!.color!) : null,
        child: Icon(
          t.isGroup ? Icons.groups : Icons.person,
          color: ann?.color != null ? Colors.white : null,
        ),
      ),
      title: Text(_contacts.titleFor(t),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitleLines,
      ),
      onTap: () => _openThread(t),
    );
  }

  Future<void> _openThread(MessageThread t) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ThreadScreen(
          thread: t,
          store: _store,
          contactsService: _contactsService,
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
  final bool outlined;
  const _MiniChip({required this.label, this.color, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: outlined ? null : (color ?? Colors.grey).withValues(alpha: 0.18),
        border: outlined
            ? Border.all(color: Theme.of(context).colorScheme.outline)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!outlined && color != null)
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
/// editor (color/note, categories, Contacts labels).
class ThreadScreen extends StatelessWidget {
  final MessageThread thread;
  final OrganizerStore store;
  final ContactsLabelService contactsService;
  final List<Category> categories;
  final Set<int> threadCategoryIds;
  final ConversationAnnotation? annotation;
  final ContactsSnapshot contacts;
  final VoidCallback onChanged;

  const ThreadScreen({
    super.key,
    required this.thread,
    required this.store,
    required this.contactsService,
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
      contactsService: contactsService,
      categories: categories,
      threadCategoryIds: threadCategoryIds,
      annotation: annotation,
      contacts: contacts,
    );
    if (changed) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        annotation?.color != null ? Color(annotation!.color!) : null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: color != null ? Colors.white : null,
        title: Column(
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
                          : Theme.of(context).colorScheme.onSurfaceVariant,
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
            onPressed: () => openSmsCompose(thread.participants),
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
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: _MessagesComposeBar(
          onSend: (text) => openSmsCompose(thread.participants, body: text),
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
