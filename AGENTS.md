# Steve contributor guidance

Steve is a macOS native SwiftUI menu-bar application. Preserve these invariants:

- Swift owns presentation and the privileged service boundary. Messages access stays in vendored IMsgCore and Codex credentials remain owned by the installed Codex App Server.
- Never send a live iMessage from tests or development fixtures. Production sending is gated by completed onboarding, exact chat pairing, and the active permission boundary.
- Never store ChatGPT tokens. Authentication belongs to `codex app-server`.
- Treat the workspace root and paired chat as security boundaries. Canonicalize paths and fail closed on sender/chat mismatches.
- Keep protocol fixtures deterministic. Prefer unit and functional tests over broad smoke tests.
- Do not add private Messages APIs or SIP-disabling behavior. Steve uses read-only Messages database access and public AppleScript-backed sending.

Run before handing work back:

```sh
swift test --package-path native
swift build --package-path native --configuration release
```

Only the Sol orchestrator commits, pushes, signs, notarizes, tags, or creates releases. Contributors make bounded changes for review.
