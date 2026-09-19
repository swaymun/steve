# Install and set up Steve

Steve runs in a signed-in macOS user session. Use an Apple account signed in to Messages on that Mac, and an installed Codex account with access to the selected model. The app must remain running for messages and scheduled tasks to execute.

## Build and install

Inspect the checkout before executing it. Install Apple's command-line tools/Xcode if the Swift toolchain is missing. Follow the [official Codex installation instructions](https://developers.openai.com/codex/cli/) and [Computer Use setup](https://learn.chatgpt.com/docs/computer-use). Computer Use must be installed and enabled through the supported app flow; executable discovery alone does not establish permission or session readiness.

```sh
swift test --package-path native
./scripts/install.sh --bin-dir "$HOME/.local/bin"
open "$HOME/Applications/Steve.app"
"$HOME/Applications/Steve.app/Contents/MacOS/Steve" setup --non-interactive --json
```

The installer defaults to `~/Applications/Steve.app` and keeps `~/.steve` and your workspace. During replacement it holds the previous app as a rollback, verifies the installed signature and CLI entry point, then removes that temporary app backup after success. A failed verification restores the previous app and retains the failed bundle for inspection. The installer does not install dependencies or select an Apple signing account automatically. Source builds use ad hoc signing unless you explicitly pass `--signing-identity`. A changed signing identity may require macOS permissions again. Use a notarized release only when one is actually published and verified.

If Steve is already running, quit it before replacement, or explicitly use `--replace-running`. An optional wrapper is installed only when `--bin-dir` is supplied. Add that directory to your own shell PATH if desired; otherwise use the executable's full path.

## CLI onboarding

The CLI talks to a user-owned local socket in the running app. It does not start a second Messages watcher, read the Messages database, or copy authentication files. JSON output has a `state`, `summary`, `checks`, and optional `values`. States are `ready`, `needs_user_action`, `blocked`, and `failed`; exit codes are 0 for ready, 2 for attention, and 1 for errors. Optional checks carry `required: false`.

```sh
steve setup --workspace "$HOME/SteveWorkspace" --permission workspace-write --json
steve setup --login --non-interactive --json
steve setup --pair --non-interactive --json
steve doctor --json
steve status --json
steve stop --json
steve start --json
```

Without flags in an interactive terminal, setup asks for a workspace and permission choice. Pressing Return preserves the existing choice. `--non-interactive` and `--json` never prompt for terminal input. Setup applies only explicit choices; later sign-in or pairing failure can follow an already-saved configuration change, which is reported in `values.applied`. After a timeout, check status before retrying a mutation.

Choose `read-only`, `workspace-write`, or `danger-full-access` deliberately. Full Access runs commands without command approvals and grants routine app/site access for the active task. It does not complete account reconnection, accept unknown forms, or authorize unrelated purchases, bookings, messages, or account changes. Other profiles retain their approval behavior. A filesystem sandbox does not by itself constrain every external application. Model and reasoning effort choices must match the account's current catalog.

When Steve needs a decision, reply “yes” or “no.” It presents one ordinary approval at a time and binds the reply to the prompt already delivered in the paired conversation. Internal approval IDs remain available to the local CLI for diagnostics; they are not required in normal messages.

`setup --login` returns an official browser authentication URL. The human completes that flow. Sign-in pauses Steve. Run doctor afterward to refresh account state, then start to resume after authentication finishes. Grant Steve Full Disk Access in System Settings, then relaunch it. Messages Automation permission is established by an explicitly authorized first reply. Grant the separate Computer Use app its requested Screen Recording and Accessibility permissions. These system prompts cannot be silently approved by onboarding.

`setup --pair` returns a short-lived code and the receiving address. Send that code in a private iMessage to the displayed Mac account. Do not publish the output or paste passwords, one-time authentication codes, cookies, or payment details into the conversation. Pairing codes authorize one exact conversation and sender.

`stop` pauses/cancels the operator; `start` resumes it. They do not quit or relaunch the menu-bar app. Use the app's Quit action to shut down cleanly.

## Optional Tailscale setup

