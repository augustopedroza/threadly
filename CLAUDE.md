# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Threadly** — a Flutter Android app that is a "thin layer" (an organizer + launcher) over the
user's existing texts. It learns which conversations exist and when they last got a message, keeps a
one-line **last-message preview** for each, lets the user **organize** them (categories, custom
nicknames, colors, notes, reminders, group rosters), then **hands off to Google Messages** for all reading and
sending. It also reads contact names/photos (read-only) to show them over raw numbers, and offers
**on-device AI suggestions** (nickname, note, category, reminder, save-as-contact) and **"Ask
Threadly" commands** (forward / reply / remind / file, in plain language), all confirmed by the user. The pitch: organize here, read/send in the app you already use.

The message content Threadly keeps is that last-message preview plus a rolling **buffer of the last
10 messages per conversation**, the input for suggestions. Both come straight from the Google Messages
**notification** (never a message store), so they work across SMS/MMS/RCS alike; both stay on the
device (prefs aren't in the backup include list, and there's no network permission). It never reads
the full message *history*. Currently **Android-only**; iOS is not viable for the core features (see
"The defining constraint").

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

> History: earlier versions read texts via the on-device SMS provider, then via a
> mautrix-gmessages + Synapse **bridge** (to reach RCS). Both were retired for the notification
> listener and **deleted from the tree on 2026-10-16** along with their permissions (`READ_SMS`,
> `RECEIVE_SMS`, `INTERNET`, cleartext traffic) and packages. To look at that code, check out the
> commit before the removal (`f6d2ddd`). Don't reintroduce SMS permissions: Play restricts them to
> default-SMS apps, and "Threadly can't read your messages" is part of the pitch.

## Two "grouping" concepts — do not conflate

The app has two app-owned ways to associate conversations, both stored in its own SQLite DB:

1. **Category** (`models/category.dart` `Category`) — a bucket (e.g. "LDS", "U17 Team").
   Classifies both individual and group conversations and **drives the tabs**. Members are
   conversation ids (the column is still named `phone` from the SMS era).
2. **Created group** — a group text started from Threadly's New Group flow. It *is* a real Google
   Messages conversation (born from an `sms:` link); Threadly just remembers its chosen name/category
   (a **pending group** until the conversation first appears) and its full roster
   (`group_recipients`, for the `sms:` fallback). The older saved-roster `GroupChat` concept is gone;
   its `group_chats` tables stay in the schema, dormant.

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
  the constraint section. Also merges each notification's bundled `android.messages` into a
  per-conversation buffer of the last 10 `{time, sender, text}` (deduped on time+text; null sender =
  "Me") in its own prefs file `threadly_recent` — the suggestions' input (`recentMessages`), cleared
  by `forget`. Detects a group via GM's group flag / conversation title /
  multiple distinct senders. Exposes `conversationsJson`, `launch(id)`, `forget(id)`,
  `openMessagesApp` over a `MethodChannel("threadly/notifications")` (wired in `MainActivity.kt`).
- `lib/data/notifications.dart` — `NotificationConversationsService` (channel wrapper) +
  `Conversation` model `{id, title, lastActivity, unread, isGroup, preview}`. The `preview` is the
  only message content the Dart side sees; the 10-message buffer stays native.
