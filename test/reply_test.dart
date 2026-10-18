import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/models/reply.dart';

void main() {
  final now = DateTime(2026, 10, 18, 12, 0);
  final last = DateTime(2026, 10, 18, 9, 0);
  final at = last.millisecondsSinceEpoch;

  bool shows({
    DateTime? lastActivity,
    bool lastFromMe = false,
    String? preview = 'Can you pick up Ava at 5?',
    ReplyState state = ReplyState.none,
  }) =>
      belongsInToReply(
        lastActivity: lastActivity ?? last,
        lastFromMe: lastFromMe,
        preview: preview,
        state: state,
        now: now,
      );

  test('a recent incoming message shows until judged', () {
    expect(shows(), isTrue);
  });

  test('the AI can rule it out, but only for that message', () {
    expect(shows(state: ReplyState(verdictAtMs: at, needsReply: false)), isFalse);
    expect(shows(state: ReplyState(verdictAtMs: at, needsReply: true)), isTrue);
    // A verdict for an older message doesn't apply to a newer one.
    expect(
        shows(state: ReplyState(verdictAtMs: at - 60000, needsReply: false)),
        isTrue);
  });

  test('done hides it until a newer message arrives', () {
    expect(shows(state: ReplyState(doneAtMs: at)), isFalse);
    expect(
        shows(
            lastActivity: last.add(const Duration(minutes: 5)),
            state: ReplyState(doneAtMs: at)),
        isTrue);
  });

  test('a reply Threadly saw, reactions, and empty previews are out', () {
    expect(shows(lastFromMe: true), isFalse);
    expect(shows(preview: '👍 to “Let me see if we can help”'), isFalse);
    expect(shows(preview: '❤️ to "See you there"'), isFalse);
    expect(shows(preview: null), isFalse);
    expect(shows(preview: '  '), isFalse);
  });

  test('older than a week is out', () {
    expect(shows(lastActivity: now.subtract(const Duration(days: 8))), isFalse);
    expect(shows(lastActivity: now.subtract(const Duration(days: 6))), isTrue);
  });

  test('looksLikeReaction only matches the reaction format', () {
    expect(looksLikeReaction('👍 to “U14 4-0”'), isTrue);
    expect(looksLikeReaction('Talk to “Mom” first'), isFalse);
    expect(looksLikeReaction('Are you going to the game?'), isFalse);
  });

  test('needsVerdict tracks the newest message', () {
    expect(needsVerdict(lastActivity: last, state: ReplyState.none), isTrue);
    expect(
        needsVerdict(
            lastActivity: last,
            state: ReplyState(verdictAtMs: at, needsReply: true)),
        isFalse);
  });
}
