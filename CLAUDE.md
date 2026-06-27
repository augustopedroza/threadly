# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Threadly** — a Flutter Android app that is a "thin layer" (an organizer + launcher) over the
user's existing texts. It does **not** read message content. It learns which conversations exist and
when they last got a message, lets the user **organize** them (categories, custom nicknames, colors,
notes, group rosters), then **hands off to Google Messages** for all reading and sending. It also
reads contact names/photos (read-only) to show them over raw numbers. The pitch: organize here,
read/send in the app you already use.

Currently **Android-only**, and on Android intentionally **content-free**. iOS is not viable for the
core features (see "The defining constraint").

## The defining constraint (read before changing data/platform code)

"Group texts" are three incompatible, gatekept systems — **SMS/MMS**, **iMessage**, **RCS** — and on
a modern Pixel most threads are **RCS, which no third-party app can read**. So Threadly does not read
message content at all. Instead, the Android "source" is a **`NotificationListenerService`** that
observes **Google Messages' notifications** purely as a *signal*: a conversation exists, its title,
its last-activity time, and whether it's unread. It posts no notifications of its own. This requires
the user to grant **notification access**.

Consequences baked into the design:

- The conversation list is **incremental** — a conversation appears only after Google Messages posts
  a notification for it (i.e. an *incoming* message while GM is **not** foregrounded). Send-only or
  foreground/muted conversations are invisible.
- Notifications expose the group **name and flag** but **not the membership**, and the exact-thread
  `contentIntent` is a **notification trampoline Android 12+ blocks** for third-party apps. So an
  incoming group can be detected and named but **can't be deep-linked**; tapping it opens the GM
  inbox. Only groups **created in Threadly** (whose full roster we captured) deep-link to the thread.

**iOS is not viable** for the parts that matter: iOS forbids reading other apps' notifications or the
Messages store, so unread state, recency, and the auto-built list are impossible. iOS could only be a
manual organizer + `sms:` launcher.

**This app never sends via `SmsManager` and holds no `SEND_SMS` permission.** **All sending is a
handoff**: an `sms:recipient1,recipient2?body=...` deep link opens Google Messages (group compose for
multiple recipients). This handoff is the product's core idea, not a fallback. See `lib/messaging.dart`.

