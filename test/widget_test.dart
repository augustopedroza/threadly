import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/models/category.dart';
import 'package:chat_organizer/models/thread.dart';

void main() {
  test('a thread with multiple participants is a group', () {
    final group = MessageThread(
      participants: ['+15551112222', '+15553334444'],
      messages: const [],
    );
    final direct = MessageThread(
      participants: ['+15551112222'],
      messages: const [],
    );

    expect(group.isGroup, isTrue);
    expect(direct.isGroup, isFalse);
  });

  test('participantKey is order-independent', () {
    final a = MessageThread(
      participants: ['+1222', '+1111'],
      messages: const [],
    );
    final b = MessageThread(
      participants: ['+1111', '+1222'],
      messages: const [],
    );

    expect(a.participantKey, equals(b.participantKey));
  });

  test('latest returns the first message (newest-first ordering)', () {
    final now = DateTime(2026, 6, 14, 12);
    final earlier = DateTime(2026, 6, 14, 9);
    final thread = MessageThread(
      participants: ['+1111'],
      messages: [
        Message(body: 'newest', address: '+1111', date: now, isIncoming: true),
        Message(
            body: 'older', address: '+1111', date: earlier, isIncoming: true),
      ],
    );

    expect(thread.latest?.body, equals('newest'));
  });

  test('an annotation with only a reminder is not empty', () {
    const bare = ConversationAnnotation(threadKey: 'k');
    const reminded = ConversationAnnotation(threadKey: 'k', remindAtMs: 1000);

    expect(bare.isEmpty, isTrue);
    expect(reminded.isEmpty, isFalse);
  });
}
