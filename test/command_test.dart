import 'package:flutter_test/flutter_test.dart';

import 'package:chat_organizer/data/contacts.dart';
import 'package:chat_organizer/models/command.dart';

void main() {
  group('forwardBody', () {
    test('uses the lead-in the user asked for', () {
      expect(forwardBody('Practice moved to 6', note: 'From Adam'),
          'From Adam: “Practice moved to 6”');
      expect(forwardBody('ok', note: 'from the coach:'), 'From the coach: “ok”');
    });

    test('credits the original sender when no lead-in is given', () {
      expect(forwardBody('See you there', sender: 'Tami'),
          'From Tami: “See you there”');
      expect(forwardBody('See you there', sender: 'Me'), 'Fwd: “See you there”');
      expect(forwardBody('See you there'), 'Fwd: “See you there”');
    });
  });

  group('ThreadlyCommand.fromMap', () {
    test('THIS means the conversation itself', () {
      final c = ThreadlyCommand.fromMap(
          {'action': 'REPLY', 'to': 'THIS', 'text': "I'll be late"})!;
      expect(c.action, CommandAction.reply);
      expect(c.to, isNull);
      expect(c.text, "I'll be late");
    });

    test('unknown actions give nothing', () {
      expect(ThreadlyCommand.fromMap({'action': 'DANCE'}), isNull);
      expect(ThreadlyCommand.fromMap({}), isNull);
    });
  });

  group('matchPeople', () {
    const snap = ContactsSnapshot(
      available: true,
      phoneToName: {},
      people: [
        (phone: '8015550101', display: 'Steve Winters'),
        (phone: '8015550102', display: 'Steve Boyack'),
        (phone: '8015550103', display: 'Maria Luiza Pedroza'),
        (phone: '8015550104', display: 'Tami'),
      ],
    );
    List<String> names(String q) => [for (final p in snap.matchPeople(q)) p.display];

    test('a full name picks that person', () {
      expect(names('Steve Winters'), ['Steve Winters']);
      expect(names('steve winters'), ['Steve Winters']);
    });

    test('a first name can be ambiguous', () {
      expect(names('Steve'), ['Steve Winters', 'Steve Boyack']);
    });

    test('word prefixes in any order match', () {
      expect(names('Winters'), ['Steve Winters']);
      expect(names('maria pedroza'), ['Maria Luiza Pedroza']);
      expect(names('Tami'), ['Tami']);
    });

    test('no match gives an empty list', () {
      expect(names('Bob'), isEmpty);
      expect(names(''), isEmpty);
    });
  });
}
