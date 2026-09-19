# Steve

Steve connects one private iMessage conversation to a persistent operator on your Mac. A small native menu-bar app owns Messages, the workspace boundary, and a relay/worker pair running through the installed Codex App Server. Authentication stays with Codex; Steve does not store ChatGPT tokens or require an OpenAI API key.

**Development preview.** Source installation, paired iMessage delivery, saved preferences, and one-time and recurring schedules have been exercised on a Mac. In two small pilot runs, Steve completed visible-browser research from Hacker News to an original source, checked live restaurant availability without booking, and obtained and cleaned up guest-cart quotes without purchasing. Both pilots read a bounded set of real email and produced private local drafts; calendar reads worked, but complete calendar inventory was blocked by a missing OAuth scope, so that workflow remains partial. Focused retests with both configurations delivered native videos containing only the selected app window; received attachments decoded and were visually inspected on a Mac. Phone takeover and video playback on a physical iPhone remain unverified. The [eight-task outcome report](guide/practical-benchmark-20260919.md) preserves original scores, repair checks, and interventions. These pilots are acceptance evidence, not a statistically reliable model ranking. The optional Link payment adapter has fixture tests only and is not connected to the operator. This source tree is MIT licensed; no notarized binary release is claimed.

## Set it up with your agent

Give a local coding agent this repository and the following request:

> Help me install Steve from this repository. Read AGENTS.md and guide/setup.md first. Inspect my existing installation and dependencies, preserve my settings and data, build and test the source, and run the installed app's setup --non-interactive --json command. Explain each needs_user_action step and help me finish account login, macOS permissions, and exact iMessage pairing. Use my existing browser profile. Ask for any missing access choice rather than enabling full computer access automatically. Do not copy credentials into chat or send a live test until I authorize the destination.

The agent needs local tools on the Mac that will run Steve. A web chat without local access cannot install a Mac app. Follow [the setup guide](guide/setup.md) for manual installation and machine-readable commands.

## How it works

- The persistent relay interprets requests and formats verified results; a persistent worker performs the task. Context can be reused, compacted, or deliberately reset.
- The installed Computer Use plugin operates visible Chrome using the existing profile. Install the plugin through its supported ChatGPT/Codex flow; it is not redistributed in this repository.
- Incoming messages and outgoing parts are persisted. Restart recovery preserves queued requests. Ambiguous executions or sends are recorded for review rather than automatically replayed.
- Explicitly saved preferences survive restart and can be listed or forgotten. Reminders and scheduled tasks use durable records and explicit timezones; uncertain outcomes block automatic repetition.
- One exact private conversation is paired with a short-lived code. Other chats, group conversations, and mismatched senders cannot operate Steve.
- Say what you want in normal language. `/stop` is the emergency pause command. Say “resume” to continue accepting work or “status” to inspect the current state. A stopped task with uncertain side effects is not automatically rerun.

Steve uses read-only access to the local Messages database and public AppleScript sending. It does not require private Messages frameworks, SIP changes, a Messages extension, or an iPhone companion app.

## Development

macOS 14 or later and a Swift toolchain compatible with `native/Package.swift` and its locked dependencies are required.

```sh
swift test --package-path native
swift build --package-path native --configuration release
./scripts/build-native.sh
```

Tests use fixtures and never send live iMessages. Live acceptance runs require an explicitly authorized conversation. Raw histories, local settings, diagnostic logs, screenshots, and development artifacts must stay out of public commits.

See [third-party notices](THIRD_PARTY_NOTICES.md) and [the release checklist](guide/release-checklist.md).
