import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/models/later.dart';

void main() {
  Map<String, DateTime> presets(DateTime now) =>
      {for (final o in laterPresets(now)) o.label: o.when};

  test('a weekday morning offers everything', () {
    // Wednesday, Oct 14, 2026, 10:30:45.
    final p = presets(DateTime(2026, 10, 14, 10, 30, 45));
    expect(p['In 1 hour'], DateTime(2026, 10, 14, 11, 30));
    expect(p['This evening'], DateTime(2026, 10, 14, 18, 0));
    expect(p['Tomorrow morning'], DateTime(2026, 10, 15, 9, 0));
    expect(p['This weekend'], DateTime(2026, 10, 17, 9, 0));
    expect(p['Next week'], DateTime(2026, 10, 19, 9, 0));
  });

  test('late in the day drops "this evening"', () {
    final p = presets(DateTime(2026, 10, 14, 17, 30));
    expect(p.containsKey('This evening'), isFalse);
    expect(p['In 1 hour'], DateTime(2026, 10, 14, 18, 30));
  });

  test('Friday: the weekend is tomorrow, so it is not repeated', () {
    final p = presets(DateTime(2026, 10, 16, 9, 0));
    expect(p.containsKey('This weekend'), isFalse);
    expect(p['Tomorrow morning'], DateTime(2026, 10, 17, 9, 0));
    expect(p['Next week'], DateTime(2026, 10, 19, 9, 0));
  });

  test('Saturday: next week is Monday; no "this weekend"', () {
    final sat = presets(DateTime(2026, 10, 17, 9, 0));
    expect(sat.containsKey('This weekend'), isFalse);
    expect(sat['Next week'], DateTime(2026, 10, 19, 9, 0));
  });

  test('Sunday: Monday is tomorrow morning, so neither extra repeats it', () {
    final sun = presets(DateTime(2026, 10, 18, 8, 48));
    expect(sun.containsKey('This weekend'), isFalse);
    expect(sun.containsKey('Next week'), isFalse);
    expect(sun['Tomorrow morning'], DateTime(2026, 10, 19, 9, 0));
    expect(sun['This evening'], DateTime(2026, 10, 18, 18, 0));
  });

  test('Thursday still offers this weekend', () {
    final thu = presets(DateTime(2026, 10, 15, 12, 0));
    expect(thu['This weekend'], DateTime(2026, 10, 17, 9, 0));
  });

  test('on a Monday, next week is a week out', () {
    final p = presets(DateTime(2026, 10, 19, 8, 0));
    expect(p['Next week'], DateTime(2026, 10, 26, 9, 0));
  });

  test('crosses month and year boundaries', () {
    final p = presets(DateTime(2026, 12, 31, 23, 30));
    expect(p['In 1 hour'], DateTime(2027, 1, 1, 0, 30));
    expect(p['Tomorrow morning'], DateTime(2027, 1, 1, 9, 0));
  });

  test('notification snooze times', () {
    final now = DateTime(2026, 10, 14, 10, 30);
    expect(snoozeAnHour(now), DateTime(2026, 10, 14, 11, 30));
    expect(snoozeTomorrow(now), DateTime(2026, 10, 15, 9, 0));
  });
}
