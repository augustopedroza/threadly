# Threadly

An organizer for your text conversations on Android. Threadly sits on top of
**Google Messages**: it lists your conversations, lets you sort them into
categories and annotate them, and hands off to Google Messages whenever you
want to read or reply.

**Organize here, read and send in the app you already use.**

## What it does

- **One list of your conversations**, newest first, with contact names and
  photos, an unread dot, and a one-line preview of the last message you received.
- **Categories** (e.g. "Family", "Soccer", "U17 Team") that become tabs, so a
  busy inbox splits into the groups of people you actually think in.
- **Per-conversation notes**: a nickname, a color, a free-text note, and a
  **reminder** that notifies you about a conversation at a time you pick.
- **Open the exact thread** in Google Messages with one tap, including RCS
  group chats.
- **Get back in one tap**: an optional floating "Threadly" button over
  Google Messages returns you to the list where you left it, with the
  conversation you came from highlighted.
- **Start group texts** from your contacts, named and filed under a category
  before the first message is even sent.
- **Search** by name, nickname, note, or category.

## How it works (and what it can't see)

Most texts on a modern Android phone are **RCS**, and no third-party app can
read the RCS message store. So Threadly never reads messages. It uses
**notification access** to observe Google Messages' notifications, which
carry a conversation's name, when it last got a message, whether it's unread,
and the text of the latest incoming message.

That design has some consequences:

- A conversation appears in Threadly **after it receives a message** while
  Threadly is installed. Conversations where you only ever send aren't seen.
- The preview is the last **incoming** message (sending doesn't post a
  notification).
- Threadly **never sends** anything. Composing and sending always happen in
  Google Messages, so every message lands in your real history.

**Android only.** iOS doesn't let apps read other apps' notifications or the
Messages store, so the core features aren't possible there.

## Permissions

| Permission | Why |
|---|---|
| Notification access | Learn about conversations from Google Messages' notifications |
| Contacts (read-only) | Show names and photos instead of phone numbers |
| Notifications, alarms & reminders | The reminders you set on conversations |
| Display over other apps (optional) | The floating "back to Threadly" button |

No SMS permissions and no internet access. Everything Threadly stores
(categories, notes, reminders) stays on the device.

## Requirements

- Android with **Google Messages** as the messaging app
- Flutter 3.41 / Dart 3.11 to build

## Build and run

```bash
flutter pub get
flutter run                 # on a connected device or emulator
flutter build apk --release
```

On first launch, grant notification access when prompted. The list fills in as
new messages arrive.

Checks (all must pass):

```bash
flutter analyze
flutter test
flutter build apk --debug
```

Most behavior is platform-bound, so test on a real device or the Pixel
emulator. [CLAUDE.md](CLAUDE.md) covers the architecture, the data model, the
Google Messages deep-link details, and device-testing tips.
