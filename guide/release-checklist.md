# Release acceptance

This is an acceptance checklist, not a claim of completed validation.

- Native fixture tests and optimized build pass from the final source commit.
- A clean source installation works without developer paths, credentials, or local caches.
- The CLI reports missing dependencies and human steps accurately; repeated setup preserves configuration.
- The installed app sends and receives only through an explicitly authorized paired private conversation.
- Stop, resume, revocation, app restart, watcher recovery, uncertain execution, and partial delivery are exercised on the installed Mac build.
- Browser work uses the actual installed Computer Use capability. Relay tool restrictions are inspected live; configuration flags alone do not prove universal tool isolation.
- Phone takeover is tested in iPhone Safari against the actual Mac session: login, pause, disconnect, expiry, revocation, and explicit resume with fresh inspection.
- Persistent preference and schedule operations have durable outcomes, timezone/restart tests, and real message delivery acceptance.
- Link setup and test-mode payment flows are verified without a real charge. Real purchases require separate exact authorization and receipt evidence.
- The complete public tree and fresh history are scanned for secrets and personal information. Private diagnostics, old handoffs, histories, screenshots, and evaluation PDFs stay private.
- The original repository remains preserved privately. The public repository has the intended license and only main after landing.
- Public release artifacts are signed, notarized, stapled, assessed, and hashed as the final downloadable archive. Source builds and locally signed development bundles are not called notarized releases.
- The signed app includes the Apple Events entitlement required by hardened runtime, and a real authorized Messages reply succeeds from that build. The entitlement does not replace the user's Automation permission grant.
- Task evidence can be recorded and sent as an actual iMessage video attachment, with verified iPhone playback, bounded duration and size, compression/conversion, and optional requested system audio. Login/takeover intervals are excluded; a video supplements explicit outcome verification.
- The technical article describes the final implementation and labels remaining acceptance gaps. Screenshots and examples are reviewed for public disclosure.
