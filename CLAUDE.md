# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Threadly** — a Flutter Android app that is a "thin layer" (an organizer + launcher) over the
user's existing texts. It learns which conversations exist and when they last got a message, keeps a
one-line **last-message preview** for each, lets the user **organize** them (categories, custom
nicknames, colors, notes, reminders, group rosters), then **hands off to Google Messages** for all reading and
sending. It also reads contact names/photos (read-only) to show them over raw numbers. The pitch:
organize here, read/send in the app you already use.

The **only** message content Threadly keeps is that last-message preview, and it comes straight from
the Google Messages **notification** (never a message store), so it works across SMS/MMS/RCS alike. It
does not read message *history* or thread bodies. Currently **Android-only**; iOS is not viable for
the core features (see "The defining constraint").

## The defining constraint (read before changing data/platform code)

"Group texts" are three incompatible, gatekept systems — **SMS/MMS**, **iMessage**, **RCS** — and on
a modern Pixel most threads are **RCS, whose message store no third-party app can read**. So Threadly
never touches the message store. Instead, the Android "source" is a **`NotificationListenerService`**
that observes **Google Messages' notifications**: a conversation exists, its title, its last-activity
time, whether it's unread, and the **last incoming message's text** (the notification's own preview —
transport-blind, so it covers RCS too). The listener posts no notifications of its own (the app's
only own notifications are user-set conversation **reminders**, see `lib/data/reminders.dart`; the
listener filters to the GM package so they never loop back). This requires the user
to grant **notification access**. Note the preview is *incoming-only* (messages you send post no
notification) and needs at least one new message after install.

Consequences baked into the design:

- The conversation list is **incremental** — a conversation appears only after Google Messages posts
  a notification for it (i.e. an *incoming* message while GM is **not** foregrounded). Send-only or
  foreground/muted conversations are invisible.
- Notifications expose the group **name and flag** but **not the membership**. Deep-linking any
  conversation (incoming RCS groups included) works via **Google Messages' own conversation id**:
  the notification's `shortcutId` (also the trailing number of its tag, which is Threadly's
  conversation id). GM registers a sharing shortcut per conversation whose intent is a plain
  LAUNCHER intent to `.ui.ConversationListActivity` with extras `conversation_id="<id>"` (**must be
  a String** — an int lands in the inbox), `mapi_conversation_kind=1`, `via_shortcut=true`
  (recipe from `adb shell dumpsys shortcut`, verified 2026-10-16). Threadly builds that intent
  itself in `launch(id)`; nothing expires with the notification. It relies on undocumented GM
  extras, so the `sms:` and inbox fallbacks stay. Dead ends, don't retry: the notification's
  `contentIntent` (a PendingIntent that goes away with the notification), and a hand-attached
  roster via `sms:` (tried 2026-07, reverted — an `sms:` recipient link resolves to the *SMS/MMS*
  thread for those members, so for an incoming **RCS** group it opens a *different* conversation).
  Groups created in Threadly also deep-link via `sms:` only because they *are* the MMS thread.

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
color, note, and **reminder** (`remindAtMs`, an epoch-ms instant that fires a local notification;
kept after firing so the list shows it as elapsed until cleared). On the notification path these
(and category membership, reads, recipients) key by
the **conversation id**, not a phone-derived key. The nickname shows as a *subtitle* — it does
**not** replace the title (deliberate, per user feedback).

Contact **labels** (Android contact groups) were intentionally removed: they're account-bound (fail
on accountless devices) and only duplicated what categories already do better. Contacts are now
**read-only**, used solely to resolve a phone number to a display name (`data/contacts.dart`).

## Architecture

Mainline (notification-driven) pieces:

- `android/.../ConversationNotificationListener.kt` — the `NotificationListenerService`. Watches
  Google Messages notifications and persists, per conversation, `{title, ts, group, preview, gmId}`
  plus an active (= unread) set in SharedPreferences. `preview` is the last *incoming* message's
  text, read from the notification (`android.messages` newest entry, else `EXTRA_TEXT`); a collapsed
  "N new messages" summary keeps the prior preview. `gmId` is GM's conversation id (the
  `shortcutId`, else parsed from the tag) that `launch(id)` turns into an exact-thread intent — see
  the constraint section. Detects a group via GM's group flag / conversation title /
  multiple distinct senders. Exposes `conversationsJson`, `launch(id)`, `forget(id)`,
  `openMessagesApp` over a `MethodChannel("threadly/notifications")` (wired in `MainActivity.kt`).
- `lib/data/notifications.dart` — `NotificationConversationsService` (channel wrapper) +
  `Conversation` model `{id, title, lastActivity, unread, isGroup, preview}`. The `preview` is the
  only message content in the app; there is no message *history*.
- `lib/ui/conversations_screen.dart` — `ConversationsScreen`, the **home** (set in `main.dart`).
  Permission onboarding; list sorted by recency with avatars, last-message preview, unread dot,
  nickname/note/category; tabs (All + categories); search (name/nickname/note/category — *not* the
  preview); tap → handoff; long-press → organize; swipe → forget. Filters out short-code/automated
  senders via `_isAutomatedSender` (keeps groups, 10+ digit numbers, saved contacts). Hosts the New
  Group flow and the inline `_OrganizeSheet`. Tapping resolves the open target: exact thread via
  `launch(id)` (GM conversation id, any kind); else 1:1 → `sms:` to the contact number / created
  group → `sms:` to its saved roster (2+); else open GM inbox. After a
  handoff to a raw-number 1:1 (no contact, no nickname), returning to Threadly shows a **mapping
  prompt** (`_queueMappingPrompt` → resume) offering the organize sheet; "don't ask" declines are
  in-memory (per session). Groups deliberately get no such prompt — see the constraint note below.
  Swipe-forget clears the conversation's annotation, memberships, reminder, and saved roster.