> Legacy: a prior approach read RCS via a mautrix-gmessages + Synapse **bridge** on a Mac (and before
> that the on-device SMS provider). Both were retired in favor of the notification listener. The old
> bridge/SMS code (`lib/data/matrix_client.dart`, `gmessages_source.dart`, `sms_source.dart`,
> `bridge_config.dart`, `lib/main.dart`'s `ThreadListScreen`, `bridge/`, `tool/bridge_smoke.dart`)
> remains in the tree but is **unused** by the mainline app.

## Two "grouping" concepts — do not conflate

The app has two app-owned ways to associate people, both stored in its own SQLite DB:

1. **Category** (`models/category.dart` `Category`) — a bucket of people (e.g. "LDS", "U17 Team").
   Classifies both individual and group conversations and **drives the tabs**. Members are phone
   numbers.
2. **Group chat** (`GroupChat`) — a named, saved roster of people *under a category* (e.g. "U17
   Parents Carpool"). Launchable as a native group text. **Not** an SMS thread.

Plus **conversation annotations** (`ConversationAnnotation`): per-conversation custom **nickname**,
color, and note. On the notification path these (and category membership, reads, recipients) key by
the **conversation id**, not a phone-derived key. The nickname shows as a *subtitle* — it does
**not** replace the title (deliberate, per user feedback).

Contact **labels** (Android contact groups) were intentionally removed: they're account-bound (fail
on accountless devices) and only duplicated what categories already do better. Contacts are now
**read-only**, used solely to resolve a phone number to a display name (`data/contacts.dart`).

## Architecture

Mainline (notification-driven) pieces:

- `android/.../ConversationNotificationListener.kt` — the `NotificationListenerService`. Watches
  Google Messages notifications and persists, per conversation, `{title, ts, group}` plus an active
  (= unread) set in SharedPreferences. Holds each active notification's `contentIntent` for
  exact-thread launch (when present). Detects a group via GM's group flag / conversation title /
  multiple distinct senders. Exposes `conversationsJson`, `launch(id)`, `forget(id)`,
  `openMessagesApp` over a `MethodChannel("threadly/notifications")` (wired in `MainActivity.kt`).
- `lib/data/notifications.dart` — `NotificationConversationsService` (channel wrapper) +
  `Conversation` model `{id, title, lastActivity, unread, isGroup}`. No message content.
- `lib/ui/conversations_screen.dart` — `ConversationsScreen`, the **home** (set in `main.dart`).
  Permission onboarding; list sorted by recency with avatars, unread dot, nickname/note/category;
  tabs (All + categories); search; tap → handoff; long-press → organize; swipe → forget.
  Hosts the New Group flow and inline organize sheet. Tapping resolves the open target: 1:1 →
  `sms:` to the contact number; created group → `sms:` to its saved roster (2+); else open GM inbox.
- `lib/ui/new_group_screen.dart` — pick people + optional name/category → `launchGroupText` + store a
  **pending group**, applied to the real conversation when it appears.
- `lib/ui/category_manager_screen.dart` — add/rename/recolor/delete categories.
- `lib/data/organizer_store.dart` — `OrganizerStore`, the app-owned SQLite store. **Tables are still
  named `groupings` / `grouping_members` / `grouping_id`** for back-compat ("grouping" → "category"
  in UI only; don't surface "grouping"). On the notification path, annotations, reads, category
  membership, pending groups, and group recipients are all keyed by the **conversation id**.
  `createCategory` is **idempotent by name** (case-insensitive).
- `lib/data/contacts.dart` — `ContactsService` + immutable `ContactsSnapshot`: normalized phone →
  name (`nameForPhone`, `titleFor`), photo (`photoForTitle`), name → number (`phoneForName`), and a
  `people` list for the New Group picker. Read-only.
- `lib/messaging.dart` — the handoff: `openSmsCompose(recipients, {body})`; `launchGroupText(context,
  recipients)` warns if `recipients.length > kGroupTextWarnLimit` (20).
- `lib/models/category.dart` / `models/thread.dart` — `Category` / `GroupChat` /
  `ConversationAnnotation` / `Person`, and `normalizePhone(raw)` (digits-only, last 10).

Legacy (in tree, **unused** by the mainline): `lib/main.dart`'s `ThreadListScreen`/`ThreadScreen`,
`lib/data/sms_source.dart`, `gmessages_source.dart`, `matrix_client.dart`, `bridge_config.dart`,
`lib/ui/{manage_categories_screen,edit_category_screen,group_chat_editor_screen}.dart`, `bridge/`.

### SQLite schema (organizer.db, version 6)

`onCreate` builds everything; `onUpgrade` migrates: `<2` group-chat tables, `<3` `name` column on
`conversation_annotations`, `<4` `conversation_reads`, `<5` `pending_groups` (name/category for a
group started before it exists, applied + removed on first appearance), `<6` `group_recipients`
(a created group's full member numbers, for `sms:` reopen). **Bump `version` and add an `onUpgrade`
branch for any schema change** — existing installs carry real user data.

`android/app/src/main/AndroidManifest.xml`: the `ConversationNotificationListener` service
(`BIND_NOTIFICATION_LISTENER_SERVICE`), permissions (`READ_CONTACTS`; `READ_SMS`/`RECEIVE_SMS`/
`INTERNET` linger from the legacy paths — **no SEND_SMS, no WRITE_CONTACTS**), and `<queries>` for
the `sms:` scheme + the Google Messages package. The `applicationId` is still
`com.augusto.group_chat` (kept through the rename — do not change it).

## Commands

The Flutter SDK here is at `/Users/acmcp/dev/flutter/bin/flutter` (may not be on PATH; Flutter
3.41.2 / Dart 3.11).

```bash
flutter pub get                 # install deps
flutter analyze                 # lint (must be clean; flutter_lints / analysis_options.yaml)
flutter test                    # run all unit tests
flutter test test/widget_test.dart --plain-name "is a group"   # run a single test by name
flutter run                     # run on a connected device/emulator
flutter build apk --debug       # verify the full Android native stack compiles
```

## Verification reality

`flutter analyze`, `flutter test`, and the debug APK build are the CI-equivalent checks and must
pass. The unit tests cover only the pure-Dart model (`test/widget_test.dart`); everything
platform-bound is verified by running the app.

A **plugged-in Android device or emulator** is required to exercise the notification source,
contact resolution, and the `sms:` handoff — macOS/Chrome/iOS targets can't. The conversation list
only populates once **notification access** is granted and Google Messages posts notifications; the
Pixel API 35 emulator has Google Messages with seeded conversations, so the list, unread dots,
recency, categories, search, swipe-delete, and the handoff are all testable there. Grant access fast
via `adb shell cmd notification allow_listener com.augusto.group_chat/com.augusto.group_chat.ConversationNotificationListener`.
Real **group detection** and **contact photos** need a real device (the emulator's synthetic
notifications/contacts lack those signals). The app's SQLite-backed organizing works fully on an
emulator, no account needed.
