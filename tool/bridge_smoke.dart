// Standalone smoke test for the Matrix/bridge read path.
// Run on the Mac (which can reach the homeserver):
//   dart run tool/bridge_smoke.dart
// Prints structure only (titles, counts) — never message bodies.
import 'dart:io';

import 'package:chat_organizer/data/matrix_client.dart';

// Credentials come from the environment so none are committed:
//   BRIDGE_HOMESERVER=… BRIDGE_USER=… BRIDGE_PASSWORD=… dart run tool/bridge_smoke.dart
final homeserver =
    Platform.environment['BRIDGE_HOMESERVER'] ?? 'http://localhost:8008';
final user = Platform.environment['BRIDGE_USER'] ?? 'augusto';
final password = Platform.environment['BRIDGE_PASSWORD'] ?? '';

Future<void> main() async {
  if (password.isEmpty) {
    stderr.writeln('Set BRIDGE_PASSWORD (and optionally BRIDGE_HOMESERVER/'
        'BRIDGE_USER) in the environment.');
    exit(2);
  }
  final client = MatrixClient(homeserver);
  await client.loginWithPassword(user, password);
  stdout.writeln('logged in as ${client.userId}');

  final joined = await client.joinPendingInvites();
  stdout.writeln('accepted $joined pending invites');

  final rooms = await client.loadRooms(timelineLimit: 50);
  final portals = rooms.where((r) => r.isGmessagesPortal).toList();
  stdout.writeln('joined rooms: ${rooms.length}, gmessages portals: '
      '${portals.length}');

  // diagnostics: what does each room's parsed state look like?
  for (final r in rooms.take(5)) {
    final types = <String, int>{};
    for (final e in r.state) {
      types[e.type] = (types[e.type] ?? 0) + 1;
    }
    stdout.writeln('  room ${r.id}  state=${r.state.length} timeline='
        '${r.timeline.length}  bridge=${r.bridge != null} '
        'ghosts=${r.ghosts.length}  types=$types');
  }

  final threads = buildThreads(rooms, client.userId!);
  stdout.writeln('built threads: ${threads.length}\n');

  var withNumbers = 0, withoutNumbers = 0;
  for (final t in threads.take(12)) {
    final named = t.participants.where((p) => p.startsWith('gm:')).length;
    withNumbers += t.participants.length - named;
    withoutNumbers += named;
    final latest = t.latest;
    final when = latest == null ? '—' : latest.date.toIso8601String();
    final bodyLen = latest?.body.length ?? 0;
    stdout.writeln(
      '${t.isGroup ? "GROUP" : "dm   "}  '
      'parts=${t.participants.length.toString().padLeft(2)} '
      '(num=${(t.participants.length - named)} name=$named)  '
      'msgs=${t.messages.length.toString().padLeft(3)}  '
      'last=$when bodyLen=$bodyLen  '
      'title="${_clip(t.title, 48)}"',
    );
  }
  stdout.writeln('\nparticipant keys across shown threads: '
      'phone=$withNumbers, name-only(gm:)=$withoutNumbers');
}

String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
