import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/contacts.dart';
import '../data/notifications.dart';
import '../data/organizer_store.dart';
import '../data/reminders.dart';
import '../data/return_chip.dart';
import '../data/suggestions.dart';
import '../format.dart';
import '../messaging.dart';
import '../models/category.dart';
import '../models/command.dart';
import '../models/due_date.dart';
import '../models/reply.dart';
import 'category_manager_screen.dart';
import 'later_picker.dart';
import 'new_group_screen.dart';
import 'reminders_screen.dart';
import 'undo_snack_bar.dart';

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
  final ReminderService _reminders = ReminderService();
  final ReturnChipService _chip = ReturnChipService();
  final SuggestionService _suggest = SuggestionService();

  /// Whether the "back to Threadly" chip is set up (permission + preference).
  ReturnChipStatus? _chipStatus;

  /// The conversation last handed off to Messages, until the user returns:
  /// its row blinks on the way back (chip or Back), and that's the moment to
  /// offer the return chip once (if it isn't set up yet).
  Conversation? _lastHandoff;
  DateTime? _lastHandoffAt;

  /// How long a handoff still counts as "where you came from" — the chip's
  /// own lifetime, so coming back much later doesn't blink an old row.
  static const _returnWindow = Duration(minutes: 20);

  /// The row currently blinking (see [_blink]) and a counter that restarts
  /// the pulse when the same row blinks again.
  String? _blinkId;
  int _blinkSeq = 0;

  bool _loading = true;
  bool _loadedOnce = false;
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

  /// conversation id -> "To reply" bookkeeping (done marks, AI verdicts).
  Map<String, ReplyState> _replyStates = const {};

  /// Whether the AI is working through "To reply" candidates (one pass at a
  /// time; it only runs while Threadly is on screen).
  bool _judging = false;

  /// The hard-to-map conversation we just handed off to Google Messages: a
  /// 1:1 that's only a raw number. When the user comes back — having just
  /// *seen* the real thread — offer to nickname it.
  ///
  /// Groups deliberately get no such prompt. We tried letting the user attach
  /// an incoming group's roster for deep-linking, but an sms: recipient link
  /// resolves to the *SMS/MMS* thread for those members — for an RCS group
  /// (most incoming groups) that opens a different conversation with the same
  /// people. Only groups created in Threadly (born from that same sms: link)
  /// deep-link safely.
  Conversation? _mappingPromptPending;

  /// Conversations the user said "don't ask" for. In-memory: asking again
  /// next session is fine, nagging within one is not.
  final Set<String> _mappingPromptDeclined = {};

  /// Conversations whose suggestion the user put off ("Not now") this
  /// session; "Don't suggest" is remembered natively for good.
  final Set<String> _suggestDeferred = {};

  /// Reminder suggestions already offered this session ("id|epoch ms"), so
  /// the same date isn't offered again on every return.
  final Set<String> _offeredReminders = {};

  bool _searching = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A cold start can itself be a return: the chip (shown after a Messages
    // notification tap) launching Threadly fresh.
    _load().then((_) async {
      await _refreshChipStatus();
      await _afterReturn(null, null);
    });
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
    if (state != AppLifecycleState.resumed) return;
    final pending = _mappingPromptPending;
    _mappingPromptPending = null;
    final handoffAt = _lastHandoffAt;
    final fromHandoff = (handoffAt != null &&
            DateTime.now().difference(handoffAt) < _returnWindow)
        ? _lastHandoff
        : null;
    _lastHandoff = null;
    _lastHandoffAt = null;
    _load(reloadContacts: true).then((_) async {
      // Also re-reads the chip status: the user may have just granted the
      // overlay permission in Settings.
      await _refreshChipStatus();
      await _afterReturn(fromHandoff, fromHandoff != null ? pending : null,
          handoffAt: handoffAt);
    });
  }

  /// Back in Threadly from a conversation in Messages — opened from here
  /// ([fromHandoff]) or by tapping Messages' own notification (the chip
  /// remembers which, natively). Show where they were, then at most one
  /// prompt. [pending] is a raw-number 1:1 due a nickname offer.
  Future<void> _afterReturn(
    Conversation? fromHandoff,
    Conversation? pending, {
    DateTime? handoffAt,
  }) async {
    // Always consume, so a notification tap never lingers. Whichever came
    // last wins: a notification tapped in Messages *after* a handoff is
    // where the user actually was.
    final tapped = await _chip.consumeReturnTarget();
    var from = fromHandoff;
    if (tapped != null &&
        (fromHandoff == null ||
            handoffAt == null ||
            tapped.at.isAfter(handoffAt))) {
      final t = _conversations.where((x) => x.id == tapped.id).firstOrNull;
      if (t != null) {
        from = t;
        pending = _needsMappingPrompt(t) ? t : null;
      }
    }
    final back = from;
    if (!mounted || back == null) return;
    // Show where they were. Any prompt waits for the blink so it doesn't
    // cover it.
    _blink(back.id);
    // Ask the on-device model meanwhile (it only runs while Threadly is on
    // screen, so not before now). Fresh copy if the conversation is listed.
    final c = _conversations.where((x) => x.id == back.id).firstOrNull ?? back;
    final suggestion = _suggestDeferred.contains(c.id)
        ? Future<Suggestion?>.value()
        : _suggestFor(c);
    await Future<void>.delayed(_Blink.duration);
    final s = _returnOffer(c, await suggestion);
    if (!mounted) return;
    // One prompt per return, in this order: a suggestion (which also covers
    // the raw-number nickname offer), the plain nickname offer, then the
    // one-time chip offer.
    if (s != null) {
      _offerSuggestion(c, s);
    } else if (pending != null) {
      _offerNickname(pending);
    } else {
      final chip = _chipStatus;
      if (chip != null && !chip.active && !chip.nudged) {
        _maybeOfferReturnChip();
      }
    }
  }

  /// The title to show: a raw-number 1:1 shows its contact name once saved
  /// (the stored title only updates with Google Messages' next notification).
  String _displayTitle(Conversation c) =>
      c.isGroup ? c.title : (_contacts.nameForPhone(c.title) ?? c.title);

  /// A 1:1 whose title is just a phone number (not a saved contact).
  bool _isRawNumber(Conversation c) =>
      !c.isGroup &&
      _numberFromTitle(c.title) != null &&
      _contacts.nameForPhone(c.title) == null;

  /// What, if anything, to offer on return from Messages. A conversation
  /// not organized at all yet (no nickname, note, or category) gets the full
  /// suggestion; an organized one only a *new* reminder (a date mentioned
  /// since), so filed chats aren't nagged. Fields already set are dropped.
  /// The organize sheet always shows everything.
  Suggestion? _returnOffer(Conversation c, Suggestion? s) {
    if (s == null) return null;
    final ann = _annotations[c.id];
    final remindKey = '${c.id}|${s.remindAt?.millisecondsSinceEpoch}';
    final offer = s.copyWith(
      dropNickname: ann?.name?.isNotEmpty == true,
      dropNote: ann?.note?.isNotEmpty == true,
      dropRemind: s.remindAt == null ||
          s.remindAt!.millisecondsSinceEpoch == ann?.remindAtMs ||
          _offeredReminders.contains(remindKey),
    );
    final unorganized = ann?.name?.isNotEmpty != true &&
        ann?.note?.isNotEmpty != true &&
        _categoryIdsFor(c).isEmpty;
    final result = unorganized
        ? offer
        : offer.copyWith(dropNickname: true, dropNote: true, dropCategory: true);
    if (result.isEmpty) return null;
    if (result.remindAt != null) _offeredReminders.add(remindKey);
    return result;
  }

  Future<Suggestion?> _suggestFor(Conversation c, {bool force = false}) {
    final mine = _categoryIdsFor(c);
    return _suggest.suggest(
      c,
      categories: [
        for (final cat in _categories)
          if (!mine.contains(cat.id)) cat.name,
      ],
      wantName: _isRawNumber(c),
      force: force,
    );
  }

  /// Offer what the model suggested for [c], to accept, edit, or skip.
  /// Nothing is saved without a tap.
  Future<void> _offerSuggestion(Conversation c, Suggestion s) async {
    final number = _isRawNumber(c) ? _numberFromTitle(c.title) : null;
    // A raw number's nickname is the person's name: offer it as a contact.
    final person = number != null ? s.nickname : null;
    final category = _categories
        .where((cat) => cat.name == s.category)
        .firstOrNull;
    // Nickname: a group's topic or a person's name. Note: what it's about.
    final nickname = TextEditingController(text: s.nickname ?? '');
    final note = TextEditingController(text: s.note ?? '');
    var addCategory = category != null;
    final remindAt = s.remindAt;
    var remind = remindAt != null;
    // One reminder per conversation: say so when this would replace one.
    final existing = _annotations[c.id]?.remindAtMs;
    final replaces = existing != null &&
        DateTime.fromMillisecondsSinceEpoch(existing).isAfter(DateTime.now());
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 0, 24, MediaQuery.of(ctx).viewInsets.bottom + 8),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 20, color: Theme.of(ctx).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Organize “${c.title}”?',
                        style: Theme.of(ctx).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Suggested from recent messages, on this phone.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                if (person != null) ...[
                  const SizedBox(height: 16),
                  Text('This looks like $person.'),
                ],
                // A raw number always gets the name field: whatever's typed
                // there can become a contact.
                if (s.nickname != null || number != null) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: nickname,
                    textCapitalization: number != null
                        ? TextCapitalization.words
                        : TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: number != null
                          ? 'Name or nickname'
                          : 'Nickname (shown as a subtitle)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
                if (number != null)
                  _SaveContactButton(
                    name: nickname,
                    onPressed: () => Navigator.pop(ctx, 'contact'),
                  ),
                if (s.note != null) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: note,
                    decoration: const InputDecoration(
                      labelText: 'Note',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                if (category != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: addCategory,
                    onChanged: (v) => setSheet(() => addCategory = v ?? false),
                    secondary: CircleAvatar(
                        radius: 6, backgroundColor: Color(category.color)),
                    title: Text('Add to ${category.name}'),
                  ),
                if (remindAt != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: remind,
                    onChanged: (v) => setSheet(() => remind = v ?? false),
                    secondary: const Icon(Icons.alarm),
                    title: Text('Remind me ${formatDue(remindAt)}'),
                    subtitle: (s.remindWhat != null || replaces)
                        ? Text([
                            ?s.remindWhat,
                            if (replaces)
                              'Replaces your reminder for '
                                  '${formatDue(DateTime.fromMillisecondsSinceEpoch(existing))}',
                          ].join(' · '))
                        : null,
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, 'save'),
                    child: const Text('Save'),
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'later'),
                      child: const Text('Not now'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, 'never'),
                      child: const Text('Don’t suggest for this one'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final name = nickname.text.trim();
    final noteText = note.text.trim();
    nickname.dispose();
    note.dispose();
    if (!mounted) return;
    // Save what's checked/filled. "Save to contacts" saves the same, except
    // the name goes to the contact instead of the nickname (it'd duplicate
    // the contact name the row shows once saved).
    Future<void> save({required bool nicknameToo}) async {
      final ann = _annotations[c.id];
      final newName = nicknameToo && name.isNotEmpty ? name : null;
      final remindAtMs = (remind && remindAt != null)
          ? remindAt.millisecondsSinceEpoch
          : ann?.remindAtMs;
      if (newName != null ||
          noteText.isNotEmpty ||
          remindAtMs != ann?.remindAtMs) {
        // Keep the rest of the annotation: setAnnotation replaces the row.
        await _store.setAnnotation(c.id,
            name: newName ?? ann?.name,
            color: ann?.color,
            note: noteText.isNotEmpty ? noteText : ann?.note,
            remindAtMs: remindAtMs,
            remindWhat: (remind && remindAt != null) ? s.remindWhat : null);
      }
      if (remind && remindAt != null) {
        await _reminders.ensurePermission();
        final shownName = name.isNotEmpty ? name : (ann?.name ?? '');
        await _reminders.schedule(
          c.id,
          title: shownName.isNotEmpty ? shownName : _displayTitle(c),
          body: s.remindWhat ??
              (noteText.isNotEmpty
                  ? noteText
                  : 'You asked to be reminded about this conversation.'),
          when: remindAt,
        );
      }
      if (addCategory && category != null) {
        await _store.setMembership(category.id, c.id, true);
      }
      _load();
    }

    switch (choice) {
      case 'contact':
        await save(nicknameToo: false);
        // The contacts app takes it from here; the name shows once saved
        // (contacts reload when Threadly resumes).
        await _suggest.saveContact(name, number!);
      case 'save':
        await save(nicknameToo: true);
      case 'never':
        await _suggest.dismiss(c.id);
      default: // "Not now" or dismissed: ask again next session.
        _suggestDeferred.add(c.id);
    }
  }

  /// Pulse [id]'s row (see [_Blink]); the trigger clears once it's done so a
  /// row built later (another tab, scrolled in) doesn't blink late.
  void _blink(String id) {
    final seq = ++_blinkSeq;
    setState(() => _blinkId = id);
    Future<void>.delayed(_Blink.duration, () {
      if (mounted && _blinkSeq == seq) setState(() => _blinkId = null);
    });
  }

  Future<void> _refreshChipStatus() async {
    final s = await _chip.status();
    if (mounted) setState(() => _chipStatus = s);
  }

  /// After a handoff: draw the return chip over Messages (no-op unless set
  /// up) and remember [c] for the way back.
  void _handedOff(Conversation c) {
    _queueMappingPrompt(c);
    _lastHandoff = c;
    _lastHandoffAt = DateTime.now();
    _chip.show();
  }

  /// Offer the return chip once, the first time the user comes back from
  /// Messages without it — right when the two-Back trip is fresh.
  Future<void> _maybeOfferReturnChip() async {
    final s = _chipStatus;
    if (s == null || s.active || s.nudged) return;
    await _chip.markNudged();
    if (!mounted) return;
    final turnOn = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'One tap back to Threadly',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Back in Messages goes to its inbox first. Threadly can show a '
                'small floating “Threadly” button over Messages after you open '
                'a conversation: one tap brings you back to where you were. '
                'It disappears when you return.\n\n'
                'Android calls this “Display over other apps”: in the list '
                'that opens, find Threadly and switch it on, then come back. '
                'You can turn the button off anytime from the ⋮ menu.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Turn on in Settings'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No thanks'),
              ),
            ],
          ),
        ),
      ),
    );
    if (turnOn == true) await _enableReturnChip();
  }

  /// Turn the chip on: the preference, plus the system permission if needed
  /// (opens Settings; status refreshes on resume).
  Future<void> _enableReturnChip() async {
    await _chip.setEnabled(true);
    if (_chipStatus?.granted != true) {
      await _chip.openSettings();
    } else {
      await _refreshChipStatus();
    }
  }

  /// Pull everything fresh. Only the very first load shows a spinner; later
  /// ones (every return from Messages, every edit) refresh in place so the
  /// list keeps its scroll position and tab. Contacts — the slow part, every
  /// contact plus its photo — are re-read only when [reloadContacts] (first
  /// load, return from Messages where a contact may have just been added,
  /// manual refresh); in-app edits can't change them.
  Future<void> _load({bool reloadContacts = false}) async {
    final first = !_loadedOnce;
    if (first) setState(() => _loading = true);
    final granted = await _notifs.permissionGranted();
    var contacts = _contacts;
    if (first || reloadContacts) {
      try {
        contacts = await _contactsService.load();
      } catch (_) {
        contacts = ContactsSnapshot.empty;
      }
    }
    final conversations = [
      for (final c in granted
          ? await _notifs.conversations()
          : const <Conversation>[])
        if (!_isAutomatedSender(c, contacts)) c,
    ];
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
    final replyStates = await _store.allReplyStates();
    // NOTE: we deliberately do NOT build group recipients from harvested
    // senders. The notification only reveals who *sent*, never the full roster,
    // and an incomplete roster opens the wrong conversation (a 1:1 or a
    // different group). Only groups created in Threadly (full picker roster, set
    // on pending-merge) get a deep-linkable recipient list.
    //
    // Purge any single-member group rosters left by earlier builds — they'd open
    // a 1:1 with that one person instead of the group.
    for (final e in groupRecipients.entries.toList()) {
      if (e.value.length < 2) {
        await _store.clearGroupRecipients(e.key);
        groupRecipients.remove(e.key);
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
      _replyStates = replyStates;
      _loading = false;
      _loadedOnce = true;
    });
    _judgeReplies();
  }

  /// Conversations in the "To reply" tab, newest first.
  List<Conversation> _toReply() {
    final now = DateTime.now();
    return [
      for (final c in _conversations)
        if (belongsInToReply(
          lastActivity: c.lastActivity,
          lastFromMe: c.lastFromMe,
          preview: c.preview,
          state: _replyStates[c.id] ?? ReplyState.none,
          now: now,
        ))
          c,
    ];
  }

  /// Ask the on-device AI, one at a time, whether each unjudged "To reply"
  /// candidate's newest message needs an answer; save each verdict (so a
  /// message is judged once) and drop "no"s from the tab as they come in.
  /// Stops when Threadly leaves the screen (AICore only serves the app on
  /// screen) or the model can't answer; unjudged chats stay in the tab.
  Future<void> _judgeReplies() async {
    if (_judging) return;
    _judging = true;
    try {
      for (final c in _toReply()) {
        final state = _replyStates[c.id] ?? ReplyState.none;
        if (!needsVerdict(lastActivity: c.lastActivity, state: state)) continue;
        if (!mounted ||
            WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
          return;
        }
        final verdict = await _suggest.needsReply(c);
        if (verdict == null) return;
        final at = c.lastActivity.millisecondsSinceEpoch;
        await _store.setReplyVerdict(c.id, at, verdict);
        if (!mounted) return;
        setState(() => _replyStates = {
              ..._replyStates,
              c.id: ReplyState(
                  doneAtMs: state.doneAtMs, verdictAtMs: at, needsReply: verdict),
            });
      }
    } finally {
      _judging = false;
    }
  }

  /// "Done" in the To reply tab: hide [c] until a newer message arrives.
  /// Updates state synchronously (the swiped row must leave the tree now).
  void _markDone(Conversation c) {
    final at = c.lastActivity.millisecondsSinceEpoch;
    final before = _replyStates[c.id] ?? ReplyState.none;
    setState(() => _replyStates = {
          ..._replyStates,
          c.id: ReplyState(
              doneAtMs: at,
              verdictAtMs: before.verdictAtMs,
              needsReply: before.needsReply),
        });
    _store.setReplyDone(c.id, at);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(undoSnackBar('${_displayTitle(c)}: done', () {
        _store.setReplyDone(c.id, before.doneAtMs);
        if (mounted) {
          setState(() => _replyStates = {..._replyStates, c.id: before});
        }
      }));
  }

  /// The user replied to [c] through Threadly (Ask Threadly opened the
  /// draft): it's handled, as far as "To reply" is concerned.
  Future<void> _markReplied(Conversation c) async {
    final at = c.lastActivity.millisecondsSinceEpoch;
    await _store.setReplyDone(c.id, at);
    if (!mounted) return;
    final before = _replyStates[c.id] ?? ReplyState.none;
    setState(() => _replyStates = {
          ..._replyStates,
          c.id: ReplyState(
              doneAtMs: at,
              verdictAtMs: before.verdictAtMs,
              needsReply: before.needsReply),
        });
  }

  /// "Forget conversation" from its sheet (no longer a swipe: it collided
  /// with Android's back gesture).
  Future<void> _forgetFromSheet(Conversation c) async {
    if (await _confirmForget(c)) await _forget(c);
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

  /// True for an automated/short-code sender we don't want in the list: a numeric
  /// title with fewer than 10 digits (short codes like 262966), or an unsaved
  /// alphanumeric sender id (CHASE, GOOGLE). Real people are kept — groups, a
  /// 10+ digit number, or a title that resolves to a saved contact.
  bool _isAutomatedSender(Conversation c, ContactsSnapshot contacts) {
    if (c.isGroup) return false;
    final title = c.title.trim();
    final digits = title.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 10) return false; // a real phone number
    if (contacts.phoneForName(title) != null) return false; // a saved contact
    return true;
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
    final toReply = _toReply().length;
    final tabs = [
      'All',
      toReply > 0 ? 'To reply ($toReply)' : 'To reply',
      ..._categories.map((c) => c.name),
    ];
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
                    Builder(builder: (context) {
                      final now = DateTime.now();
                      final due = _reminderEntries()
                          .where((e) => !e.when.isAfter(now))
                          .length;
                      return IconButton(
                        tooltip: 'Reminders',
                        icon: Badge(
                          isLabelVisible: due > 0,
                          label: Text('$due'),
                          child: const Icon(Icons.alarm),
                        ),
                        onPressed: _openReminders,
                      );
                    }),
                    IconButton(
                      tooltip: 'Refresh',
                      icon: const Icon(Icons.refresh),
                      onPressed: () => _load(reloadContacts: true),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v != 'chip') return;
                        if (_chipStatus?.active == true) {
                          await _chip.setEnabled(false);
                          await _refreshChipStatus();
                        } else {
                          await _enableReturnChip();
                        }
                      },
                      itemBuilder: (_) => [
                        CheckedPopupMenuItem(
                          value: 'chip',
                          checked: _chipStatus?.active == true,
                          child: const Text('“Back to Threadly” button'),
                        ),
                      ],
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
        _replyTab(),
        for (final c in _categories) _tab(_forCategory(c.id), c.id),
      ],
    );
  }

  /// "To reply": recent conversations whose newest message (from someone
  /// else) looks like it needs an answer. Swipe left marks one done.
  Widget _replyTab() {
    final convos = _toReply();
    if (convos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing waiting on you.\n\nRecent messages that look like they '
            'need an answer show up here. Swipe one left when it’s handled.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      children: [for (final c in convos) _tile(c, replyTab: true)],
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
              'It uses them to list your conversations and show each one’s latest '
              'message — the only notifications it posts are reminders you set '
              'yourself, and you still read and reply in Google Messages.',
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
              onPressed: () => _load(reloadContacts: true),
              child: const Text('I’ve enabled it — refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Conversation c, {bool replyTab = false}) {
    final ann = _annotations[c.id];
    final photo = c.isGroup ? null : _contacts.photoForTitle(c.title);
    final unread = _isUnread(c);
    // A nickname that just repeats the title (e.g. kept after saving the
    // number as a contact with the same name) adds nothing: hide it.
    final hasName = ann?.name?.isNotEmpty == true &&
        ann!.name!.trim().toLowerCase() != _displayTitle(c).trim().toLowerCase();
    final hasNote = ann?.note?.isNotEmpty == true;
    final preview = c.preview;
    final chips = [
      for (final cat in _categories)
        if (_categoryIdsFor(c).contains(cat.id)) cat,
    ];
    final subtitle = <Widget>[
      if (preview != null)
        Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: unread ? FontWeight.w600 : null,
          ),
        ),
      if (hasName)
        Text(
          ann.name!,
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
      if (ann?.remindAtMs != null) _reminderLine(ann!.remindAtMs!),
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
    // Keyed: list children match by key, not position, so a running pulse
    // stays with its conversation when a refresh re-sorts the list.
    return _Blink(
      key: ValueKey('row-${c.id}'),
      trigger: c.id == _blinkId ? _blinkSeq : 0,
      child: Dismissible(
      key: ValueKey('conv-${c.id}'),
      // Right: save for later (the row stays). Left, in "To reply" only:
      // done. No destructive swipe — a left swipe from the edge is also
      // Android's back gesture; forgetting lives in the sheet. A long drag
      // is needed so a short edge gesture doesn't trigger either.
      direction: replyTab
          ? DismissDirection.horizontal
          : DismissDirection.startToEnd,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.5,
        DismissDirection.endToStart: 0.5,
      },
      background: Container(
        color: Theme.of(context).colorScheme.primaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.snooze,
                color: Theme.of(context).colorScheme.onPrimaryContainer),
            const SizedBox(width: 8),
            Text('Later',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer)),
          ],
        ),
      ),
      secondaryBackground: Container(
        color: Theme.of(context).colorScheme.secondaryContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Done',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSecondaryContainer)),
            const SizedBox(width: 8),
            Icon(Icons.done,
                color: Theme.of(context).colorScheme.onSecondaryContainer),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _saveForLater(c);
          return false;
        }
        return true; // Done (To reply tab only)
      },
      onDismissed: (_) => _markDone(c),
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
              c.title.isEmpty ? 'Unknown' : _displayTitle(c),
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
      ),
    );
  }

  /// "⏰ Jul 8, 9:00 AM" under a conversation with a reminder set — primary
  /// while pending, error-tinted once it has elapsed (so a fired reminder stays
  /// visible until cleared or replaced in the organize sheet).
  Widget _reminderLine(int remindAtMs) {
    final when = DateTime.fromMillisecondsSinceEpoch(remindAtMs);
    final elapsed = !when.isAfter(DateTime.now());
    final color = elapsed
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.alarm, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            formatMessageTime(when),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color),
          ),
        ],
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
    await _reminders.cancel(c.id);
    await _store.setAnnotation(c.id); // all-null clears the row
    // Also drop any saved roster: for an incoming group it may deep-link the
    // wrong (MMS) thread, and forgetting should be a clean slate either way.
    await _store.clearGroupRecipients(c.id);
    await _store.clearReplyState(c.id);
    for (final cat in _categories) {
      await _store.setMembership(cat.id, c.id, false);
    }
    if (mounted) _load();
  }

  Future<void> _open(Conversation c) async {
    await _markRead(c);
    // 1) Open the exact thread by Google Messages' own conversation id (works
    //    for every kind, incoming RCS groups included, notification or not).
    //    It relies on undocumented GM extras, hence the fallbacks below.
    if (await _notifs.launch(c.id)) {
      _handedOff(c);
      return;
    }
    // 2) Deep-link by number(s): the contact's number for a 1:1, or the saved
    //    roster of a group created here.
    final recipients = _draftRecipients(c);
    if (recipients != null && await openSmsCompose(recipients)) {
      _handedOff(c);
      return;
    }
    // 3) Last resort: the Google Messages inbox.
    if (await _notifs.openMessagesApp()) {
      _handedOff(c);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't open this conversation in Messages."),
        ),
      );
    }
  }

  /// Set ([when]) or clear (null) [c]'s reminder without touching the rest
  /// of its annotation — "save for later", snooze, and the reminders screen.
  Future<void> _setReminder(Conversation c, DateTime? when) async {
    final ann = await _store.setReminder(c.id, when?.millisecondsSinceEpoch);
    if (when == null) {
      await _reminders.cancel(c.id);
    } else {
      await _reminders.ensurePermission();
      final nickname = ann?.name ?? '';
      await _reminders.schedule(
        c.id,
        title: nickname.isNotEmpty ? nickname : _displayTitle(c),
        body: ann?.remindWhat ??
            ((ann?.note?.isNotEmpty ?? false)
                ? ann!.note
                : 'You asked to be reminded about this conversation.'),
        when: when,
      );
    }
    await _load();
  }

  /// "Save for later" (swipe right): pick a time, set the reminder, and
  /// offer an undo.
  Future<void> _saveForLater(Conversation c) async {
    final before = _annotations[c.id]?.remindAtMs;
    final when = await pickLater(context, title: 'Save for later');
    if (when == null || !mounted) return;
    await _setReminder(c, when);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(undoSnackBar(
        'Saved for later: ${formatDue(when)}',
        () => _setReminder(
            c,
            before != null &&
                    DateTime.fromMillisecondsSinceEpoch(before)
                        .isAfter(DateTime.now())
                ? DateTime.fromMillisecondsSinceEpoch(before)
                : null,
        ),
      ));
  }

  /// Every conversation with a reminder, for the reminders screen.
  List<ReminderEntry> _reminderEntries() => [
        for (final c in _conversations)
          if (_annotations[c.id]?.remindAtMs case final ms?)
            (
              conversation: c,
              title: _displayTitle(c),
              nickname: _visibleNickname(c),
              what: _annotations[c.id]?.remindWhat ?? _annotations[c.id]?.note,
              when: DateTime.fromMillisecondsSinceEpoch(ms),
            ),
      ];

  /// The nickname as the list shows it (hidden when it repeats the title).
  String? _visibleNickname(Conversation c) {
    final name = _annotations[c.id]?.name?.trim() ?? '';
    if (name.isEmpty ||
        name.toLowerCase() == _displayTitle(c).trim().toLowerCase()) {
      return null;
    }
    return name;
  }

  Future<void> _openReminders() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RemindersScreen(
        entries: _reminderEntries,
        setReminder: _setReminder,
        open: _open,
      ),
    ));
    if (mounted) setState(() {});
  }

  /// Who an `sms:` link for [c] addresses: the contact's number for a 1:1,
  /// or the complete roster (2+) of a group created here — a partial roster
  /// would open a 1:1 or a different group. Null when [c] can't be addressed
  /// by number (an incoming group), so no draft can be pre-filled.
  List<String>? _draftRecipients(Conversation c) {
    if (c.isGroup) {
      final roster = _groupRecipients[c.id];
      return (roster != null && roster.length >= 2) ? roster : null;
    }
    final number = _contacts.phoneForName(c.title) ?? _numberFromTitle(c.title);
    return number != null ? [number] : null;
  }

  /// Open [c] in Messages with [text] typed in as a draft; the user sends.
  /// Where Messages can't pre-fill the thread (an incoming group), the text
  /// is copied and the exact thread opened, to paste.
  Future<void> _openWithText(Conversation c, String text) async {
    final recipients = _draftRecipients(c);
    if (recipients != null && await openSmsCompose(recipients, body: text)) {
      _handedOff(c);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (await _notifs.launch(c.id) || await _notifs.openMessagesApp()) {
      _handedOff(c);
    }
  }

  /// After handing [c] off to Google Messages, remember it for a mapping nudge
  /// on return when it's hard to recognize in Threadly: a 1:1 that resolves to
  /// no saved contact and has no nickname yet (fix: add one — no more
  /// memorizing numbers). Groups get no prompt (see [_mappingPromptPending]).
  void _queueMappingPrompt(Conversation c) {
    if (_needsMappingPrompt(c)) _mappingPromptPending = c;
  }

  /// A 1:1 shown only as a number (no contact, no nickname) that the user
  /// hasn't declined naming this session.
  bool _needsMappingPrompt(Conversation c) {
    if (c.isGroup || _mappingPromptDeclined.contains(c.id)) return false;
    final hasContact = _contacts.phoneForName(c.title) != null ||
        _contacts.nameForPhone(c.title) != null;
    final hasNickname = _annotations[c.id]?.name?.isNotEmpty == true;
    return !hasContact && !hasNickname;
  }

  /// A 1:1 that's just a raw number: after the user comes back from reading it
  /// in Messages (so they now know who it is), offer to nickname it.
  Future<void> _offerNickname(Conversation c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recognize “${c.title}” next time?',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'This conversation only shows a phone number. If you now know '
                'who it is, give it a nickname (or a color or category) so you '
                'don’t have to memorize the number.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'add'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Add a nickname'),
                ),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, 'later'),
                    child: const Text('Not now'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, 'never'),
                    child: const Text('Don’t ask for this number'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'never') {
      _mappingPromptDeclined.add(c.id);
      return;
    }
    if (choice != 'add') return; // "Not now" or dismissed: ask next time.
    await _organize(c);
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
    // Ask once, up front: the sheet's builder can run more than once, and
    // each call would be another on-device inference. The user opened it
    // themselves, so suggest even after "don't suggest" on a return prompt.
    final suggestion = _suggestFor(c, force: true);
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
        suggestion: suggestion,
        rawNumber: _isRawNumber(c) ? _numberFromTitle(c.title) : null,
        suggestService: _suggest,
        contacts: _contacts,
        openHere: (text) => _openWithText(c, text),
        canPrefillHere: _draftRecipients(c) != null,
        onReplied: () => _markReplied(c),
        onForget: () => _forgetFromSheet(c),
      ),
    );
    // Toggles/notes persist live; reload to reflect them (also covers dismiss
    // without an explicit Save).
    if (mounted) _load();
  }
}

