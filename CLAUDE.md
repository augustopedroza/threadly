# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**ChatOrganizer** — a Flutter Android app that is a "thin layer" over the user's existing texts.
It reads SMS conversations and lets the user **organize** them (categories, custom nicknames, colors,
notes, saved group-chat rosters), then **hands off to the native Messages app** for all sending. It
also reads contact names (read-only) to show them over raw numbers. The pitch: organize here,
send/read in the app you already use.

Currently **Android-only**. The iOS path is designed-for but not built (see "The defining
constraint").

## The defining constraint (read before changing data/platform code)

"Group texts" are three incompatible, gatekept systems:

- **SMS/MMS** — Android can read (with SMS permissions). iOS cannot read at all.
- **iMessage** — no third-party read/send anywhere.
- **RCS** — closed on every platform.

So the app is **asymmetric by design**: a reader+organizer on Android, and on iOS a degraded
companion (no thread reading — only assisted-send/deep-links). Do not attempt to read texts on iOS.

**This app never sends via `SmsManager` and holds no `SEND_SMS` permission.** A non-default SMS app
cannot write to the SMS provider, so any message it "sent" would never appear in Google Messages.
Instead, **all sending is a handoff**: an `sms:recipient1,recipient2?body=...` deep link opens the
user's default Messages app (group compose for multiple recipients). This handoff is the product's
core idea, not a fallback. See `lib/messaging.dart`.

Known sharp edge: group **MMS** recipient lists are not fully reconstructed from the SMS provider
alone via `another_telephony`. `AndroidSmsSource` derives participants from incoming SMS addresses
grouped by `THREAD_ID`. Escalating to a custom MMS content-provider query or becoming the default
SMS app remains an open decision gate.

## Two "grouping" concepts — do not conflate

The app has two app-owned ways to associate people, both stored in its own SQLite DB:

1. **Category** (`models/category.dart` `Category`) — a bucket of people (e.g. "LDS", "U17 Team").
   Classifies both individual and group conversations and **drives the tabs**. Members are phone
   numbers.
2. **Group chat** (`GroupChat`) — a named, saved roster of people *under a category* (e.g. "U17
   Parents Carpool"). Launchable as a native group text. **Not** an SMS thread.

Plus **conversation annotations** (`ConversationAnnotation`): per-thread custom **nickname**, color,
and note, keyed by `MessageThread.participantKey`. The nickname shows as a *subtitle* — it does
**not** replace the title (deliberate, per user feedback).

Contact **labels** (Android contact groups) were intentionally removed: they're account-bound (fail
on accountless devices) and only duplicated what categories already do better. Contacts are now
**read-only**, used solely to resolve a phone number to a display name (`data/contacts.dart`).

## Architecture

The UI talks only to platform-agnostic domain types; platform/storage access lives behind
interfaces so iOS can be slotted in without touching the UI.

- `lib/models/thread.dart` — `MessageThread` / `Message`, and the top-level `normalizePhone(raw)`
  (digits-only, last 10) — the canonical key for matching numbers across SMS, categories, and
  labels. `isGroup` = >1 participant; `participantKey` is the order-independent grouping/annotation
  key; messages are newest-first (`latest` = first).
- `lib/data/sms_source.dart` — `SmsSource` interface (`canReadThreads`, `loadThreads`).
  `AndroidSmsSource` reads inbox+sent via `another_telephony`, buckets by `THREAD_ID`. **A future
  `IosSmsSource` must throw on `loadThreads`.** Keep all read-platform branching here.
- `lib/data/organizer_store.dart` — `OrganizerStore`, the app-owned SQLite store (categories +
  members, group chats + members, conversation annotations). **The SQLite tables are still named
  `groupings` / `grouping_members` / `grouping_id`** for back-compat — "grouping" was renamed to
  "category" in the UI but the tables weren't migrated. These names are internal only; do not
  surface "grouping" in UI. `createCategory` is **idempotent by name** (case-insensitive) so adding
  a member never spawns a duplicate category.
- `lib/data/contacts.dart` — `ContactsService` + immutable `ContactsSnapshot`, the read-only
  Contacts-provider side: maps normalized phone → contact display name (`nameForPhone`, `titleFor`).
- `lib/messaging.dart` — the handoff: `openSmsCompose(recipients, {body})` builds the `sms:` URI;
  `launchGroupText(context, recipients)` warns first if `recipients.length > kGroupTextWarnLimit`
  (20, a soft MMS cap) then composes.
- `lib/main.dart` — UI entry. `ThreadListScreen` ("Chats") requests SMS permission, loads threads +
  all organizing data, renders an "All" tab plus one tab per category. A category tab shows its
  saved **group chats** then its **conversations**. `ThreadScreen` is the conversation view; its
  compose bar and "Open in Messages" both route through `lib/messaging.dart`.
- `lib/ui/` — `organize_sheet.dart` (the per-conversation organize modal: name/color/note +
  category & label toggles), `manage_categories_screen.dart`, `edit_category_screen.dart` (also
  hosts a category's group chats), `group_chat_editor_screen.dart`.

### SQLite schema (organizer.db, version 3)

`onCreate` builds everything; `onUpgrade` migrates: `<2` adds the group-chat tables, `<3` adds the
`name` column to `conversation_annotations`. **Bump `version` and add an `onUpgrade` branch for any
schema change** — existing installs carry real user data.

Android permissions (`READ_SMS`/`RECEIVE_SMS`/`READ_CONTACTS`, **no SEND_SMS, no WRITE_CONTACTS**)
and the `sms:` `<queries>` entry live in `android/app/src/main/AndroidManifest.xml`. The Android
`applicationId` is still `com.augusto.group_chat` (kept through the rename so installs/data persist
— do not change it).

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

A **plugged-in Android device or emulator** is required to exercise the SMS read path, contact-name
resolution, and the `sms:` handoff — macOS/Chrome/iOS targets can't. Note an **emulator quirk**:
contact groups can't be created on an accountless emulator (Android groups are account-bound) — this
is partly why contact labels were dropped. The app's own SQLite-backed organizing (categories,
nicknames, colors, group chats) works fully on an emulator with seeded SMS, no account needed.
