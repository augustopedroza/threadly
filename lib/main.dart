import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/sms_source.dart';
import 'models/thread.dart';

void main() => runApp(const GroupChatApp());

class GroupChatApp extends StatelessWidget {
  const GroupChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Group Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ThreadListScreen(),
    );
  }
}

/// Phase 0 home: request SMS permission, then show grouped threads.
class ThreadListScreen extends StatefulWidget {
  const ThreadListScreen({super.key});

  @override
  State<ThreadListScreen> createState() => _ThreadListScreenState();
}

class _ThreadListScreenState extends State<ThreadListScreen> {
  final SmsSource _source = AndroidSmsSource();
  bool _loading = true;
  String? _error;
  List<MessageThread> _threads = const [];
  bool _groupsOnly = false;

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
      setState(() {
        _threads = threads;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load messages: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible =
        _groupsOnly ? _threads.where((t) => t.isGroup).toList() : _threads;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Group Chat'),
        actions: [
          IconButton(
            tooltip: _groupsOnly ? 'Show all' : 'Groups only',
            icon: Icon(_groupsOnly ? Icons.groups : Icons.groups_outlined),
            onPressed: () => setState(() => _groupsOnly = !_groupsOnly),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(visible),
    );
  }

  Widget _buildBody(List<MessageThread> visible) {
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
    if (visible.isEmpty) {
      return const Center(child: Text('No conversations found.'));
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = visible[i];
        final last = t.latest;
        return ListTile(
          leading: CircleAvatar(
            child: Icon(t.isGroup ? Icons.groups : Icons.person),
          ),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            last?.body ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: t.isGroup
              ? const Chip(
                  label: Text('Group'),
                  visualDensity: VisualDensity.compact,
                )
              : null,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ThreadScreen(thread: t, source: _source),
            ),
          ),
        );
      },
    );
  }
}

/// A single conversation, with the two core actions:
///  - Reply here  -> send via the data source (SmsManager on Android)
///  - Open in Messages -> deep-link out to the native app (works everywhere)
class ThreadScreen extends StatelessWidget {
  final MessageThread thread;
  final SmsSource source;

  const ThreadScreen({super.key, required this.thread, required this.source});

  Future<void> _openInMessages() async {
    final to = thread.participants.join(',');
    final uri = Uri.parse('sms:$to');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(thread.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open in Messages',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openInMessages,
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
                      m.address,
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
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openInMessages,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in Messages'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _showReplySheet(context),
                  icon: const Icon(Icons.reply),
                  label: const Text('Reply here'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReplySheet(BuildContext context) {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
            left: 12,
            right: 12,
            top: 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Message'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () async {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  final to = thread.participants.isNotEmpty
                      ? thread.participants.first
                      : '';
                  Navigator.of(sheetContext).pop();
                  try {
                    await source.sendSms(to: to, body: text);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Sent')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Send failed: $e')),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
