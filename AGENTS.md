# Steve setup and contributor guidance

## For setup agents

Installation does not require a source build or the contributor checks below. Read [guide/setup.md](guide/setup.md) and follow its ordered onboarding steps.

Own the whole onboarding conversation. Explain that checking access together now avoids permission surprises when the user is away. Give one plain-language next step at a time, resume after each human action, diagnose a missing reply, and verify a useful task through Steve before handing setup back. Do not stop at a ready CLI response or ask the user to troubleshoot commands themselves. See [the guided first conversation](guide/setup.md#guide-the-first-conversation).

Recommend Astra in the local Codex desktop app for setup. Use structured user-input questions when the host provides them; otherwise ask in ordinary chat. Ask one decision at a time and wait for the answer before dependent actions. Do independent inspection while waiting. Never treat elapsed time or a selected default as permission granted. Astra and question-tool availability are separate from Steve's configured models.

- Offer recommended settings or customization: GPT-6 Luna Low Fast coordinator, GPT-6 Sol Xhigh Standard workers, two concurrent workers, and one research helper per eligible worker. Explain Fast's higher usage. Read the installed CLI's `models` catalog and current choices; preserve existing settings and offer only supported model/effort combinations. If the recommendation is unavailable, ask the user to choose from the available catalog.
- Offer private phone sign-in before the user leaves the Mac. If accepted, guide Tailscale on both devices, Steve's separate permissions, and an actual takeover/continue check. If skipped, explain that sign-in may require returning to the Mac. Do not enable public Funnel or replace unrelated network routes.

- Inspect existing Steve installations first. Preserve settings, pairing, queued work, schedules, workspace, and Codex-owned credentials. Prefer updating in the existing app location.
- Prefer the newest compatible signed, notarized release. Include published prereleases using the releases list API, not only `/releases/latest`; require the app ZIP and matching checksum. Verify signature, notarization, architecture, and macOS compatibility. Explain source builds only if no compatible release is available.
- Launch the installed app before calling its CLI. Use its full executable path; a downloaded release does not install a shell wrapper. Run setup/doctor/status through that app, not a second Messages process.
- Explain the tested separate Messages account arrangement. Inspect the installed CLI's `--help`: when `--owner` is supported (v0.1.7+), ask for the one owner's exact iMessage address and configure it during installation. Offer an optional agent name and personality; defaults are fine. The first new private message connects and remains a real request. v0.1.6 and earlier use `--pair`; do not pass unsupported flags or force a source build. Then configure native Computer Use and its permissions. Use the existing browser profile; do not install a Chrome extension or revive the old browser bridge.
- Open a required permission pane with `setup --open-permission TARGET --json`, one target at a time. Show the exact app to add. The user grants permission and completes account login; never edit TCC or grant access silently. Ordinary setup/doctor do not open Settings.
- Preserve existing access choices. Ask for a missing choice in plain language; do not silently enable Full Access. Install optional video/phone-control permissions and Tailscale only when wanted.
- Handle required blocked/needs_user_action checks before claiming configuration is ready. Optional unverified checks are separate live acceptance steps; do not repeat doctor indefinitely waiting for them to change. Wait for a human action before rechecking a missing grant.
- Never send a test iMessage without authorization for the exact destination. Prefer having the user send the first ordinary task (or the code when using the legacy pairing path). Do not call setup complete until the actual reply and native Computer Use result are verified. A configured owner address is not yet a verified connected conversation.
- If a first message does not connect, verify its actual sending address with the user. A phone-number preference is not proof of the sender used by that conversation. Never add or substitute an owner without their explicit choice, and require a fresh message after changing it.
- Keep login URLs, pairing codes, credentials, histories, and diagnostics private. Do not paste passwords or tokens into chat.
- On upgrade, keep a temporary rollback outside Applications until the updated app passes verification; then remove that app rollback. Preserve user data and never reset permissions as a troubleshooting shortcut.

## For contributors

Steve is a macOS native SwiftUI menu-bar application. Preserve these invariants:

- Swift owns presentation and the privileged service boundary. Messages access stays in vendored IMsgCore and Codex credentials remain owned by the installed Codex App Server.
- Never send a live iMessage from tests or development fixtures. Production sending is gated by completed onboarding, exact chat pairing, and the active permission boundary.
- Never store ChatGPT tokens. Authentication belongs to `codex app-server`.
- Keep Steve's App Server session and SQLite storage under its private runtime. Reuse shared Codex setup without sharing the desktop task index, and keep Computer Use on its existing installed home. Import only an exact Steve-originated legacy transcript when resuming it; never copy all desktop history.
- Treat the workspace root and paired chat as security boundaries. Canonicalize paths and fail closed on sender/chat mismatches.
- Keep protocol fixtures deterministic. Prefer unit and functional tests over broad smoke tests.
- Before adding a test, name the observable contract, a credible regression, and why existing coverage would miss it. Give each contract one primary test at the strongest practical boundary; extend an existing case for another input instead of replaying the same path in a helper test and an RPC or gateway test. Keep a lower-level test when it protects a distinct failure mode, especially security or wire compatibility. Avoid production hooks that exist only for tests.
- When pruning tests, preserve the contract in its primary test, run the focused check and the required full checks below, and report measured test and production line changes separately. Treat CI time savings as estimates unless measured on the runner.
- Do not add private Messages APIs or SIP-disabling behavior. Steve uses read-only Messages database access and public AppleScript-backed sending.

Run before handing development work back:

```sh
swift test --package-path native
swift build --package-path native --configuration release
```

Only the Sol orchestrator commits, pushes, signs, notarizes, tags, or creates releases. Contributors make bounded changes for review.
