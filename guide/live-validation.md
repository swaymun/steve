# Validate an installed Steve

Run unit tests first. These checks then exercise the installed app, actual Mac session, and an explicitly authorized private iMessage conversation. Do not run them against another person's account or send messages until the operator has authorized the exact destination. They are manual acceptance scenarios, not an automatic sender.

For each scenario, record the installed build identity, start/end time, observed result, artifact verification, and any blocker in a **private** log. A source test, successful process exit, or queued message is not proof of delivery. Do not publish raw conversations, login screens, account identifiers, or unreviewed recordings.

## Validation coverage

The v0.1.6 cycle exercised self-owned email replies and calendar writes, reminders, memory, cancellation, browser tasks, document delivery, and staged shopping without a purchase. Its exact released build passed Luna PDF/browser checks and independent Astra browser/calendar checks. Earlier videos were decoded and reviewed on a Mac, and the user confirmed playback in their Messages chat; video and physical iPhone continuation were not reverified in v0.1.6. Completed reservations and purchases remain untested. Keep evidence attributed to its actual build. These are coverage gaps, not confirmed product restrictions.

Account sign-in problems should be diagnosed separately from Steve's controls. A website's phone-number or verification requirement does not by itself establish a Steve login bug. Keep personal account details in private logs.

## Acceptance scenarios

### Onboarding: Steve's additional dimension

Treat onboarding as a seventeenth **Steve-specific** dimension alongside the 16 Assistant Benchmark dimensions, not as part of that benchmark's official rubric. Its success is the first useful, observed result—not a saved address or a dismissed setup screen. Keep raw evidence private.

- Fresh installation: choose one owner during setup, optionally name the agent and describe its personality. Defaults work without extra questions.
- Start with “hey” or “Open example.com.” No code, command syntax or technical coaching on an owner-capable build. The greeting is generated in the chosen style; an actual first task is preserved and executed.
- Inspect both agent profiles' instructions and actual replies for the chosen identity. Runtime status, security errors and transport acknowledgments remain factual fixed messages; task outcomes must not be scripted by test topic.
- Reject other senders, SMS, groups, sent-by-me messages, old synced history and a second private chat. An owner change cannot silently replace a connected conversation.
- Restart before and after first contact; repeat installation; change name/style; preserve pairing, settings, grants, queued tasks and workspace. Disconnect must remove automatic owner authorization as well as the chat binding.
- Test a missing Messages grant, denied Automation and an unavailable model. Explain the real next step and retain the first task without falsely declaring setup complete.
- Record time to first useful result, required human steps, unnecessary questions, address mistakes, unsupported assumptions and assisted recovery. Do not count simulated transport as live iMessage acceptance.