/// "You came from here": on return from Messages, scrolls the row into view
/// (only if it isn't already, so the list otherwise keeps its place) and
/// pulses it twice with the theme's primary color.
class _Blink extends StatefulWidget {
  const _Blink({super.key, required this.trigger, required this.child});

  static const duration = Duration(milliseconds: 1100);

  /// Non-zero starts the pulse; a new non-zero value restarts it.
  final int trigger;
  final Widget child;

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _Blink.duration);

  static final _pulses = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 2),
  ]);

  @override
  void initState() {
    super.initState();
    if (widget.trigger != 0) _start();
  }

  @override
  void didUpdateWidget(_Blink old) {
    super.didUpdateWidget(old);
    if (widget.trigger != 0 && widget.trigger != old.trigger) _start();
  }

  void _start() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Reveal it if it's off screen: each policy only scrolls one way, and
      // is a no-op when the row is already fully visible.
      for (final policy in [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        if (!mounted) return;
        await Scrollable.ensureVisible(
          context,
          alignmentPolicy: policy,
          duration: const Duration(milliseconds: 250),
        );
      }
      if (mounted) _controller.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ColoredBox(
        color: color.withValues(alpha: 0.22 * _pulses.evaluate(_controller)),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// "Save to contacts" for a raw-number conversation, using the name typed in
/// [name] (enabled once it's non-empty). Opens the system new-contact screen
/// prefilled; Threadly itself never writes contacts.
class _SaveContactButton extends StatelessWidget {
  const _SaveContactButton({required this.name, required this.onPressed});

  final TextEditingController name;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: name,
      builder: (context, value, _) {
        final typed = value.text.trim();
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: typed.isEmpty ? null : onPressed,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: Text(
              typed.isEmpty ? 'Save to contacts' : 'Save “$typed” to contacts',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
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

  /// On-device suggestion, shown as tap-to-apply chips once it arrives.
  final Future<Suggestion?> suggestion;

  /// The number, when this is a raw-number 1:1 (enables "save to contacts").
  final String? rawNumber;
  final SuggestionService suggestService;

  /// For "Ask Threadly": resolving names, and opening this conversation with
  /// a draft (pre-filled when [canPrefillHere], else copied to paste).
  final ContactsSnapshot contacts;
  final Future<void> Function(String text) openHere;
  final bool canPrefillHere;

  /// Ask Threadly opened a reply here (clears it from "To reply").
  final Future<void> Function() onReplied;

  /// Remove the conversation from Threadly (asks first).
  final Future<void> Function() onForget;

  const _OrganizeSheet({
    required this.store,
    required this.conversation,
    required this.categories,
    required this.selectedCategoryIds,
    required this.annotation,
    required this.suggestion,
    required this.rawNumber,
    required this.suggestService,
    required this.contacts,
    required this.openHere,
    required this.canPrefillHere,
    required this.onReplied,
    required this.onForget,
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
  late int? _remindAtMs = widget.annotation?.remindAtMs;
  late List<Category> _categories = widget.categories;
  late final Set<int> _selected = {...widget.selectedCategoryIds};
  final ReminderService _reminders = ReminderService();
  Suggestion? _suggestion;

  /// What the reminder is for ("Big move at home"): saved with it, shown on
  /// the reminders screen, and used as the notification text.
  late String? _remindWhat = widget.annotation?.remindWhat;

  // "Ask Threadly": the instruction box, whether it's thinking, what it says
  // back, and a category it proposes (applied on tap).
  final TextEditingController _ask = TextEditingController();
  bool _asking = false;

  /// Whether the color + categories section is expanded (collapsed at first).
  bool _showStyle = false;
  String? _askInfo;
  Category? _askCategory;

  static const _askExamples = '“forward this to Steve, say it’s from Adam”, '
      '“tell them I’m running late”, “remind me Friday at 5”, or '
      '“put this in Soccer”';

  /// Interpret the instruction on the device, then stage the result for the
  /// user to confirm: a draft card (forward / reply), or filled-in fields
  /// (remind / file) that Save keeps.
  Future<void> _runAsk() async {
    final instruction = _ask.text.trim();
    if (instruction.isEmpty || _asking) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _asking = true;
      _askInfo = null;
      _askCategory = null;
    });
    final r = await widget.suggestService.interpret(
      widget.conversation,
      instruction,
      categories: [
        for (final c in _categories)
          if (!_selected.contains(c.id)) c.name,
      ],
    );
    if (!mounted) return;
    setState(() => _asking = false);
    final cmd = r.command;
    if (cmd == null) {
      setState(() => _askInfo = r.unavailable
          ? 'Ask Threadly needs the on-device AI, which isn’t available right '
              'now. Try again in a moment.'
          : 'Sorry, I didn’t get that. Try $_askExamples.');
      return;
    }
    switch (cmd.action) {
      case CommandAction.forward || CommandAction.reply:
        await _confirmDraft(cmd);
      case CommandAction.remind:
        final now = DateTime.now();
        final due = (cmd.when != null ? parseDueDate(cmd.when!, now) : null) ??
            parseDueDate(instruction, now);
        if (due == null || !due.when.isAfter(now)) {
          setState(() => _askInfo = 'I couldn’t tell when. Try “remind me '
              'Friday at 5” or “in 2 hours”.');
          return;
        }
        setState(() {
          _remindAtMs = due.when.millisecondsSinceEpoch;
          _remindWhat = cmd.text;
          _askInfo =
              'Reminder set for ${formatDue(due.when)}. Tap Save to keep it.';
          _ask.clear();
        });
      case CommandAction.file:
        final cat = _categories
            .where((c) => c.name == cmd.category && !_selected.contains(c.id))
            .firstOrNull;
        final nickname = cmd.nickname;
        if (cat == null && nickname == null) {
          setState(() => _askInfo = 'I couldn’t tell how to file it. Your '
              'categories: ${_categories.map((c) => c.name).join(', ')}.');
          return;
        }
        setState(() {
          if (nickname != null) _name.text = nickname;
          _askCategory = cat;
          _askInfo = [
            if (nickname != null) 'Nickname filled in. Tap Save to keep it.',
            if (cat != null) 'Tap to add it to ${cat.name}:',
          ].join(' ');
          _ask.clear();
        });
    }
  }

  /// The confirmation card for a forward or reply: who it goes to (choosing
  /// among same-named contacts), which message (forward), and the editable
  /// text. Confirming opens Messages with the draft; nothing is sent here.
  Future<void> _confirmDraft(ThreadlyCommand cmd) async {
    final here = widget.conversation;
    final forward = cmd.action == CommandAction.forward;
    String norm(String t) => t.toLowerCase().trim();
    final toName = cmd.to;
    final toHere = toName == null ||
        norm(toName) == norm(here.title) ||
        (_name.text.trim().isNotEmpty && norm(toName) == norm(_name.text));
    final matches = toHere
        ? const <({String phone, String display})>[]
        : widget.contacts.matchPeople(toName);
    var picked = matches.length == 1 ? matches.first : null;

    final recent = forward
        ? await widget.suggestService.recentMessages(here.id)
        : const <({String sender, String text, DateTime time})>[];
    if (!mounted) return;
    final messages = recent.isNotEmpty
        ? recent.take(5).toList()
        : [
            if (here.preview != null && here.preview!.isNotEmpty)
              (sender: '', text: here.preview!, time: here.lastActivity),
          ];
    var message = messages.where((m) => m.sender != 'Me').firstOrNull ??
        messages.firstOrNull;
    if (forward && message == null) {
      setState(() => _askInfo = 'There’s no message here to forward yet.');
      return;
    }
    String bodyFor(({String sender, String text, DateTime time})? m) => forward
        ? forwardBody(m!.text,
            note: cmd.text, sender: here.isGroup ? m.sender : here.title)
        : (cmd.text ?? '');
    final body = TextEditingController(text: bodyFor(message));
    final saved = widget.annotation?.name?.trim() ?? '';
    final hereLabel = saved.isNotEmpty ? saved : here.title;

    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setCard) {
          final theme = Theme.of(ctx);
          final noOne = !toHere && matches.isEmpty;
          final title = forward
              ? 'Forward to ${toHere ? hereLabel : (picked?.display ?? toName)}'
              : toHere
                  ? (here.isGroup ? 'Reply in “$hereLabel”' : 'Reply to $hereLabel')
                  : 'Text ${picked?.display ?? toName}';
          return Padding(
            padding: EdgeInsets.fromLTRB(
                24, 0, 24, MediaQuery.of(ctx).viewInsets.bottom + 8),
            child: SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    if (noOne) ...[
                      const SizedBox(height: 12),
                      Text('No contact matches “$toName”. Try their full '
                          'name as saved in Contacts.'),
                    ],
                    if (matches.length > 1) ...[
                      const SizedBox(height: 12),
                      Text('Which one?', style: theme.textTheme.labelLarge),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final m in matches)
                            ChoiceChip(
                              label: Text('${m.display} · ${_prettyPhone(m.phone)}'),
                              selected: picked == m,
                              onSelected: (_) => setCard(() => picked = m),
                            ),
                        ],
                      ),
                    ],
                    if (forward && messages.length > 1) ...[
                      const SizedBox(height: 12),
                      Text('Message', style: theme.textTheme.labelLarge),
                      RadioGroup<int>(
                        groupValue: messages.indexOf(message!),
                        onChanged: (i) => setCard(() {
                          message = messages[i!];
                          body.text = bodyFor(message);
                        }),
                        child: Column(
                          children: [
                            for (final (i, m) in messages.indexed)
                              RadioListTile<int>(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                value: i,
                                title: Text(
                                  [if (m.sender.isNotEmpty) '${m.sender}:', m.text]
                                      .join(' '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (!noOne) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: body,
                        minLines: 2,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Message',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (toHere && !widget.canPrefillHere) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Messages can’t pre-fill this group, so Threadly copies '
                        'the text and opens the chat. Just paste and send.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        const Spacer(),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: body,
                          builder: (ctx, v, _) => FilledButton.icon(
                            onPressed: (noOne ||
                                    (!toHere && picked == null) ||
                                    v.text.trim().isEmpty)
                                ? null
                                : () => Navigator.pop(ctx, true),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open in Messages'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    final text = body.text.trim();
    body.dispose();
    if (go != true || !mounted) return;
    if (toHere) {
      await widget.openHere(text);
      if (!forward) await widget.onReplied();
    } else {
      await openSmsCompose([picked!.phone], body: text);
    }
    if (!mounted) return;
    setState(() {
      _askInfo = 'Opened in Messages with your draft. Send it there.';
      _ask.clear();
    });
  }

  /// "(801) 555-0101" for a 10-digit number; anything else as is.
  static String _prettyPhone(String digits) => digits.length == 10
      ? '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}'
      : digits;

  /// Color and categories change rarely, so they start collapsed to a
  /// one-line summary (the color dot and category chips); tap to edit.
  Widget _colorAndCategories() {
    final theme = Theme.of(context);
    final chosen = [
      for (final c in _categories)
        if (_selected.contains(c.id)) c,
    ];
    final header = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _showStyle = !_showStyle),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Text('Color & categories', style: theme.textTheme.labelMedium),
            const SizedBox(width: 12),
            Expanded(
              child: _showStyle
                  ? const SizedBox.shrink()
                  : Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_color != null)
                          CircleAvatar(
                              radius: 7, backgroundColor: Color(_color!)),
                        for (final c in chosen)
                          _MiniChip(label: c.name, color: Color(c.color)),
                        if (_color == null && chosen.isEmpty)
                          Text('None', style: theme.textTheme.bodySmall),
                      ],
                    ),
            ),
            Icon(_showStyle ? Icons.expand_less : Icons.expand_more),
          ],
        ),
      ),
    );
    if (!_showStyle) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Text('Color', style: theme.textTheme.labelMedium),
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
            Text('Categories', style: theme.textTheme.labelMedium),
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
      ],
    );
  }

  Widget _askBox() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ask,
          enabled: !_asking,
          textInputAction: TextInputAction.send,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _runAsk(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.auto_awesome),
            hintText: 'Ask Threadly: forward, reply, remind, file…',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _asking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Ask',
                    icon: const Icon(Icons.send),
                    onPressed: _runAsk,
                  ),
          ),
        ),
        if (_askInfo != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_askInfo!, style: theme.textTheme.bodySmall),
          ),
        if (_askCategory != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ActionChip(
              avatar: CircleAvatar(
                  radius: 6, backgroundColor: Color(_askCategory!.color)),
              label: Text('Add to ${_askCategory!.name}'),
              onPressed: () async {
                await _toggleCategory(_askCategory!, true);
                if (mounted) {
                  setState(() {
                    _askInfo = 'Added to ${_askCategory!.name}.';
                    _askCategory = null;
                  });
                }
              },
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    widget.suggestion.then((s) {
      if (mounted) setState(() => _suggestion = s);
    });
  }

  /// Tap-to-apply chips for whatever the model suggested that isn't already
  /// set. Applying fills the field / ticks the category; text fields still
  /// need Save, like any edit here. Nickname = a group's topic or a raw
  /// number's person name; the note = what the chat is about.
  Widget _suggestionChips() {
    final s = _suggestion;
    if (s == null) return const SizedBox.shrink();
    final nickname = s.nickname;
    final note = s.note;
    final category =
        _categories.where((c) => c.name == s.category).firstOrNull;
    final chips = <Widget>[
      if (nickname != null && _name.text.trim() != nickname)
        ActionChip(
          avatar: const Icon(Icons.auto_awesome, size: 18),
          label: Text('Nickname: $nickname',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onPressed: () => setState(() => _name.text = nickname),
        ),
      if (note != null && _note.text.trim().isEmpty)
        ActionChip(
          avatar: const Icon(Icons.auto_awesome, size: 18),
          label: Text('Note: $note',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onPressed: () => setState(() => _note.text = note),
        ),
      if (s.remindAt != null &&
          _remindAtMs != s.remindAt!.millisecondsSinceEpoch)
        ActionChip(
          avatar: const Icon(Icons.alarm, size: 18),
          label: Text(
            [
              'Remind ${formatDue(s.remindAt!)}',
              ?s.remindWhat,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => setState(() {
            _remindAtMs = s.remindAt!.millisecondsSinceEpoch;
            _remindWhat = s.remindWhat;
          }),
        ),
      if (category != null && !_selected.contains(category.id))
        ActionChip(
          avatar: CircleAvatar(
              radius: 6, backgroundColor: Color(category.color)),
          label: Text('Add to ${category.name}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onPressed: () => _toggleCategory(category, true),
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 4, children: chips),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _ask.dispose();
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

  /// Pick a reminder time: quick presets or a custom date + time.
  Future<void> _pickReminder() async {
    final when = await pickLater(context,
        current: _remindAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(_remindAtMs!)
            : null);
    if (when == null || !mounted) return;
    setState(() => _remindAtMs = when.millisecondsSinceEpoch);
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.store.setAnnotation(
      widget.conversation.id,
      name: _name.text,
      color: _color,
      note: _note.text,
      remindAtMs: _remindAtMs,
      remindWhat: _remindWhat,
    );
    final when = _remindAtMs != null
        ? DateTime.fromMillisecondsSinceEpoch(_remindAtMs!)
        : null;
    if (when != null && when.isAfter(DateTime.now())) {
      final allowed = await _reminders.ensurePermission();
      if (!allowed) {
        messenger.showSnackBar(const SnackBar(
          content: Text(
              'Notifications are off for Threadly — the reminder won’t show '
              'until you allow them in system settings.'),
        ));
      }
      final nickname = _name.text.trim();
      final note = _note.text.trim();
      await _reminders.schedule(
        widget.conversation.id,
        title: nickname.isNotEmpty
            ? nickname
            : (widget.conversation.title.isEmpty
                ? 'Conversation reminder'
                : widget.conversation.title),
        body: _remindWhat ??
            (note.isNotEmpty
                ? note
                : 'You asked to be reminded about this conversation.'),
        when: when,
      );
    } else {
      // No reminder, or it was cleared/elapsed: drop any pending one.
      await _reminders.cancel(widget.conversation.id);
    }
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
            _askBox(),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Nickname (shown as a subtitle)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            // A raw number: whatever name is in the field can become a
            // contact (the system editor opens prefilled; the user saves
            // there).
            if (widget.rawNumber != null)
              _SaveContactButton(
                name: _name,
                onPressed: () => widget.suggestService
                    .saveContact(_name.text.trim(), widget.rawNumber!),
              ),
            _suggestionChips(),
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
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alarm),
              title: Text(_remindAtMs == null
                  ? 'Remind me'
                  : 'Reminder: ${formatDue(DateTime.fromMillisecondsSinceEpoch(_remindAtMs!))}'),
              subtitle: _remindAtMs == null
                  ? const Text('Get a notification about this conversation')
                  : (_remindWhat != null ? Text(_remindWhat!) : null),
              trailing: _remindAtMs == null
                  ? null
                  : IconButton(
                      tooltip: 'Clear reminder',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _remindAtMs = null;
                        _remindWhat = null;
                      }),
                    ),
              onTap: _pickReminder,
            ),
            const SizedBox(height: 4),
            _colorAndCategories(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onForget();
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Forget conversation'),
              ),
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
