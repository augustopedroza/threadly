import '../models/thread.dart';
import 'matrix_client.dart';
import 'sms_source.dart';

/// Reads conversations from the mautrix-gmessages bridge over Matrix, so
/// Threadly can see RCS (which the device SMS provider can't). A drop-in
/// [SmsSource] — the UI is unchanged. Sending still goes through the native
/// handoff (this source is read-only).
class GMessagesBridgeSource implements SmsSource {
  final String homeserver;
  final String user;
  final String password;

  MatrixClient? _client;

  GMessagesBridgeSource({
    required this.homeserver,
    required this.user,
    required this.password,
  });

  @override
  bool get canReadThreads => true;

  @override
  bool get needsSmsPermission => false;

  @override
  Future<List<MessageThread>> loadThreads() async {
    final client = _client ??= MatrixClient(homeserver);
    if (client.accessToken == null) {
      await client.loginWithPassword(user, password);
    }
    // Accept invites so newly-bridged chats appear, then load.
    await client.joinPendingInvites();
    final rooms = await client.loadRooms();
    return buildThreads(rooms, client.userId!);
  }
}