Basic iMessage operation does not require Tailscale. Phone browser access requires a private network connection. The [recommended standalone macOS app](https://tailscale.com/docs/install/mac) includes the CLI. Install Tailscale on the phone too, use your own account, and complete the operating system's VPN approval. The account and VPN setup remain human steps.

```sh
steve setup --tailscale-connect --non-interactive --json
steve doctor --json
```

The explicit connect flag runs a bounded `tailscale up` and reads its status. It does not reset routing, switch accounts, enable Funnel, or overwrite Serve routes. Existing nondefault settings may require finishing setup in Tailscale's app. See the [Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli). A connected tailnet alone is not proof that phone takeover is configured.

## Phone control in Safari

After connecting Tailscale on both devices, enable private HTTPS and generate a one-time link:

```sh
steve setup --phone-access --non-interactive --json
steve phone --json
steve phone --disconnect --json
```

Once phone access is configured, ask Steve in the paired iMessage conversation for a phone-control link. If Steve is paused, first say "resume", then ask for the link. Steve sends a private, one-use Safari link that expires after two minutes. The link is not included in model inputs or Steve's SQLite outbox; it remains in your private Messages history. Requesting a link does not grant control or pause the worker; claiming it does. If delivery is uncertain or the link expires, ask for a new one.

The setup command uses an unused HTTPS port (8443 or 10000), preserves other Serve routes, and refuses a conflicting or publicly exposed Funnel route. Tailscale may require enabling HTTPS in your account before setup succeeds. The backend listens only on loopback. The link contains a short-lived secret: keep it private. You can also show a QR code from Steve’s connected-phone menu.

Steve needs its own Screen Recording and Accessibility grants for this feature. The separate Computer Use app’s grants do not apply to Steve. Open an existing Chrome window before pairing. Safari shares the display containing that window, including other visible apps and password-manager popups. Inputs and live images are not written into the model conversation or recording artifacts.

Taking control pauses and drains the worker. Disconnect, expiry, revocation, and system lock leave it paused. Finishing can resume queued requests; an interrupted action is never automatically replayed. Send a new message to continue an interrupted task. Real iPhone Safari login, keyboard, and lock behavior remain release acceptance checks.

## Video evidence

For an explicitly requested task demonstration, the native recorder creates H.264 MP4 video. Exact-window capture is the default: inventory the named app's visible windows, choose the verified task window, and record only that window. Steve decodes the output locally and checks size and duration before returning a workspace artifact. The relay can select that artifact for native iMessage delivery. Video is evidence of what happened; it does not replace checking the task’s actual result.

```sh
steve video windows --app BUNDLE_ID --json
steve video start --demonstration --window WINDOW_ID --app BUNDLE_ID --seconds 30 --json
steve video stop RECORDING_ID --json
steve video cancel --json
```

Window capture excludes the desktop and other windows, does not include child windows or audio, and cancels if the selected window is resized, hidden, closed, or replaced. Do not guess a window ID or fall back to a wider scope when the requested window is unavailable. Full-display capture requires separate, explicit authorization for everything visible on that display: `steve video start --demonstration --display DISPLAY_ID --seconds 30 --json`. Add `--audio` only when system sound was also explicitly authorized; it is available only with display capture. Microphone recording is not supported. Finish permissions and authentication before recording; cancel before any login, sensitive input, or phone takeover. The visible recording indicator also offers cancellation.

The default delivery budget is 24 MiB, with a maximum recording duration of 120 seconds. These are Steve’s limits, not an Apple-published iMessage attachment limit. Exceeding a limit discards the unfinished clip. Short demonstrations with and without system audio have been received and fully decoded on another Mac; Messages converted the H.264 MP4 to a HEVC MOV and retained the AAC audio. Do not assume the received file has the source codec, extension, or bytes. Actual iPhone playback remains a separate acceptance check. Apple documents inline video attachments in [Messages on Mac](https://support.apple.com/guide/messages/send-images-ichtb967d30b/mac).

## Saved preferences

Ask Steve to remember, list, or forget a preference. Forget removes the active saved preference from Steve; it does not erase earlier iMessages or Codex conversation history. Saved preferences do not authorize purchases, account changes, or other actions.

## Reminders and scheduled tasks

Ask normally: “Remind me in two minutes to check the oven.” For a clock time, Steve uses your requested timezone, a saved timezone preference, or the Mac’s local timezone and shows the date-correct abbreviation (for example, EST/EDT or PST/PDT) in the confirmation. The original unset UTC default falls back to the Mac’s zone; explicit non-UTC settings are preserved. If needed, say “Remember that my timezone is Eastern time.” You can also ask Steve to list or cancel schedules in normal language. The Mac and Steve must be running for execution; after downtime, missed recurring occurrences are coalesced instead of replaying every missed run.

Schedules remain bound to the paired chat, workspace, and permission choices. An uncertain task or delivery outcome blocks later automatic occurrences until reviewed. Live checks verified a one-time reminder across restart and a recurring reminder paused across restart with zero executions. Daylight-saving transitions still need separate installed-device acceptance.

## Optional payments

The source includes an isolated Stripe Link test-mode adapter and deterministic tests. It is not wired into the operator or onboarding, and Steve cannot currently make a purchase through it. Do not provide payment credentials in iMessage. Account setup, a reviewed purchase flow, and live test-mode validation remain future integration work.

## Troubleshooting and data

If the CLI cannot connect, open the installed app in the active user session. A second Steve instance cannot take the local control socket. If Messages is unavailable, grant Full Disk Access to the installed bundle and relaunch; Terminal's permission does not grant the app permission.

Codex credentials belong to Codex. Steve stores settings, exact pairing, queue state, and thread IDs in `~/.steve/steve.sqlite3`. The default workspace is `~/.steve/workspace`; existing configured workspaces are preserved. Logs are under `~/Library/Logs/Steve`. Treat all of these as private. Raw benchmark histories stay local.

To uninstall, quit Steve, remove the installed app and optional command wrapper, and remove its login item if enabled in macOS Settings. Keep the data directory and workspace unless you explicitly want to delete them. Disconnect the phone in Steve before handing the Mac to someone else.
