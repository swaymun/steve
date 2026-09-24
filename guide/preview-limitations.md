# Current support and limits

Steve supports iMessage tasks, concurrent research, native browser and app use, reminders, connected email and calendar reads, and file, screenshot, and video delivery. See [setup](setup.md) for supported hardware, account requirements, and permissions.

The current implementation has these limits:

- **One paired conversation:** Steve accepts tasks from one paired direct chat. Group chats and messages sent by Steve's own Messages account are ignored, so use a separate Messages account on Steve's Mac.
- **Shared desktop:** computer workers can overlap, but they see the same Mac and browser profile. Independent windows and apps work best; simultaneous edits to one page may interfere. Phone sign-in temporarily pauses workers for private input. Native helpers handle public research only and require compatible Codex support; workers work alone when helpers are unavailable.
- **Short recordings:** video has a 120-second maximum and a default 24 MiB delivery budget. Resizing, hiding, or closing the selected window cancels its recording. System audio is available with explicitly requested display recording; microphone recording is unavailable. See [video setup](setup.md#video-evidence).

Physical-device checks and workflows not exercised during release testing are tracked in [live validation](live-validation.md#validation-coverage). An untested workflow is not necessarily unsupported or broken.
