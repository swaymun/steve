# Set up Steve on a Mac

The default path is **install and launch → pair iMessage → enable native Computer Use → verify a browser task**. A local agent can perform the installation and open permission settings. You complete login, grant macOS access, choose the owner, and send the first ordinary iMessage.

Use the tested account arrangement: Messages on Steve's Mac is signed in to a separate account from the person texting Steve. Same-account self-messaging is outside this setup flow; messages marked as sent by the Mac's own account are ignored. Keep the Mac awake and Steve running in its signed-in user session.

## Guide the first conversation

The local setup agent owns onboarding through the first useful result. Start by explaining the purpose in ordinary language: finish the access checks together while the user is at the Mac, so a request sent later does not get stuck behind a permission prompt. Offer an agent name and personality without making either a required interview.

Use Astra in the local Codex desktop app when available. Ask short structured questions using the host's question tool; ordinary chat is the fallback. Do not assume the tool exists just because a model was selected. Ask one choice at a time, wait for permission confirmations, and continue independent inspection while waiting. Structured asynchronous questions depend on the installed host and model catalog ([Codex documentation](https://learn.chatgpt.com/docs/changelog)).

1. Install, launch, and inspect Steve using the steps below. Explain each required grant when it is needed: Steve reads incoming Messages with Full Disk Access and sends replies through Messages Automation; native Computer Use separately needs Screen Recording to see apps and Accessibility to operate them. Open one pane at a time, identify the exact app, and let the human grant access. Reuse working grants.
2. After each human action, continue the same setup, recheck once, and handle the next remaining step. Relaunch Steve after Full Disk Access when needed. Do not finish the task with an unexplained command or a generic list of permissions.
3. Configure the one owner the user chose, then ask them to send a short greeting or a useful first request to the verified receiving address. Observe whether the exact conversation connects and the reply arrives. The Automation consent may appear on this first authorized reply; guide that handoff without sending an extra probe.
4. If the user starts with a greeting, offer one harmless browser sample in ordinary words. Let their acceptance start it through Steve. If their first message already asks for a browser task, use that as the sample. A plain “yes” should be enough; do not require command syntax or a prescribed technical prompt. When the installed release does not offer a sample itself, the setup agent supplies this invitation and stays with the user through the task.
5. Observe Steve's own native Computer Use task and the received result. Do not substitute a browser task run directly by the setup agent. If access fails, explain the specific missing grant, open its pane, and continue the same task after the human acts. Only then confirm that messaging and browser control worked, explain that the Mac must stay awake and signed in with Steve running, and invite the next ordinary request.

Keep the welcome and replies model-written, brief, and specific to what actually worked. Avoid a fixed greeting script, repeated acknowledgments, or a blanket claim that everything is ready. Video, private phone control, email and calendar connections are separate choices; offer to set them up before the user leaves only when wanted. A browser test does not verify those capabilities.


### When the first message gets no reply

Check Steve's status and required blockers first. If it is waiting for the owner, verify the actual sender of that specific newly sent test message on the receiving Mac, using Messages or narrowly scoped local diagnostics. Keep addresses and message evidence private; do not inspect unrelated conversations. The sending device's “Start new conversations from” preference alone is insufficient: an existing conversation or account issue can still send from an email instead of the chosen number.

Explain the mismatch and let the user choose to correct the sending identity or replace the sole owner with the observed address. Never silently broaden the allowlist. Apply an owner change only with explicit approval and while still unpaired; changing an already connected owner requires the documented disconnect flow. Ask for a fresh message afterward, since older messages must not become newly authorized. If the sender is correct, diagnose the actual Messages/Automation or task error rather than repeatedly asking for Full Disk Access. Preserve an unresolved blocker and the exact human next step; do not claim onboarding is complete.

## Install a release

