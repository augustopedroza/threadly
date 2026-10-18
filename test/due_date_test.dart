import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/models/due_date.dart';

void main() {
  // Messages "sent" Friday, Oct 16, 2026 at 10:00 AM.
  final ref = DateTime(2026, 10, 16, 10, 0);

  DateTime? due(String words) => parseDueDate(words, ref)?.when;

  test('weekday with a time resolves to the coming one', () {
    expect(due('Saturday at 9am'), DateTime(2026, 10, 17, 9, 0));
    expect(due('sat 9:30 pm'), DateTime(2026, 10, 17, 21, 30));
    expect(due('next Tuesday @ 7:15pm'), DateTime(2026, 10, 20, 19, 15));
  });

  test('same weekday: today if the time is still ahead, else next week', () {
    expect(due('Friday at 6pm'), DateTime(2026, 10, 16, 18, 0));
    expect(due('Friday at 8am'), DateTime(2026, 10, 23, 8, 0));
    expect(due('Friday'), DateTime(2026, 10, 23, 9, 0));
  });

  test('relative days', () {
    expect(due('tomorrow at noon'), DateTime(2026, 10, 17, 12, 0));
    expect(due('tonight'), DateTime(2026, 10, 16, 19, 0));
    expect(due('today at 3'), DateTime(2026, 10, 16, 15, 0));
  });

  test('month names and numeric dates', () {
    expect(due('Oct 20'), DateTime(2026, 10, 20, 9, 0));
    expect(due('October 20th at 4pm'), DateTime(2026, 10, 20, 16, 0));
    expect(due('20 October'), DateTime(2026, 10, 20, 9, 0));
    expect(due('10/31'), DateTime(2026, 10, 31, 9, 0));
    // Already past this year: next year.
    expect(due('Jan 5'), DateTime(2027, 1, 5, 9, 0));
    expect(due('3/1'), DateTime(2027, 3, 1, 9, 0));
  });

  test('day of month', () {
    expect(due('the 20th'), DateTime(2026, 10, 20, 9, 0));
    expect(due('by the 1st'), DateTime(2026, 11, 1, 9, 0));
  });

  test('a time alone is today if still ahead, else tomorrow', () {
    expect(due('at 6pm'), DateTime(2026, 10, 16, 18, 0));
    expect(due('at 8am'), DateTime(2026, 10, 17, 8, 0));
  });

  test('a date without a time defaults to 9 AM and says so', () {
    final d = parseDueDate('Oct 20', ref)!;
    expect(d.hasTime, isFalse);
    expect(parseDueDate('Oct 20 at 5pm', ref)!.hasTime, isTrue);
  });

  test('a day number is never read as a time', () {
    expect(due('Oct 20'), DateTime(2026, 10, 20, 9, 0));
  });

  test('words without a date or time give nothing', () {
    expect(due('soon'), isNull);
    expect(due('next week sometime'), isNull);
    expect(due('Feb 30'), isNull);
  });
}
