# Steve setup and contributor guidance

## For setup agents

Installation does not require a source build or the contributor checks below. Read [guide/setup.md](guide/setup.md) and follow its ordered onboarding steps.

- Inspect existing Steve installations first. Preserve settings, pairing, queued work, schedules, workspace, and Codex-owned credentials. Prefer updating in the existing app location.
- Prefer the newest compatible signed, notarized release. Include published prereleases using the releases list API, not only `/releases/latest`; require the app ZIP and matching checksum. Verify signature, notarization, architecture, and macOS compatibility. Explain source builds only if no compatible release is available.
- Launch the installed app before calling its CLI. Use its full executable path; a downloaded release does not install a shell wrapper. Run setup/doctor/status through that app, not a second Messages process.
- Explain the tested separate Messages account arrangement. Pair iMessage first, then configure native Computer Use and its permissions. Use the existing browser profile; do not install a Chrome extension or revive the old browser bridge.
- Open a required permission pane with `setup --open-permission TARGET --json`, one target at a time. Show the exact app to add. The user grants permission and completes account login; never edit TCC or grant access silently. Ordinary setup/doctor do not open Settings.
- Preserve existing access choices. Ask for a missing choice in plain language; do not silently enable Full Access. Install optional video/phone-control permissions and Tailscale only when wanted.
- Handle required blocked/needs_user_action checks before claiming configuration is ready. Optional unverified checks are separate live acceptance steps; do not repeat doctor indefinitely waiting for them to change. Wait for a human action before rechecking a missing grant.
- Never send a test iMessage without authorization for the exact destination. Prefer having the user send the pairing code and the first browser task. Do not call setup complete until the actual reply and native Computer Use result are verified.
- Keep login URLs, pairing codes, credentials, histories, and diagnostics private. Do not paste passwords or tokens into chat.
- On upgrade, keep a temporary rollback outside Applications until the updated app passes verification; then remove that app rollback. Preserve user data and never reset permissions as a troubleshooting shortcut.

## For contributors

Steve is a macOS native SwiftUI menu-bar application. Preserve these invariants:

- Swift owns presentation and the privileged service boundary. Messages access stays in vendored IMsgCore and Codex credentials remain owned by the installed Codex App Server.
- Never send a live iMessage from tests or development fixtures. Production sending is gated by completed onboarding, exact chat pairing, and the active permission boundary.
- Never store ChatGPT tokens. Authentication belongs to `codex app-server`.
- Treat the workspace root and paired chat as security boundaries. Canonicalize paths and fail closed on sender/chat mismatches.
- Keep protocol fixtures deterministic. Prefer unit and functional tests over broad smoke tests.
- Do not add private Messages APIs or SIP-disabling behavior. Steve uses read-only Messages database access and public AppleScript-backed sending.

Run before handing development work back:

```sh
swift test --package-path native
swift build --package-path native --configuration release
```

Only the Sol orchestrator commits, pushes, signs, notarizes, tags, or creates releases. Contributors make bounded changes for review.
