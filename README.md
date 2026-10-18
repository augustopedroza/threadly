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
- **Save for later**: swipe a conversation right and pick a time (in an hour,
  this evening, tomorrow morning, this weekend, next week, or any date). You'll
  be reminded then; the notification can snooze it for an hour or until
  tomorrow without opening the app.
- **Reminders in one place**: the alarm icon lists every reminder, due and
  upcoming, with what each is for. Open, reschedule, or clear from there.
- **To reply**: a tab of recent messages that look like they need an answer
  from you (the on-device AI skips "ok thanks" and reactions). Threadly can't
  see what you send from Google Messages, so swipe a chat left when it's
  handled; replying through Threadly clears it too, and a new message brings
  it back.
- **Open the exact thread** in Google Messages with one tap, including RCS
  group chats.
- **Get back in one tap**: an optional floating "Threadly" button over
  Google Messages returns you to the list where you left it, with the
  conversation you came from highlighted. It appears whenever you open a
  chat from Threadly, and also when you open one by tapping a Google
  Messages notification, so a new text is one tap from being filed.
- **Start group texts** from your contacts, named and filed under a category
  before the first message is even sent.
- **Smart suggestions, on your phone**: from a conversation's recent messages,
  Threadly suggests a nickname (a group's main topic, or the person's name when
  an unknown number introduces themselves), a note on what the chat is about,
  which of your categories it fits, and a **reminder** when someone mentions an
  upcoming date ("practice Saturday at 9am"). For an unknown number it can also
  offer to **save the person to your contacts**. Nothing is saved until you
  confirm.
- **Ask Threadly**: tell it what to do in plain words, typed or spoken with
  your keyboard's mic. "Forward this to Steve Winters, say it's from Adam",
  "tell them I'm running late", "remind me Friday at 5", "put this in
  Soccer". It works on your phone with the same on-device AI, shows you exactly
  what it will do, and opens Google Messages with the draft ready to send.
- **Search** by name, nickname, note, or category.

## How it works (and what it can't see)

Most texts on a modern Android phone are **RCS**, and no third-party app can
read the RCS message store. So Threadly never reads your message history. It
uses **notification access** to observe Google Messages' notifications, which
carry a conversation's name, when it last got a message, whether it's unread,
and the text of the latest few messages. Threadly keeps the last 10 per
conversation, on the phone only, for its suggestions.

Suggestions run on **Gemini Nano, the AI built into recent Android phones**
(through Android's AICore). It works offline, costs nothing, and your
messages never leave the device. On phones without it, everything else works
the same; you just don't get suggestions.

That design has some consequences:

- A conversation appears in Threadly **after it receives a message** while
  Threadly is installed. Conversations where you only ever send aren't seen.
- The preview is the last **incoming** message (sending doesn't post a
  notification).
- Threadly **never sends** anything. Composing and sending always happen in
  Google Messages, so every message lands in your real history.
- Suggestions start from what's in the notifications, so they get better as
  new messages arrive after install.

**Android only.** iOS doesn't let apps read other apps' notifications or the
Messages store, so the core features aren't possible there.

## Permissions

| Permission | Why |
|---|---|
| Notification access | Learn about conversations from Google Messages' notifications |
| Contacts (read-only) | Show names and photos instead of phone numbers |
| Notifications, alarms & reminders | The reminders you set on conversations |
| Display over other apps (optional) | The floating "back to Threadly" button, shown over Google Messages after you open a chat from Threadly or from a notification |

No SMS permissions, no internet access, and no permission to change your
contacts: "Save to contacts" opens Android's own contact screen, already
filled in, for you to confirm. Everything Threadly stores (categories, notes,
reminders, recent messages) stays on the device.

## Requirements

- Android 8.0 or later, with **Google Messages** as the messaging app
- For suggestions: a phone with Gemini Nano (e.g. Pixel 9 and 10 series). The
  model downloads once, in a few minutes, the first time it's used.
- Flutter 3.41 / Dart 3.11 to build

## Download

Every push to `main` builds a signed APK on GitHub Actions: open the run under
**Actions → Android** and download **threadly-apk** from its Artifacts.
Tagged versions (`v1.2.0`) are also published under **Releases** with the APK
attached. Each build installs over the previous one.

To cut a release:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

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
