# Validate an installed Steve

Run unit tests first. These checks then exercise the installed app, actual Mac session, and an explicitly authorized private iMessage conversation. Do not run them against another person's account or send messages until the operator has authorized the exact destination. They are manual acceptance scenarios, not an automatic sender.

For each scenario, record the installed build identity, start/end time, observed result, artifact verification, and any blocker in a **private** log. A source test, successful process exit, or queued message is not proof of delivery. Do not publish raw conversations, login screens, account identifiers, or unreviewed recordings.

| Scenario | Action | Required evidence |
| --- | --- | --- |
| Setup | Run installed `setup --non-interactive --json`, complete the human steps, and run it again. | Existing choices preserved; accurate missing steps; one running gateway. |
| Exact pairing | Pair the authorized chat; send an inert status request from an unpaired fixture when separately authorized. | Paired reply received; unpaired chat cannot execute a task. |
| File delivery | Ask for a new text file containing a unique test marker. | Exact bytes in the Mac workspace and the received iMessage attachment. |
| Browser approval | Request a public HTTPS page through the installed official tool with site approval set to ask. | Scoped approval reaches the phone; explicit decision resolves once; unsupported prompts cancel without inventing a saved user denial. |
| Browser result | After approval, read the page heading and return a screenshot. | Fresh visible page evidence, readable received image, existing profile preserved. |
| Pause | Start a harmless multi-step task, then send `/stop`. | Prompt cancellation; no later unapproved action or stale artifact delivery. |
| Restart | Restart with queued work and with a deliberately interrupted test operation. | Queued work survives; ambiguous effects are reported and never automatically replayed. |
| Preference | Explicitly save a harmless formatting preference, inspect it, then forget it. | Persistence across restart and absence after forgetting; no inferred fact or credential stored. |
| Reminder | Schedule a short one-time reminder in an explicit timezone. | Exactly one received reminder, durable outcome, and no duplicate after restart. |
| Recurring task | Schedule a harmless workspace task, miss several intervals, then restart. | One coalesced run, correct next occurrence, real task and delivery result; unresolved outcomes block further runs. |
| Phone takeover | Open the private link in iPhone Safari, control an inert test form, disconnect, expire, and revoke. | Worker paused before capture/input; no recorded or model-visible typing; end states stay paused unless explicitly resumed. |
| Task video | On an explicitly selected display, record a short non-sensitive TextEdit demonstration and send it. | Visible recording indicator, valid H.264 MP4, exact task outcome, received native attachment, actual iPhone playback. |
| Video audio | Repeat with a brief known system sound and `--audio`. | Audible AAC track in the received clip; no microphone recording. |
| Video privacy | Cancel through the indicator and request phone takeover during a harmless recording. | No incomplete clip delivered; input/capture permit closed; discarded files absent. |
| Link test request | Review a fictional purchase envelope and use only the supported test-mode adapter. | Exact test amount/items, stable operation identity, no real charge, no credential-bearing output in model/chat/logs. |

Keep the browser's saved permissions intact unless the user explicitly asks to change them. A blocked origin cannot be retested through another browser surface as a workaround. A new approval test requires the user's chosen permission setting.

The default recording budget is 24 MiB and the maximum duration is 120 seconds. These are product limits, not a claimed universal iMessage size limit. A video proves only what it shows; separately inspect the resulting file, state, or receipt.
