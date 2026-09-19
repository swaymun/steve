# Development preview limitations

Steve's core iMessage flow, native browser tasks, reminders, connected email reads, file delivery, and document-window recordings have been exercised on a Mac. The following features still need verification or have narrower support:

- **Messages accounts:** the tested arrangement uses a separate Messages account on Steve's Mac. Same-account self-messaging is not supported by the setup flow.
- **Phone login and control:** completing a website login through the private Tailscale page on a physical iPhone has not passed full acceptance. This feature is optional.
- **Video:** received recordings have been decoded and reviewed on a Mac. Playback on a physical iPhone remains unverified. Closing the recorded window cancels the active capture; a delivered clip may show the final state without the full editing sequence. Small text may be difficult to read.
- **Connected accounts:** email reads, calendar discovery, and event searches have been exercised through authorized connectors. Coverage depends on the connected account and its scopes. An empty response for one calendar does not establish that every calendar is clear. Sending email and changing calendar events were outside this release's live acceptance checks.
- **Concurrent work:** background research can overlap, but visible Mac and browser tasks run one at a time. Native research helpers depend on compatible Codex support; an operator continues alone when helpers are unavailable. Restarted operations with uncertain effects require review and are not replayed automatically.
- **Payments:** the optional Stripe Link adapter has deterministic fixture coverage only. It is not connected to the operator or onboarding and cannot currently make a purchase.
- **Compatibility:** the downloadable app is verified on Apple silicon. Intel source builds have not been validated. Steve requires a signed-in, awake Mac session; native Computer Use has separate availability and OS requirements.

Steve's optional Screen Recording and Accessibility grants are separate from the Computer Use app's grants. Installing an app or finding its executable does not prove its permissions work. Finish [onboarding](setup.md) with a real browser task and an observed iMessage reply.
