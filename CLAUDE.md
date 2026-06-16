# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter app — a "thin layer" that organizes group texts and lets the user choose between this UI
and the native Messages app. Currently a **Phase 0 Android-only spike** (see `~/.claude/plans/there-are-so-many-memoized-pike.md`).

## The defining constraint (read before changing data/platform code)

"Group texts" are three incompatible systems, each gatekept:

- **SMS/MMS** — Android can read+send (with SMS permissions or as default SMS app); iOS cannot read at all.
- **iMessage** — no third-party read/send anywhere (only macOS `chat.db`).
- **RCS** — closed on every platform.

Because of this the app is **asymmetric by design**: a full client on Android, and on iOS a
degraded companion (no thread reading — only `MFMessageComposeViewController` assisted send and
`sms:` deep links). Do not attempt to read texts on iOS; there is no API. The "Open in Messages"
deep link is the cross-platform fallback and the product's core idea.

Known sharp edge: group **MMS** recipient lists are not fully reconstructed from the SMS provider
alone via `another_telephony`. The current code derives participants from incoming SMS addresses
grouped by THREAD_ID. The open decision gate is whether to escalate to a custom MMS content-provider
query or become the default SMS app. Play Store also requires SMS apps to be the default handler +
pass policy review.

## Architecture

The UI talks only to platform-agnostic domain types; platform access lives behind one interface so
iOS can be slotted in without touching the UI.

- `lib/models/thread.dart` — `MessageThread` / `Message`. `isGroup` = >1 participant; `participantKey`
  is the order-independent grouping key; messages are newest-first (`latest` = first).
- `lib/data/sms_source.dart` — `SmsSource` interface (`canReadThreads`, `loadThreads`, `sendSms`).
  `AndroidSmsSource` implements it against the SMS provider. **A future `IosSmsSource` must throw on
  `loadThreads` and route `sendSms` through the compose sheet / deep link.** Keep all platform
  branching here, not in the UI.
- `lib/main.dart` — UI only. `ThreadListScreen` requests SMS permission at runtime and renders the
  grouped list; `ThreadScreen` shows a conversation with the two core actions: **Reply here**
  (`source.sendSms`) and **Open in Messages** (`sms:` deep link via `url_launcher`).

Android permissions (`READ_SMS`/`RECEIVE_SMS`/`SEND_SMS`) and the `sms:` `<queries>` entry live in
`android/app/src/main/AndroidManifest.xml`.

## Commands

The Flutter SDK here is at `/Users/acmcp/dev/flutter/bin/flutter` (may not be on PATH).

```bash
flutter pub get                 # install deps
flutter analyze                 # lint (must be clean; uses analysis_options.yaml / flutter_lints)
flutter test                    # run all unit tests
flutter test test/widget_test.dart --plain-name "is a group"   # run a single test by name
flutter run                     # run on connected device
flutter build apk --debug       # verify the full Android native stack compiles
```

## Verification reality

`flutter analyze`, `flutter test`, and the debug APK build are the CI-equivalent checks and must
pass. But the spike's actual go/no-go — reading **real** group threads — requires a **physical
Android device**; emulators have no SMS data, and macOS/Chrome/iOS targets cannot exercise the SMS
data source. When verifying group support, specifically confirm group MMS threads show correct
participants.