- `lib/ui/conversations_screen.dart` — `ConversationsScreen`, the **home** (set in `main.dart`).
  Permission onboarding; list sorted by recency with avatars, last-message preview, unread dot,
  nickname/note/category; tabs (**All, To reply**, then categories); search (name/nickname/note/
  category — *not* the preview); tap → handoff; long-press → organize; **swipe right → "Save for
  later"** (`_saveForLater`: pick a time → a reminder; Undo restores the previous one). **No
  destructive swipes anywhere** — a swipe from the screen edge is also Android's back gesture, and
  it was forgetting chats / clearing reminders by accident: forgetting lives in the organize
  sheet ("Forget conversation", confirmed), swipes need half the width (`dismissThresholds`). Alarm
  icon in the app bar (badge = overdue count) → the Reminders screen.
  **To reply** tab (`_replyTab`, rules in `lib/models/reply.dart` `belongsInToReply`, unit-tested
  in `test/reply_test.dart`): last 7 days, newest message from someone else (not a reaction like
  `👍 to “…”`, not the user's own inline reply — native `lastFromMe`), not marked done since that
  message, and not judged "no" by the on-device AI. `_judgeReplies` asks
  `ConversationSuggester.needsReply` (YES/NO few-shot) one chat at a time while Threadly is on
  screen and saves each verdict per message (`reply_state.verdict_at`), so a message is judged
  once; unjudged chats show (benefit of the doubt, and the fallback where there's no AI). Threadly
  can't see replies sent in Google Messages, so a chat leaves on swipe-left **Done** (Undo) or
  when Ask Threadly opens a reply to it (`_markReplied`); a newer message brings it back. Filters out short-code/automated
  senders via `_isAutomatedSender` (keeps groups, 10+ digit numbers, saved contacts). Hosts the New
  Group flow and the inline `_OrganizeSheet`. Tapping resolves the open target: exact thread via
  `launch(id)` (GM conversation id, any kind); else 1:1 → `sms:` to the contact number / created
  group → `sms:` to its saved roster (2+); else open GM inbox. Returning from any handoff (chip or
  Back) refreshes the list **in place** (spinner only on first load, so scroll/tab survive) and
  **blinks** the conversation you came from (`_Blink`: scrolls it into view only if off screen,
  two primary-color pulses; a row not yet built — far off screen after a reorder — isn't
  reached). `_Blink` is **keyed by conversation id** — list children otherwise match by position,
  and a running pulse would land on whatever row a re-sort put there. "Came from" = whichever is
  **newer**: the last handoff (expires after 20 min, `_returnWindow`) or a GM notification tap
  (counted only if the user then came back *through the chip*). Any prompt waits for the blink. After a
  handoff to a raw-number 1:1 (no contact, no nickname), returning to Threadly shows a **mapping
  prompt** (`_queueMappingPrompt` → resume) offering the organize sheet; "don't ask" declines are
  in-memory (per session). Groups deliberately get no such prompt — see the constraint note below.
  On return the on-device model is asked too; `_returnOffer` decides what to show: an
  **unorganized** conversation (no nickname, note, or category) gets the whole suggestion, an
  organized one only a **new reminder** (each "id|time" offered once per session, `_offeredReminders`),
  and fields already set are dropped. If anything's left, `_offerSuggestion` replaces those prompts
  (one prompt per return): editable nickname / note, "Add to <category>" and "Remind me <when>"
  checkboxes (the latter notes when it replaces an existing reminder; saving schedules it via
  `ReminderService`), Not now (session) / Don't suggest for this one (permanent, native). The
  organize sheet always shows tap-to-apply suggestion chips (`_suggestionChips`, `force: true`);
  its request starts once in `_organize`, not in the builder. **Save to contacts**: for a
  raw-number 1:1, both sheets show `_SaveContactButton` under the name field, using whatever name
  is typed there (AI-suggested or not; disabled while empty). In the return prompt it also saves
  the note/category/reminder, but not the name as a nickname (it'd duplicate the contact name the
  row then shows).
  `setAnnotation` replaces the whole row, so saves carry over the other fields. A raw-number 1:1
  shows its contact name once saved (`_displayTitle`); a nickname equal to the shown title is
  hidden (e.g. kept after saving the contact under the same name).
  Swipe-forget clears the conversation's annotation, memberships, reminder, and saved roster.
- `lib/ui/new_group_screen.dart` — pick people (`lib/ui/people_picker.dart`, a searchable
  multi-select) + optional name/category → `launchGroupText` + store a
  **pending group**, applied to the real conversation when it appears.
- `lib/ui/category_manager_screen.dart` — add/rename/recolor/delete categories.
- `lib/data/organizer_store.dart` — `OrganizerStore`, the app-owned SQLite store. **Tables are still
  named `groupings` / `grouping_members` / `grouping_id`** for back-compat ("grouping" → "category"
  in UI only; don't surface "grouping"). On the notification path, annotations, reads, category
  membership, pending groups, and group recipients are all keyed by the **conversation id**.
  `createCategory` is **idempotent by name** (case-insensitive).
- `lib/data/contacts.dart` — `ContactsService` + immutable `ContactsSnapshot`: normalized phone →
  name (`nameForPhone`), photo (`photoForTitle`), name → number (`phoneForName`), and a
  `people` list for the New Group picker. Read-only.
- `lib/data/reminders.dart` — `ReminderService` over `flutter_local_notifications`: the user-set
  per-conversation reminder notifications (the only notifications Threadly posts). One reminder per
  conversation (stable FNV-1a notification id from the conversation id, so re-scheduling replaces).
  Exact alarm when "Alarms & reminders" is allowed, else inexact; asks for the Android 13+
  `POST_NOTIFICATIONS` runtime permission on save; survives reboots via the plugin's boot receiver.
  Set/cleared in `_OrganizeSheet`, shown as an alarm line on the tile (error-tinted once elapsed),
  cancelled on swipe-forget. Requires core-library desugaring (see `android/app/build.gradle.kts`).
  Each reminder stores **what it's for** (`remind_what`, e.g. "Big move at home") — the
  notification text and the Reminders screen subtitle; `setAnnotation` keeps it unless given, and
  clears it with the reminder. The payload is JSON `{id, title, body}` (`ReminderPayload`; older
  ones were a bare id). Notification buttons **"Snooze 1 hour" / "Tomorrow morning"** act without
  opening the app: `onReminderAction` (top-level, `vm:entry-point`) runs in the plugin's background
  isolate (`DartPluginRegistrant.ensureInitialized()`), moves the stored time
  (`OrganizerStore.setReminder`) and re-schedules; needs the plugin's `ActionBroadcastReceiver` in
  the manifest. Home-screen paths (save for later, Reminders screen) go through
  `_setReminder` → `OrganizerStore.setReminder` (touches only the reminder fields).
- `lib/ui/reminders_screen.dart` — `RemindersScreen`: every reminder, **Due** (newest first) then
  **Upcoming**; tap opens the chat (handoff), snooze icon → reschedule, ✓ → clear (Undo restores
  even a past-due one). No swipe-to-clear (back-gesture collisions).
  The home screen owns the data (`_reminderEntries`) and passes callbacks.
- `lib/ui/later_picker.dart` + `lib/models/later.dart` — `pickLater`: quick times (`laterPresets`:
  in 1 hour, this evening (before 5 PM), tomorrow morning, this weekend (Mon-Thu), next week (not
  on Sunday) — 9 AM / 6 PM) plus "Pick date & time…"; used by save for later, the Reminders
  screen, and the organize sheet's reminder row. Unit-tested in `test/later_test.dart`.
- `lib/messaging.dart` — the handoff: `openSmsCompose(recipients, {body})`; `launchGroupText(context,
  recipients)` warns if `recipients.length > kGroupTextWarnLimit` (20).
- `android/.../ConversationSuggester.kt` + `lib/data/suggestions.dart`
  (`MethodChannel("threadly/suggest")`: `suggest`, `dismiss`, `saveContact`) — on-device suggestions
  via **Gemini Nano / ML Kit GenAI Prompt API** (`com.google.mlkit:genai-prompt`, hence `minSdk 26`).
  Free, offline, no network permission. From the conversation's recent messages it proposes
  `{nickname, note, category, reminder}`: nickname = a **group's main topic**, or for a **raw-number
  1:1 the person's own name** when they state it (also offered as a contact); none for a saved
  contact (its name already shows). Note = what the chat is about (2-10 words). Category = one of
  the user's existing categories it isn't in (never a new one). **Reminder**: the model only *copies*
  the date words of an upcoming plan/deadline ("Saturday at 9am | Practice"), kept only if they
  really appear in a message; native passes them with that message's send time (`dueRef`), and
  `lib/models/due_date.dart` `parseDueDate` resolves them **deterministically** (weekdays, today/
  tonight/tomorrow, "Oct 20", "10/31", "the 1st", lone times; US month/day; no time → 9:00 AM;
  bare hours 1-7 → PM; unit-tested in `test/due_date_test.dart`) — small models get date math
  wrong. Only moments in the coming year count. The prompt is a literal labeled template plus a
  per-kind example (Nano drops labels otherwise; the parser also reads bare lines positionally,
  and treats "NONE - NONE", "NONE | NONE" etc. as empty). Results are cached in memory per (last activity,
  wantName, categories). AICore realities: inference **only for the app on screen**
  (`BACKGROUND_USE_BLOCKED`, so never from the listener), per-app quota (`BUSY`/battery), supported
  devices only (Pixel 9/10 and some flagships), and a one-time model download (~3 min on the test
  Pixel 10 Pro Fold) triggered by the first call when `DOWNLOADABLE`. Every failure = no suggestion.
  "Save to contacts" (`saveContact`) opens the system `Intents.Insert` editor prefilled — the user
  saves (and picks the account) there, so Threadly stays **read-only on contacts** (no
  WRITE_CONTACTS); Back from the editor returns to Threadly with nothing saved. Logs (tag
  `ThreadlySuggest`) carry ids/status/errors only — never message text.
- **"Ask Threadly"** — a command box at the top of the organize sheet (`_askBox` / `_runAsk`):
  plain-language instructions about that chat, typed or dictated with the keyboard mic (no
  RECORD_AUDIO). `ConversationSuggester.interpret` (channel `interpret`) has Gemini Nano map it to
  one action via a 6-line few-shot template — `ACTION` (FORWARD/REPLY/REMIND/FILE), `TO` (a name
  as said, or THIS), `TEXT`, `WHEN`, `CATEGORY`, `NICKNAME` → `ThreadlyCommand`
  (`lib/models/command.dart`). As with suggestions the model only *copies*; Dart resolves:
  names → `ContactsSnapshot.matchPeople` (exact full name, else every spoken word prefixes a name
  word; several → the user picks), dates → `parseDueDate` (the WHEN words, else the whole
  instruction; also "in N minutes/hours/days/weeks"), categories → the user's list. Outcomes:
  **forward/reply** → `_confirmDraft` card (recipient, which buffered message to forward via
  channel `recent`, editable text from `forwardBody`, e.g. `From Adam: “…”`) → "Open in Messages"
  opens a **draft**; nothing is ever sent by Threadly. Replies to *this* chat go through the
  screen's `_openWithText`: `sms:…?body=` where `_draftRecipients` can address it (a 1:1, or a
  group created here), else the text is **copied to the clipboard** and the exact thread opened
  to paste (incoming RCS groups can't take a pre-filled draft). **remind** → fills the sheet's
  reminder; **file** → fills the nickname / offers an "Add to <category>" chip; Save keeps them.
  Limits: text only (notifications carry no media), "this message" = Threadly's buffered recent
  messages for that chat (incoming; your own sends aren't seen). The card pre-selects the newest
  message *from someone else* and lists up to 5 recent ones to pick from.
- Organize sheet layout: Ask Threadly box, nickname (+ save-to-contacts / suggestion chips), note,
  reminder, then **"Color & categories" collapsed** to a one-line summary (color dot + category
  chips; `_showStyle` expands it) — they change rarely.
- `android/.../ReturnChip.kt` + `lib/data/return_chip.dart` (`MethodChannel("threadly/return_chip")`)
  — the optional **"back to Threadly" chip**: a draggable `TYPE_APPLICATION_OVERLAY` pill drawn over
  Google Messages after every handoff (`_handedOff` in the home screen, and `openSmsCompose`), and
  when the user **taps one of GM's own notifications**: the listener's reason-carrying
  `onNotificationRemoved` sees `REASON_CLICK` (vs a swipe or read-elsewhere) and calls
  `ReturnChip.showForNotificationTap`, which also remembers the conversation (read-once
  `consumeReturnTarget`, stale after the chip's 20 min). Threadly's `_afterReturn` — run on every
  resume *and* after a cold start (the chip can launch Threadly fresh) — treats that like a handoff:
  blink, suggestions, or the raw-number nickname offer (`_needsMappingPrompt`). Exists
  because Back can't return: GM's conversation screen runs in GM's own task (`singleTask`), so Back
  goes GM inbox → Threadly. Tap → Threadly as you left it; hidden on `MainActivity.onResume`, screen off, or after
  20 min; drag position remembered. Needs the user-granted `SYSTEM_ALERT_WINDOW` ("Display over other
  apps"); its Settings page is always the full app list since Android 11 (the per-app page is
  system-only). Offered once by a sheet on the first return from Messages (unless the nickname
  prompt is showing that time); toggled from the home screen's ⋮ menu. Preference + nudged flag in
  SharedPreferences, not SQLite.
- `lib/models/category.dart` — `Category`, `ConversationAnnotation`, `Person`, `pluralPeople`, the
  color palette. `lib/models/phone.dart` — `normalizePhone(raw)` (digits-only, last 10).
- `lib/main.dart` — just `main()` (initializes reminders) and `ThreadlyApp` (theme, home).

### SQLite schema (organizer.db, version 9)

`onCreate` builds everything; `onUpgrade` migrates: `<2` group-chat tables (dormant now — no
code reads them; kept so the schema doesn't change), `<3` `name` column on
`conversation_annotations`, `<4` `conversation_reads`, `<5` `pending_groups` (name/category for a
group started before it exists, applied + removed on first appearance), `<6` `group_recipients`
(a created group's full member numbers, for `sms:` reopen), `<7` `remind_at` column on
`conversation_annotations`, `<8` `remind_what` column (what the reminder is for), `<9`
`reply_state` (To reply: `done_at`, `verdict_at`, `needs_reply`). **Bump
`version` and add an `onUpgrade`
branch for any schema change** — existing installs carry real user data.

`android/app/src/main/AndroidManifest.xml`: the `ConversationNotificationListener` service
(`BIND_NOTIFICATION_LISTENER_SERVICE`), permissions (`READ_CONTACTS`; `POST_NOTIFICATIONS`/
`SCHEDULE_EXACT_ALARM`/`RECEIVE_BOOT_COMPLETED` for reminders; `SYSTEM_ALERT_WINDOW` for the
return chip — **no SMS permissions, no INTERNET, no WRITE_CONTACTS**; the release APK's full list
is those plus `VIBRATE` from the notifications plugin, checkable with `aapt2 dump permissions`), the
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
flutter test test/widget_test.dart --plain-name "normalizePhone"   # run tests by name
flutter test test/due_date_test.dart   # the reminder date resolver
flutter test test/command_test.dart    # Ask Threadly: forward text, contact matching
flutter test test/later_test.dart      # save-for-later / snooze time presets
flutter test test/reply_test.dart      # who shows in the To reply tab
flutter run                     # run on a connected device/emulator
flutter build apk --debug       # verify the full Android native stack compiles
```

## Releases

- **Signing key**: `~/keystores/threadly-release.jks` on the dev Mac (PKCS12, alias `threadly`, RSA
  4096, cert SHA-256 `56:47:5F:3E:…:57:16:5C`, valid to 2054). Its password lives only in
  `android/key.properties` (git-ignored) and in the repo's GitHub secrets. **Back the .jks and its
  password up outside this Mac** — without them no future build can install over this app.
- `android/app/build.gradle.kts`: release builds sign with that key whenever `key.properties`
  exists, else fall back to the debug key (a fresh checkout still builds, but its APK can't update
  an installed release). **versionCode = `git rev-list --count HEAD`**, so any newer commit's build
  installs over an older one, local or CI (versionName stays pubspec's, or the tag on releases).
- **CI** (`.github/workflows/android.yml`): every push to `main` runs analyze + tests and uploads
  a signed APK as a run artifact; pushing a tag `vX.Y.Z` also creates a GitHub Release with the
  APK. It writes `key.properties` from secrets `THREADLY_KEYSTORE_BASE64`,
  `THREADLY_KEYSTORE_PASSWORD`, `THREADLY_KEY_ALIAS`, `THREADLY_KEY_PASSWORD`. Pushing workflow
  files needs a token with the `workflow` scope (`gh auth refresh -s workflow`).
- Installs signed with a *different* key (the old debug-signed builds) can't be updated in place:
  that switch is an uninstall + reinstall, and Android's backup won't restore across a key change,
  so app data has to be carried over by hand (debuggable builds + `run-as`).

## Verification reality

`flutter analyze`, `flutter test`, and the debug APK build are the CI-equivalent checks and must
pass. The unit tests cover only pure Dart (`test/widget_test.dart`: models; `test/due_date_test.dart`:
date resolution; `test/command_test.dart`: Ask Threadly's forward text and contact matching);
everything platform-bound is verified by running the app.

A **plugged-in Android device or emulator** is required to exercise the notification source,
contact resolution, and the `sms:` handoff — macOS/Chrome/iOS targets can't. The conversation list
only populates once **notification access** is granted and Google Messages posts notifications; the
Pixel API 35 emulator has Google Messages with seeded conversations, so the list, unread dots,
recency, categories, search, swipe-delete, and the handoff are all testable there. Grant access fast
via `adb shell cmd notification allow_listener com.augusto.group_chat/com.augusto.group_chat.ConversationNotificationListener`.
Real **group detection** and **contact photos** need a real device (the emulator's synthetic
notifications/contacts lack those signals). The app's SQLite-backed organizing works fully on an
emulator, no account needed. **AI suggestions** need a Gemini Nano device (not the emulator): test
with the phone **unlocked and Threadly on screen** (a locked phone yields `BACKGROUND_USE_BLOCKED`),
pause a few seconds between long-presses when batch-testing (logd's chatty filter drops repeated
`ThreadlySuggest` lines), and remember a fresh install's buffer is empty, so suggestions start from
the one-line preview until new messages arrive.

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