- `lib/ui/new_group_screen.dart` — pick people (`lib/ui/people_picker.dart`, a searchable multi-select
  shared with the legacy editors) + optional name/category → `launchGroupText` + store a
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
- `lib/data/reminders.dart` — `ReminderService` over `flutter_local_notifications`: the user-set
  per-conversation reminder notifications (the only notifications Threadly posts). One reminder per
  conversation (stable FNV-1a notification id from the conversation id, so re-scheduling replaces).
  Exact alarm when "Alarms & reminders" is allowed, else inexact; asks for the Android 13+
  `POST_NOTIFICATIONS` runtime permission on save; survives reboots via the plugin's boot receiver.
  Set/cleared in `_OrganizeSheet`, shown as an alarm line on the tile (error-tinted once elapsed),
  cancelled on swipe-forget. Requires core-library desugaring (see `android/app/build.gradle.kts`).
- `lib/messaging.dart` — the handoff: `openSmsCompose(recipients, {body})`; `launchGroupText(context,
  recipients)` warns if `recipients.length > kGroupTextWarnLimit` (20).
- `android/.../ReturnChip.kt` + `lib/data/return_chip.dart` (`MethodChannel("threadly/return_chip")`)
  — the optional **"back to Threadly" chip**: a draggable `TYPE_APPLICATION_OVERLAY` pill drawn over
  Google Messages after every handoff (`_handedOff` in the home screen, and `openSmsCompose`). Exists
  because Back can't return: GM's conversation screen runs in GM's own task (`singleTask`), so Back
  goes GM inbox → Threadly. Tap → Threadly with the handed-off conversation's organize sheet open
  (a read-once `consumeTapped` flag tells a chip return from Back; Back shows the plain list, plus
  the nickname offer when due); hidden on `MainActivity.onResume`, screen off, or after
  20 min; drag position remembered. Needs the user-granted `SYSTEM_ALERT_WINDOW` ("Display over other
  apps"); its Settings page is always the full app list since Android 11 (the per-app page is
  system-only). Offered once by a sheet on the first return from Messages (unless the nickname
  prompt is showing that time); toggled from the home screen's ⋮ menu. Preference + nudged flag in
  SharedPreferences, not SQLite.
- `lib/models/category.dart` / `models/thread.dart` — `Category` / `GroupChat` /
  `ConversationAnnotation` / `Person`, and `normalizePhone(raw)` (digits-only, last 10).

Legacy (in tree, **unused** by the mainline — reachable only from `main.dart`'s `ThreadListScreen`):
`lib/main.dart`'s `ThreadListScreen`/`ThreadScreen`, `lib/data/sms_source.dart`, `gmessages_source.dart`,
`matrix_client.dart`, `bridge_config.dart`,
`lib/ui/{manage_categories_screen,edit_category_screen,group_chat_editor_screen,organize_sheet}.dart`,
`bridge/`. (`people_picker.dart` is shared: both the mainline New Group flow and these legacy editors
use it.)

### SQLite schema (organizer.db, version 7)

`onCreate` builds everything; `onUpgrade` migrates: `<2` group-chat tables, `<3` `name` column on
`conversation_annotations`, `<4` `conversation_reads`, `<5` `pending_groups` (name/category for a
group started before it exists, applied + removed on first appearance), `<6` `group_recipients`
(a created group's full member numbers, for `sms:` reopen), `<7` `remind_at` column on
`conversation_annotations`. **Bump `version` and add an `onUpgrade`
branch for any schema change** — existing installs carry real user data.

`android/app/src/main/AndroidManifest.xml`: the `ConversationNotificationListener` service
(`BIND_NOTIFICATION_LISTENER_SERVICE`), permissions (`READ_CONTACTS`; `POST_NOTIFICATIONS`/
`SCHEDULE_EXACT_ALARM`/`RECEIVE_BOOT_COMPLETED` for reminders; `SYSTEM_ALERT_WINDOW` for the
return chip; `READ_SMS`/`RECEIVE_SMS`/
`INTERNET` linger from the legacy paths — **no SEND_SMS, no WRITE_CONTACTS**), the
`flutter_local_notifications` receivers (scheduled delivery + reboot restore), and `<queries>` for
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

**Android 15 redaction trap (adb-granted access only):** after granting via `cmd notification
allow_listener`, the listener receives *redacted* notifications — empty `EXTRA_TITLE`, so `record()`
drops every one (it logs `empty title … redaction?`) and the list silently never updates. Fix:
`adb shell appops set com.augusto.group_chat RECEIVE_SENSITIVE_NOTIFICATIONS allow`, then rebind
(`disallow_listener` + `allow_listener`). Access granted by a user through Settings is unaffected.
Other emulator notes: inject a conversation with `adb emu sms send <number> <text>` (seeded
contacts own `+1310555xxxx` — use another prefix or the message lands in an existing thread);
Google Messages must be past its first-run screen ("Use Messages without an account") before it
posts notifications; `adb uninstall` wipes Threadly's DB but Android auto-backup usually restores
it on reinstall.