See [setup compatibility](setup.md#2-messages-access-and-pairing): v0.1.6 uses the legacy code flow. The signed v0.1.7 build 19 passed fresh Steve-state owner selection, a first-message native browser task, the chosen name, repeated setup, and a browser follow-up after restart on the Mac Mini. These checks reused existing macOS grants; granting permissions from scratch and physical iPhone continuation remain separate acceptance checks.

The v0.1.7 runtime checks also verified that internal conversations stay in Steve's private runtime, without adding tasks to the desktop Codex history. An earlier v0.1.7 candidate exercised existing conversation import, browser work, restart, and a calendar read before the final fresh-state checks. Keep migration evidence separate from a fresh installation.

### Runtime scenarios

| Scenario | Action | Required evidence |
| --- | --- | --- |
| Setup | Run installed `setup --non-interactive --json`, complete the human steps, and run it again. | Existing choices preserved; accurate missing steps; one running gateway. |
| Exact pairing | Pair the authorized chat; send an inert status request from an unpaired fixture when separately authorized. | Paired reply received; unpaired chat cannot execute a task. |
| File delivery | Ask for a new text file containing a unique test marker. | Exact bytes in the Mac workspace and the received iMessage attachment. |
| Readable documents | Ask for a short guide without specifying a file format, then explicitly request its Markdown source. | First reply uses plain text and delivers a readable PDF with intact content and links; Markdown is sent only for the explicit follow-up. Inspect the actual received files. |
| Browser approval | Request a public HTTPS page through the installed official tool with site approval set to ask. | Scoped approval reaches the phone; explicit decision resolves once; unsupported prompts cancel without inventing a saved user denial. |
| Browser result | After approval, read the page heading and return a screenshot. | Fresh visible page evidence, readable received image, existing profile preserved. |
| Concurrent goals | Start substantial public research, then ask an unrelated question and start a second task. | Two distinct task/thread identities, overlapping work, responsive relay, separate correct deliveries. |
| Task correction and cancel | Correct one active goal, then cancel a named goal while another is running. | Correction reaches its owner; only the named task stops; unrelated work finishes; no stale result replaces the correction. |
| Shared Mac | Queue two visible-browser tasks alongside research. | Only one computer owner; second GUI task starts after the first becomes quiescent; background research continues. |
| Research handoff | Ask a background research task to save its findings as a file. | Same task context resumes with verified computer access; original sources remain available; received file matches the workspace. |
| Model settings | Change the operator profile while a task runs, then start another task. | Existing turn retains its model; new turn uses the selected profile; relay profile remains independent. |
| Native screenshot | Ask for a screenshot of the observed browser result. | Current-turn native image is selected explicitly, delivered, and visually checked; no upload server or old capture is substituted. |
| Native helpers | Give an operator a useful independent research subtask. | Actual native spawn/join/close, parent lineage, configured count/depth, no helper shell/desktop/integrations; unsupported versions continue alone. |
| Pause | Start a harmless multi-step task, then send `/stop`. | Prompt cancellation; no later unapproved action or stale artifact delivery. |
| Restart | Restart with queued work and with a deliberately interrupted test operation. | Queued work survives; ambiguous effects are reported and never automatically replayed. |
| Preference | Explicitly save a harmless formatting preference, inspect it, then forget it. | Persistence across restart and absence after forgetting; no inferred fact or credential stored. |
| Reminder | Schedule a short one-time reminder in an explicit timezone. | Exactly one received reminder, durable outcome, and no duplicate after restart. |
| Recurring task | Schedule a harmless workspace task, miss several intervals, then restart. | One coalesced run, correct next occurrence, real task and delivery result; unresolved outcomes block further runs. |
| Phone takeover | Open the private link in iPhone Safari, control an inert test form, disconnect, expire, and revoke. | Worker paused before capture/input; no recorded or model-visible typing; end states stay paused unless explicitly resumed. |
| Task video | Inventory TextEdit windows, select the exact harmless task window, record it without display fallback, and send it. | Only the selected window appears, visible recording indicator, valid H.264 MP4, exact task outcome, received native attachment, and playback checked on the receiving device. |
| Video audio | With separate authorization for full-display and system-audio scope, repeat on an explicitly selected display with a brief known sound and `--audio`. | Audible system sound in the received clip, no microphone recording, and playback checked on the receiving device. |
| Video privacy | Cancel through the indicator and request phone takeover during a harmless recording. | No incomplete clip delivered; input/capture permit closed; discarded files absent. |
| MCP integration | Configure and authenticate an authorized MCP server in Codex on Steve's Mac, relaunch Steve, and request a harmless read. | The operator discovers the actual tool and returns its observed result; relay and research-helper restrictions remain intact. |

Keep the browser's saved permissions intact unless the user explicitly asks to change them. A blocked origin cannot be retested through another browser surface as a workaround. A new approval test requires the user's chosen permission setting.

The default recording budget is 24 MiB and the maximum duration is 120 seconds. These are product limits, not a claimed universal iMessage size limit. A video proves only what it shows; separately inspect the resulting file, state, or receipt.