The [v1.0.0 release](https://github.com/swaymun/steve/releases/tag/v1.0.0) contains a Developer ID-signed, Apple-notarized app for **Apple silicon (arm64), macOS 14 or later**. Native Computer Use has separate availability and macOS requirements; inspect its installed app and supported Codex setup flow. Intel builds have not been validated.

### Discover the right download

Use the [published releases list](https://api.github.com/repos/swaymun/steve/releases), including prereleases, to find the newest compatible release. `/releases/latest` and `releases/latest/download` exclude previews and may miss a newer compatible app.

An agent should inspect published, non-draft releases in descending version order and choose the newest compatible one. Check the Mac's architecture and macOS version against the release notes, and require both `Steve-macOS.zip` and `Steve-macOS.zip.sha256` in that same release. GitHub's automatic source ZIP/tar archives are not the app. If no compatible app exists, explain the source-build option rather than claiming there is no release.

For this version: [download the app ZIP](https://github.com/swaymun/steve/releases/download/v1.0.0/Steve-macOS.zip) and [its checksum](https://github.com/swaymun/steve/releases/download/v1.0.0/Steve-macOS.zip.sha256). In the download folder:

```sh
shasum -a 256 -c Steve-macOS.zip.sha256
ditto -x -k Steve-macOS.zip .
codesign --verify --deep --strict --verbose=2 Steve.app
spctl --assess --type execute --verbose=2 Steve.app
xcrun stapler validate Steve.app
```

Require `Steve-macOS.zip: OK`, a valid signature, and Gatekeeper acceptance as a notarized Developer ID app. The stapler check is useful if Xcode command-line tools are already installed; a release installation does not require installing a Swift toolchain. Inspect the bundle version and identifier (`com.swaymun.steve`). If verification fails, stop and report the actual failure; do not remove quarantine or bypass Gatekeeper.

Inspect an existing installation before replacing it. Preserve `~/.steve`, its queued work and schedules, workspace, pairing, and settings. Quit an idle Steve before replacement. Keep a temporary app rollback outside Applications until the updated app is verified, then remove it. Do not keep accumulating backup apps in Applications.

Move Steve.app to `/Applications` or preserve an existing `~/Applications` location, then **launch it before running setup**:

```sh
steve_app=/Applications/Steve.app
open "$steve_app"
steve_cli="$steve_app/Contents/MacOS/Steve"
"$steve_cli" setup --non-interactive --json
```

If the app is still starting and the socket is unavailable, check that it launched, then retry once it is running. Do not start a second Messages process. A download does not install a shell wrapper: **`steve` below means this installed executable**, not a command guaranteed to be on PATH.

## CLI onboarding

The CLI talks to a user-owned local socket in the running app. That app owns the macOS permission grants. The CLI does not independently read Messages or copy Codex credentials.

Responses contain `state`, `summary`, `checks`, and optional `values`, `tasks`, and `models`. The `models` catalog includes IDs, display names and supported reasoning levels from the signed-in account. An empty catalog is not permission to guess: finish Codex login and refresh doctor first. Current coordinator/worker values have legacy aliases for older clients. States are `ready`, `needs_user_action`, `blocked`, and `failed`; exit codes are 0 for ready, 2 for attention, and 1 for errors. Inspect the JSON even when exit code 2 is returned. `--json` and `--non-interactive` never prompt for terminal input; an explicit permission-opening command still opens macOS Settings.

### 1. Account and access choices

Run setup without options to inspect what is missing. Preserve existing choices. If needed, choose a workspace and access profile in plain language, then apply only those choices:

```sh
steve setup --workspace "$HOME/SteveWorkspace" --permission workspace-write --json
```

The profiles are Read Only (`read-only`), Workspace Write (`workspace-write`), and Full Access (`danger-full-access`). Full Access allows routine commands without individual command approval, but does not authorize unrelated purchases, bookings, messages, or account changes. Do not enable it silently. Use the existing browser profile. Select models/effort only from the account's current catalog.

Reuse the existing Codex sign-in. Only if sign-in is missing, run `steve setup --login --non-interactive --json` and let the user finish the official browser flow. Keep returned login URLs private. Login pauses Steve; after authentication, run doctor, then `steve start --json` when ready to resume. Never ask the user to paste ChatGPT tokens or passwords.

Then offer recommended models or customization. For a new installation, recommend a **GPT-6 Luna Low Fast coordinator, GPT-6 Sol Xhigh Standard workers, two concurrent workers, and one research helper per eligible worker**. Fast consumes more allowance. Apply this recommendation only if accepted and supported by the returned `models` catalog; do not overwrite an existing profile by default. For customization, ask about the worker model first, then reasoning/speed, coordinator, and concurrency as needed. A user who accepts the recommendation does not need a separate question for every setting. See [model and concurrency settings](#coordinator-and-worker-settings).

### 2. Messages access and pairing

Open Messages on the Mac and confirm its separate receiving account. If Messages access is denied:

```sh
steve setup --open-permission full-disk-access --json
```

The helper opens the pane and reveals the installed Steve bundle. The user adds/enables that exact app under Full Disk Access, then relaunches Steve. A grant to Terminal or Codex does not transfer to Steve. A changed signing identity can require the user to remove a stale permission entry and add the current app; do not reset TCC automatically.

**Release compatibility:** v0.1.7 adds owner selection, names and personalities. Inspect the installed executable's `--help` before using these options; v0.1.6 and earlier use the code fallback below. Prefer the compatible signed release.

If its help includes `--owner`, ask which exact iMessage address the user will send from. Configure one owner, with optional name and style:

```sh
steve setup --owner 'owner@example.com' --agent-name 'Olive' --personality 'Warm and concise' --non-interactive --json
```

Use the user's actual chosen address. Phone numbers require the country code. Name and personality are optional and can be changed later in the menu's Agent section or with the same flags. An empty `--personality ''` restores the default style. These choices never change permissions. Do not infer a second owner or choose an address from a website or email.

The user sends a normal private message to the returned `receiveAddress` from the allowed address. A greeting works; a task is handled as a task, without being consumed by a pairing handshake. Steve binds that exact chat after observing the message. Old synced history, SMS, groups, messages from the receiving account and other senders cannot connect. Repeating setup preserves an existing connection; disconnect explicitly before replacing an owner.

For v0.1.6 or when deliberately choosing the code fallback, create a short-lived pairing code:

```sh
steve setup --pair --non-interactive --json
```

On that fallback, the user sends the displayed code from their phone in a private iMessage to the returned receiving address. Verify the actual reply on either path. macOS may ask whether Steve may control Messages; the user allows that prompt. If permission was denied, `steve setup --open-permission messages-automation --json` opens Automation so the user can enable Messages under Steve. That entry may not exist until Steve first requests access during an authorized reply. The helper itself sends no message.

Do not generate a new code if the exact intended conversation is already paired. Do not publish codes or receiving addresses. Group chats and messages sent by the receiving account cannot pair. Fixture tests never send messages; any separate live test requires authorization for its exact destination.

### 3. Native Computer Use

Install and enable the official **native Computer Use** capability through Codex's supported app flow. Follow [Computer Use setup](https://learn.chatgpt.com/docs/computer-use). Do not install a Chrome extension, copy private runtime components, or revive the old browser bridge.

Open its separate permission panes:

```sh
steve setup --open-permission computer-use-screen-recording --json
steve setup --open-permission computer-use-accessibility --json
```

Run one command, finish that grant, then run the next. The helper derives the app's actual display name and path from the discovered installation; it may be displayed as ChatGPT Computer Use. Add that native app, not Steve or the nested command-line helper. Follow any macOS relaunch request. Install Google Chrome if needed for the current browser workflow and use the existing profile.

### 4. Check configuration, then verify a task

```sh
steve doctor --json
steve status --json
```

Resolve required `blocked` or `needs_user_action` checks. Report failures accurately; distinguish a database error from missing permission or account sign-in. After a human handoff, recheck once the user has acted. Do not loop repeatedly on an unchanged missing grant.

`computer_use: ready` means its executable is installed. The separate `computer_use_live: unverified` check has `required: false`: Steve cannot inspect another app's permissions or prove a working browser session. **Repeating doctor will not verify this check.** Likewise, optional Tailscale, video, and phone-control checks do not block ordinary setup. A `ready` CLI result establishes configuration readiness, not end-to-end acceptance.

Have the user text Steve:

> Open example.com and tell me the heading.

Confirm the native Computer Use session opens the page and the reply reports the observed **Example Domain** heading. A plausible reply alone is not proof that the browser was used. Only then call the default onboarding complete. If Computer Use cannot be installed or the live task fails, report the specific remaining step and describe messaging as ready separately.

## Permission helper reference

Available in v0.1.2 and later. Run `setup --open-permission TARGET --json` by itself, without other setup options. Invalid or mixed requests fail before changing settings or opening a pane. Ordinary setup, doctor, and status never open Settings automatically.

| Target | App to grant access to | Purpose |
| --- | --- | --- |
| `full-disk-access` | Installed Steve.app | Read the Messages database |
| `messages-automation` | Steve → Messages | Send the pairing reply and authorized results |
| `computer-use-screen-recording` | Installed native Computer Use app | View browsers/apps |
| `computer-use-accessibility` | Installed native Computer Use app | Operate browsers/apps |
| `steve-screen-recording` | Installed Steve.app, optional | Video evidence and phone control |
| `steve-accessibility` | Installed Steve.app, optional | Phone-control input |

The response returns `values.permissionTarget`, `appName`, `appPath`, `settingsOpened`, and `nextStep`; a missing app omits the name/path and explains how to install it. `settingsOpened: "true"` means macOS accepted the open request, not that a grant was made or the exact pane was selected. If the pane is wrong or opening fails, follow the returned manual path under System Settings → Privacy & Security. The response remains `needs_user_action` because the user owns the grant. No TCC changes or permission bypasses are performed.

See the [permissions and privacy table](../README.md#permissions-and-privacy). Permissions granted to Computer Use do not apply to Steve's optional features, or vice versa.

## Everyday control

Use normal messages for tasks and “yes”/“no” for a pending decision. Internal approval IDs are available in the CLI for diagnostics, but are not needed in ordinary messages. A status reply describes current work first, with prior failures labeled History. Unconfirmed outcomes need review and are not automatically rerun.

`steve stop` cancels active and queued requests and pauses Steve; `steve start` accepts new work again. In iMessage, say “stop” or “resume.” These do not quit or relaunch the app; use its Quit action to shut down cleanly.

## Coordinator and worker settings

The coordinator keeps the iMessage conversation and routes work. On a fresh installation its default is **GPT-6 Luna, Low, Fast** when that model is available in the signed-in Codex account. Workers default to **GPT-6 Sol, Xhigh, Standard**. If the automatic coordinator model is unavailable, Steve uses the selected worker profile; an explicitly selected unavailable coordinator model fails clearly. Existing installations keep their saved choices.

Change these independently in Steve's menu-bar settings or through the installed CLI:

```sh
steve setup --coordinator-model gpt-6-luna --coordinator-effort low --coordinator-service-tier fast --json
steve setup --worker-model gpt-6-sol --worker-effort xhigh --worker-service-tier standard --json
steve setup --max-workers 2 --max-helpers 1 --json
```

The v1.0 CLI prefers `--worker-model`, `--worker-effort`, `--worker-service-tier`, `--coordinator-model`, `--coordinator-effort`, `--coordinator-service-tier`, and `--max-workers`. Legacy `--model`, `--effort`, `--service-tier`, `--relay-*`, and `--max-operators` still work; specify a choice only once. Existing settings and storage keys are preserved.

Use `--coordinator-model auto` to restore automatic selection. The model and effort must be supported by the current account. Standard is the worker's default service tier and Fast is the coordinator's fresh-install default; Fast consumes more Codex usage. Changing agent settings applies to future turns and preserves pairing, permissions, schedules, and work already running.

Steve defaults to two active workers (configurable from one to four) and one native research helper per background worker (zero to two). Helpers have one level of delegation and only public web research tools. When the installed App Server cannot support helper lineage, the worker works alone. Current source lets computer workers overlap on the shared Mac, so independent windows or apps are best; v1.0.0 still runs computer tasks one at a time. A live phone sign-in temporarily holds new computer work; research can continue. Helpers are disabled for computer workers.

Ask naturally: “Also compare the train options,” “For the hotel search, keep it under $200,” or “Cancel the hotel search.” Steve keeps unrelated goals separate, routes corrections to their owner, and asks which task only when the reference is ambiguous. `/stop` cancels active and queued requests and pauses scheduled execution. It does not delete schedules. Resuming does not restart cancelled requests. An uncertain action is never automatically repeated after a crash or interruption.

## Build from source

Use source builds only when needed. Inspect the checkout and follow contributor instructions. Install Apple's command-line tools/Xcode if the Swift toolchain is missing; follow the [official Codex installation instructions](https://developers.openai.com/codex/cli/).

```sh
swift test --package-path native
./scripts/install.sh --bin-dir "$HOME/.local/bin"
open "$HOME/Applications/Steve.app"
"$HOME/Applications/Steve.app/Contents/MacOS/Steve" setup --non-interactive --json
```

The installer preserves data and workspace, defaults to `~/Applications/Steve.app`, and removes the temporary app rollback after its signature/CLI checks succeed. Failed verification restores the previous app. Source builds are ad hoc signed unless an existing identity is explicitly selected with `--signing-identity`; changing identity can require fresh macOS grants. Source installation does not imply live acceptance. Quit Steve before replacement or pass `--replace-running`. The optional shell wrapper is installed only with `--bin-dir`.

## Optional Tailscale setup

Offer this during onboarding: “Would you like to finish website sign-ins from your phone when you’re away?” If the user skips it, ordinary messaging and Computer Use can still be verified, but explain that future sign-ins may require returning to the Mac. If accepted, stay through both devices’ setup and an actual control/continue check; a connected Mac alone is insufficient.

Basic iMessage operation does not require Tailscale. Phone browser access requires a private network connection. The [recommended standalone macOS app](https://tailscale.com/docs/install/mac) includes the CLI. Install Tailscale on the phone too, use your own account, and complete the operating system's VPN approval. The account and VPN setup remain human steps.

```sh
steve setup --tailscale-connect --non-interactive --json
steve doctor --json
```

The explicit connect flag runs a bounded `tailscale up` and reads its status. It does not reset routing, switch accounts, enable Funnel, or overwrite Serve routes. Existing nondefault settings may require finishing setup in Tailscale's app. See the [Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli). A connected tailnet alone is not proof that phone takeover is configured.

## Phone control in Safari

Open `steve-screen-recording` and `steve-accessibility` with `setup --open-permission TARGET --json`, one at a time, when those grants are missing. Wait for the user’s confirmation before rechecking. Preserve Computer Use’s separate existing grants.

After connecting Tailscale on both devices, enable private HTTPS and generate a one-time link:

```sh
steve setup --phone-access --non-interactive --json
steve phone --json
steve phone --disconnect --json
```

Once phone access is configured, ask Steve in the paired iMessage conversation for a phone-control link. If Steve is paused, first say "resume", then ask for the link. Steve sends a private, one-use Safari link that expires after two minutes. The link is not included in model inputs or Steve's SQLite outbox; it remains in your private Messages history. Requesting a link does not grant control or pause the worker; claiming it does. If delivery is uncertain or the link expires, ask for a new one.

For a login, ask Steve to open the site's sign-in page. When the worker verifies that page and phone access is configured, Steve automatically offers the private link. Open it in Safari with Tailscale connected and tap **Take control**. The verified login briefly reserves computer control so another task cannot replace the page. You are operating the same browser session on the Mac, so your successful login remains available there. Tailscale supplies the private network connection behind the URL; it is required on the phone even though the interface is a web page.

The setup command uses an unused HTTPS port (8443 or 10000), preserves other Serve routes, and refuses a conflicting or publicly exposed Funnel route. Tailscale may require enabling HTTPS in your account before setup succeeds. The backend listens only on loopback. The link contains a short-lived secret: keep it private. You can also show a QR code from Steve’s connected-phone menu.

Steve needs its own Screen Recording and Accessibility grants for this feature. The separate Computer Use app’s grants do not apply to Steve. Open an existing Chrome window before pairing. Safari shares the display containing that window, including other visible apps and password-manager popups. Inputs and live images are not written into the model conversation or recording artifacts.

Taking control pauses and drains the worker. Disconnect, expiry, revocation, and system lock leave it paused. After completing the verified login, tap **Done — continue** or send an ordinary signed-in reply to resume verification in the same task. An interrupted action is never automatically replayed, and an expired or disconnected session remains paused until you explicitly continue. Real iPhone Safari login, keyboard, and lock behavior remain release acceptance checks.

## Video evidence

For an explicitly requested task demonstration, the native recorder creates H.264 MP4 video. Exact-window capture is the default: inventory the named app's visible windows, choose the verified task window, and record only that window. Steve decodes the output locally and checks size and duration before returning a workspace artifact. The coordinator can select that artifact for native iMessage delivery. Video is evidence of what happened; it does not replace checking the task’s actual result.

```sh
steve video windows --app BUNDLE_ID --json
steve video start --demonstration --window WINDOW_ID --app BUNDLE_ID --seconds 30 --json
steve video stop RECORDING_ID --json
steve video cancel --json
```

Window capture excludes the desktop and other windows, does not include child windows or audio, and cancels if the selected window is resized, hidden, closed, or replaced. Do not guess a window ID or fall back to a wider scope when the requested window is unavailable. Full-display capture requires separate, explicit authorization for everything visible on that display: `steve video start --demonstration --display DISPLAY_ID --seconds 30 --json`. Add `--audio` only when system sound was also explicitly authorized; it is available only with display capture. Microphone recording is not supported. Finish permissions and authentication before recording; cancel before any login, sensitive input, or phone takeover. The visible recording indicator also offers cancellation.

The default delivery budget is 24 MiB, with a maximum recording duration of 120 seconds. These are Steve’s limits, not an Apple-published iMessage attachment limit. Exceeding a limit discards the unfinished clip. Short demonstrations with and without system audio have been received and fully decoded on another Mac; Messages converted the H.264 MP4 to a HEVC MOV and retained the AAC audio. The user also confirmed playback in their Messages chat. Do not assume the received file has the source codec, extension, or bytes. Apple documents inline video attachments in [Messages on Mac](https://support.apple.com/guide/messages/send-images-ichtb967d30b/mac).

## Saved preferences

Clearly stated lasting preferences can be saved alongside an ordinary task; you can also ask Steve to remember, list, change, or forget one directly. Steve projects active preferences and adopted plans into a private `STEVE_MEMORY.md` inside the configured workspace. It creates the file with restricted permissions, refuses symlinks or an existing user-owned/tracked file, and adds a verified Git exclusion. Keep the file private. The durable database remains authoritative, so do not edit the projection directly.

Forget removes the active saved preference from Steve; it does not erase earlier iMessages or Codex conversation history. Preferences and plan context never authorize purchases, account changes, messages, bookings, or other actions.

## Reminders and scheduled tasks

Ask normally: “Remind me in two minutes to check the oven.” For a clock time, Steve uses your requested timezone, a saved timezone preference, or the Mac’s local timezone and shows the date-correct abbreviation (for example, EST/EDT or PST/PDT) in the confirmation. The original unset UTC default falls back to the Mac’s zone; explicit non-UTC settings are preserved. If needed, say “Remember that my timezone is Eastern time.” You can also ask Steve to list or cancel schedules in normal language. The Mac and Steve must be running for execution; after downtime, missed recurring occurrences are coalesced instead of replaying every missed run.

Schedules remain bound to the paired chat, workspace, and permission choices. An uncertain task or delivery outcome blocks later automatic occurrences until reviewed. Live checks verified a one-time reminder across restart and a recurring reminder paused across restart with zero executions. Daylight-saving transitions still need separate installed-device acceptance.

Steve can adopt a dated plan from an ordinary request and perform read-only follow-ups at a known meaningful next-check time, then daily at 9:00 AM in the plan's timezone. Follow-ups stay quiet from 10:00 PM through 8:00 AM unless a verified deadline falls before morning; an explicit reminder time is unchanged. Steve sends only a verified meaningful change, deadline, blocker, or decision. Taking the plan back yourself, cancelling its task, expiration, or an uncertain outcome stops later automatic checks.

## MCP integrations

Steve's computer-enabled workers inherit MCP servers configured in Codex on the Mac running Steve. Add a compatible server through Codex's normal MCP configuration, complete its authentication, and verify it with `codex mcp list`. User configuration normally lives in `~/.codex/config.toml`; trusted workspace configuration can also apply. See the [official Codex MCP setup guide](https://developers.openai.com/codex/mcp/) for local STDIO and remote HTTP servers, authentication, and tool settings.

You can ask your setup agent: “Connect this service's MCP server to Codex on this Mac, then verify Steve can use it.” After current tasks finish, quit and relaunch Steve to reload configuration, then try a harmless read through the paired chat. Install and authenticate on Steve's Mac under its macOS user account; configuring a different computer does not configure Steve. Local server executables and required environment variables must be available to the running app, not only an interactive Terminal session.

The coordinator and background research helpers do not get integration access; Steve routes connected work to a worker with that capability. Each server still needs compatible tools, its own dependencies and sign-in, and the appropriate account access. Adding an integration does not authorize unrelated messages, purchases, or account changes.

## Troubleshooting and data

If the CLI cannot connect, open the installed app in the active user session. A second Steve instance cannot take the local control socket. If Messages is unavailable, grant Full Disk Access to the installed bundle and relaunch; Terminal's permission does not grant the app permission.

Codex credentials belong to Codex. Steve stores settings, exact pairing, queue state, and thread IDs in `~/.steve/steve.sqlite3`. The default workspace is `~/.steve/workspace`; existing configured workspaces are preserved. Logs are under `~/Library/Logs/Steve`. Treat all of these as private. Raw benchmark histories stay local.

From v0.1.7, Steve's App Server uses `~/.steve/runtime` for its sessions and task database, so internal coordinator, worker and helper chats stay out of the desktop Codex task list. It reuses existing Codex configuration, plugins, skills and file-based authentication through local links; it never copies credentials or the desktop task database. Keychain-only setups may need to sign in once through Steve. Native Computer Use keeps its existing installation and permissions. [Codex state locations](https://learn.chatgpt.com/docs/config-file/environment-variables#core-locations).

On upgrade, a missing private thread can import its exact Steve-originated legacy transcript when resumed. Existing desktop entries are left intact; no unrelated chats are imported or deleted. The configured workspace and Steve's durable queue, preferences and schedules remain unchanged. Do not point the runtime at the desktop Codex home or link its session/database storage there.

To uninstall, quit Steve, remove the installed app and optional command wrapper, and remove its login item if enabled in macOS Settings. Keep the data directory and workspace unless you explicitly want to delete them. Deleting `~/.steve` removes private runtime history too; unlink shared setup files without following their targets, and never delete `~/.codex` as part of Steve cleanup. Disconnect the phone in Steve before handing the Mac to someone else.
