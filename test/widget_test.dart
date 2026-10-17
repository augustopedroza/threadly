import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/models/category.dart';
import 'package:chat_organizer/models/phone.dart';

void main() {
  test('normalizePhone keeps the last 10 digits, ignoring formatting', () {
    expect(normalizePhone('+1 (801) 555-0123'), equals('8015550123'));
    expect(normalizePhone('801.555.0123'), equals('8015550123'));
    expect(normalizePhone('18015550123'), equals('8015550123'));
  });

  test('normalizePhone leaves short codes as their digits', () {
    expect(normalizePhone('72727'), equals('72727'));
    expect(normalizePhone(''), isEmpty);
  });

  test('an annotation with only a reminder is not empty', () {
    const bare = ConversationAnnotation(threadKey: 'k');
    const reminded = ConversationAnnotation(threadKey: 'k', remindAtMs: 1000);

    expect(bare.isEmpty, isTrue);
    expect(reminded.isEmpty, isFalse);
  });
}
