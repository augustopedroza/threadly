import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/category.dart';
import '../models/reply.dart';

/// Local persistence for the app-managed organizing layer:
///  - categories + their members (conversation ids; the column is still named
///    `phone` from the SMS era)
///  - per-conversation annotations (nickname, color, note, reminder), reads,
///    pending groups, and created groups' rosters — all keyed by conversation id
///
/// NOTE: the SQLite tables are still named `groupings` / `grouping_members`
/// (and the `grouping_id` column) for backward compatibility with existing
/// installs — the user-facing concept was renamed to "category", but renaming
/// the tables would require a migration. These names are internal only.
///
/// This store is purely app-owned data; contact names are read separately from
/// the Android Contacts provider (see ContactsService).
class OrganizerStore {
  Database? _db;

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'organizer.db'),
      version: 9,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE groupings(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            color INTEGER NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE grouping_members(
            grouping_id INTEGER NOT NULL,
            phone TEXT NOT NULL,
            PRIMARY KEY(grouping_id, phone),
            FOREIGN KEY(grouping_id) REFERENCES groupings(id) ON DELETE CASCADE
          )''');
        await db.execute('''
          CREATE TABLE conversation_annotations(
            thread_key TEXT PRIMARY KEY,
            name TEXT,
            color INTEGER,
            note TEXT,
            remind_at INTEGER,
            remind_what TEXT
          )''');
        await _createGroupChatTables(db);
        await _createReadsTable(db);
        await _createPendingGroupsTable(db);
        await _createGroupRecipientsTable(db);
        await _createReplyStateTable(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _createGroupChatTables(db);
        if (oldVersion < 3) {
          await db.execute(
              'ALTER TABLE conversation_annotations ADD COLUMN name TEXT');
        }
        if (oldVersion < 4) await _createReadsTable(db);
        if (oldVersion < 5) await _createPendingGroupsTable(db);
        if (oldVersion < 6) await _createGroupRecipientsTable(db);
        if (oldVersion < 7) {
          await db.execute(
              'ALTER TABLE conversation_annotations ADD COLUMN remind_at INTEGER');
        }
        if (oldVersion < 8) {
          await db.execute(
              'ALTER TABLE conversation_annotations ADD COLUMN remind_what TEXT');
        }
        if (oldVersion < 9) await _createReplyStateTable(db);
      },
    );
  }

  /// Saved group-chat rosters under a category (added in schema v2). Dormant:
  /// only the retired legacy editors used them. Kept so the schema and its
  /// migrations stay unchanged for existing installs.
  Future<void> _createGroupChatTables(Database db) async {
    await db.execute('''
      CREATE TABLE group_chats(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        FOREIGN KEY(category_id) REFERENCES groupings(id) ON DELETE CASCADE
      )''');
    await db.execute('''
      CREATE TABLE group_chat_members(
        group_chat_id INTEGER NOT NULL,
        phone TEXT NOT NULL,
        PRIMARY KEY(group_chat_id, phone),
        FOREIGN KEY(group_chat_id) REFERENCES group_chats(id) ON DELETE CASCADE
      )''');
  }

  /// Per-conversation read marker (added in schema v4): the timestamp of the
  /// newest message the user had seen when they last opened the thread. A
  /// conversation is "unread" when a newer incoming message arrives after this.
  Future<void> _createReadsTable(Database db) async {
    await db.execute('''
      CREATE TABLE conversation_reads(
        thread_key TEXT PRIMARY KEY,
        last_read_ms INTEGER NOT NULL
      )''');
  }

  /// Member phone numbers for a group conversation (added in schema v6), so the
  /// group can be reopened via the sms: deep link (which lands on the exact
  /// thread) even with no live notification. Keyed by the conversation id.
  Future<void> _createGroupRecipientsTable(Database db) async {
    await db.execute('''
      CREATE TABLE group_recipients(
        thread_key TEXT PRIMARY KEY,
        members TEXT NOT NULL
      )''');
  }

  /// "To reply" bookkeeping (added in schema v9): when the user marked a
  /// conversation done (its last activity then), and the on-device AI's
  /// verdict on whether its newest message needs an answer.
  Future<void> _createReplyStateTable(Database db) async {
    await db.execute('''
      CREATE TABLE reply_state(
        thread_key TEXT PRIMARY KEY,
        done_at INTEGER,
        verdict_at INTEGER,
        needs_reply INTEGER
      )''');
  }

  /// Group names/categories chosen in the "new group" composer before the group
  /// exists as a conversation (added in schema v5). Matched to the real
  /// conversation by member names once it first appears, then applied + removed.
  Future<void> _createPendingGroupsTable(Database db) async {
    await db.execute('''
      CREATE TABLE pending_groups(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        category_id INTEGER,
        members TEXT NOT NULL
      )''');
  }

  // --- Categories --------------------------------------------------------

  Future<List<Category>> categories() async {
    final db = await _database;
    final rows = await db.query('groupings', orderBy: 'name COLLATE NOCASE');
    return [
      for (final r in rows)
        Category(
          id: r['id'] as int,
          name: r['name'] as String,
          color: r['color'] as int,
        ),
    ];
  }

  /// Create a category, or return the existing one with the same name
  /// (case-insensitive). Idempotent so "adding" never spawns a duplicate.
  Future<Category> createCategory(String name, int color) async {
    final db = await _database;
    final trimmed = name.trim();
    final existing = await db.query(
      'groupings',
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final r = existing.first;
      return Category(
        id: r['id'] as int,
        name: r['name'] as String,
        color: r['color'] as int,
      );
    }
    final id = await db.insert('groupings', {'name': trimmed, 'color': color});
    return Category(id: id, name: trimmed, color: color);
  }

  Future<void> updateCategory(int id, String name, int color) async {
    final db = await _database;
    await db.update(
      'groupings',
      {'name': name, 'color': color},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteCategory(int id) async {
    final db = await _database;
    await db
        .delete('grouping_members', where: 'grouping_id = ?', whereArgs: [id]);
    // Also clear any (dormant, legacy) group-chat rosters under it.
    final chats =
        await db.query('group_chats', columns: ['id'], where: 'category_id = ?', whereArgs: [id]);
    for (final r in chats) {
      await db.delete('group_chat_members',
          where: 'group_chat_id = ?', whereArgs: [r['id']]);
    }
    await db.delete('group_chats', where: 'category_id = ?', whereArgs: [id]);
    await db.delete('groupings', where: 'id = ?', whereArgs: [id]);
  }

  /// category id -> set of member conversation ids.
  Future<Map<int, Set<String>>> allMemberships() async {
    final db = await _database;
    final rows = await db.query('grouping_members');
    final out = <int, Set<String>>{};
    for (final r in rows) {
      (out[r['grouping_id'] as int] ??= <String>{}).add(r['phone'] as String);
    }
    return out;
  }

  Future<void> setMembership(int categoryId, String phone, bool member) async {
    final db = await _database;
    if (member) {
      await db.insert(
        'grouping_members',
        {'grouping_id': categoryId, 'phone': phone},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } else {
      await db.delete(
        'grouping_members',
        where: 'grouping_id = ? AND phone = ?',
        whereArgs: [categoryId, phone],
      );
    }
  }

  // --- Conversation annotations -----------------------------------------

  /// thread key -> annotation.
  Future<Map<String, ConversationAnnotation>> allAnnotations() async {
    final db = await _database;
    final rows = await db.query('conversation_annotations');
    return {
      for (final r in rows)
        r['thread_key'] as String: ConversationAnnotation(
          threadKey: r['thread_key'] as String,
          name: r['name'] as String?,
          color: r['color'] as int?,
          note: r['note'] as String?,
          remindAtMs: r['remind_at'] as int?,
          remindWhat: r['remind_what'] as String?,
        ),
    };
  }

  /// Replace [threadKey]'s annotation. [remindWhat] (what the reminder is
  /// for) is kept from the existing row when not given and the reminder
  /// stays set — so callers that don't know it can't wipe it — and cleared
  /// with the reminder.
  Future<void> setAnnotation(String threadKey,
      {String? name,
      int? color,
      String? note,
      int? remindAtMs,
      String? remindWhat}) async {
    final db = await _database;
    final cleanNote = (note != null && note.trim().isEmpty) ? null : note?.trim();
    final cleanName = (name != null && name.trim().isEmpty) ? null : name?.trim();
    if (color == null &&
        cleanNote == null &&
        cleanName == null &&
        remindAtMs == null) {
      await db.delete('conversation_annotations',
          where: 'thread_key = ?', whereArgs: [threadKey]);
      return;
    }
    var what = (remindWhat != null && remindWhat.trim().isNotEmpty)
        ? remindWhat.trim()
        : null;
    if (remindAtMs == null) {
      what = null;
    } else if (remindWhat == null) {
      final existing = await db.query('conversation_annotations',
          columns: ['remind_what'],
          where: 'thread_key = ?',
          whereArgs: [threadKey],
          limit: 1);
      what = existing.isEmpty ? null : existing.first['remind_what'] as String?;
    }
    await db.insert(
      'conversation_annotations',
      {
        'thread_key': threadKey,
        'name': cleanName,
        'color': color,
        'note': cleanNote,
        'remind_at': remindAtMs,
        'remind_what': what,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Set or clear (null) just [threadKey]'s reminder, keeping its nickname,
  /// color, and note — for snoozing, "save for later", and the reminders
  /// screen. Returns the updated annotation (null if now empty).
  Future<ConversationAnnotation?> setReminder(String threadKey, int? remindAtMs,
      {String? remindWhat}) async {
    final db = await _database;
    final rows = await db.query('conversation_annotations',
        where: 'thread_key = ?', whereArgs: [threadKey], limit: 1);
    final r = rows.isEmpty ? null : rows.first;
    await setAnnotation(threadKey,
        name: r?['name'] as String?,
        color: r?['color'] as int?,
        note: r?['note'] as String?,
        remindAtMs: remindAtMs,
        remindWhat: remindWhat);
    return (await allAnnotations())[threadKey];
  }

  // --- To reply -----------------------------------------------------------

  /// thread key -> reply state.
  Future<Map<String, ReplyState>> allReplyStates() async {
    final db = await _database;
    final rows = await db.query('reply_state');
    return {
      for (final r in rows)
        r['thread_key'] as String: ReplyState(
          doneAtMs: r['done_at'] as int?,
          verdictAtMs: r['verdict_at'] as int?,
          needsReply: switch (r['needs_reply']) {
            1 => true,
            0 => false,
            _ => null,
          },
        ),
    };
  }

  /// Mark [threadKey] done (replied) as of its last activity [atMs], or
  /// undo that (null).
  Future<void> setReplyDone(String threadKey, int? atMs) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('reply_state', {'thread_key': threadKey},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update('reply_state', {'done_at': atMs},
          where: 'thread_key = ?', whereArgs: [threadKey]);
    });
  }

  /// Record the AI's verdict on [threadKey]'s message at [atMs].
  Future<void> setReplyVerdict(String threadKey, int atMs, bool needsReply) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.insert('reply_state', {'thread_key': threadKey},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.update(
          'reply_state', {'verdict_at': atMs, 'needs_reply': needsReply ? 1 : 0},
          where: 'thread_key = ?', whereArgs: [threadKey]);
    });
  }

  Future<void> clearReplyState(String threadKey) async {
    final db = await _database;
    await db.delete('reply_state',
        where: 'thread_key = ?', whereArgs: [threadKey]);
  }

  // --- Read markers ------------------------------------------------------

  /// thread key -> epoch-ms of the newest message seen when last opened.
  Future<Map<String, int>> allReads() async {
    final db = await _database;
    final rows = await db.query('conversation_reads');
    return {
      for (final r in rows)
        r['thread_key'] as String: r['last_read_ms'] as int,
    };
  }

  /// Mark a conversation read up to [whenMs] (the newest message's timestamp).
  Future<void> markRead(String threadKey, int whenMs) async {
    final db = await _database;
    await db.insert(
      'conversation_reads',
      {'thread_key': threadKey, 'last_read_ms': whenMs},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- Pending groups ----------------------------------------------------

  /// Remember a group the user just started in the native app. It shows in the
  /// list as a launchable placeholder and carries an optional name/category, all
  /// applied to the real conversation once it first appears. [members] are
  /// normalized phones.
  Future<void> createPendingGroup({
    String? name,
    int? categoryId,
    required List<String> members,
  }) async {
    if (members.isEmpty) return;
    final db = await _database;
    final cleanName = (name != null && name.trim().isNotEmpty) ? name.trim() : null;
    await db.insert('pending_groups', {
      'name': cleanName,
      'category_id': categoryId,
      'members': members.join(','),
    });
  }

  Future<List<({int id, String? name, int? categoryId, List<String> members})>>
      pendingGroups() async {
    final db = await _database;
    final rows = await db.query('pending_groups');
    return [
      for (final r in rows)
        (
          id: r['id'] as int,
          name: r['name'] as String?,
          categoryId: r['category_id'] as int?,
          members: (r['members'] as String)
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
    ];
  }

  Future<void> updatePendingGroup(int id,
      {String? name, int? categoryId}) async {
    final db = await _database;
    final cleanName = (name != null && name.trim().isNotEmpty) ? name.trim() : null;
    await db.update(
      'pending_groups',
      {'name': cleanName, 'category_id': categoryId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePendingGroup(int id) async {
    final db = await _database;
    await db.delete('pending_groups', where: 'id = ?', whereArgs: [id]);
  }

  // --- Group recipients --------------------------------------------------

  /// conversation id -> member phone numbers, for reopening a group thread via
  /// the sms: deep link.
  Future<Map<String, List<String>>> allGroupRecipients() async {
    final db = await _database;
    final rows = await db.query('group_recipients');
    return {
      for (final r in rows)
        r['thread_key'] as String: (r['members'] as String)
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
    };
  }

  Future<void> setGroupRecipients(String threadKey, List<String> members) async {
    if (members.isEmpty) return;
    final db = await _database;
    await db.insert(
      'group_recipients',
      {'thread_key': threadKey, 'members': members.join(',')},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearGroupRecipients(String threadKey) async {
    final db = await _database;
    await db
        .delete('group_recipients', where: 'thread_key = ?', whereArgs: [threadKey]);
  }
}
