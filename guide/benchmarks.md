# Steve practical benchmark

This suite evaluates the installed Steve app through its paired Messages conversation. It measures the complete relay, worker, approval, delivery, and persistence workflow. Running these prompts directly in another agent does not count as a Steve result.

The first comparison requests **GPT-5.6 Luna, xhigh, Fast** and **GPT-6 Astra, xhigh, Standard**. Both relay and worker must use the selected configuration. Record the installed app hash, Codex version, requested and observed configuration, timestamps, and any settings restored after the run. Do not infer Fast execution from a model name or a quick reply.

## Protocol

- Run serially on the same Mac, signed-in browser profile, workspace permissions, and connected accounts. Use a separate empty workspace and fresh conversations for each configuration. Keep each episode's worker context fresh; the research episode itself must remain one continuous task.
- Give both configurations the same prompts from [the task pack](../benchmarks/practical-v1.json), replacing only `RUN` with that run's output directory. Use the stated dates rather than silently moving them. A future repetition must version any date or prompt change.
- Start the clock when the paired iMessage is sent; stop on final delivery or the episode limit. Record approval wait separately. Ordinary permission approvals are allowed and logged. Hints, repairs, login setup, retries, and manually completed steps are interventions, not autonomous successes.
- Read-only account access and local deliverables are authorized by the operator before running. Reservation and shopping tasks stop before submission. No real purchase, booking, email send, calendar invitation, or credential extraction belongs in this suite.
- Do not run live messaging from unit tests or development fixtures. An operator explicitly sends each production task after checking pairing and setup. Never replay a task automatically when its side effects are uncertain.
- Capture private evidence locally: original request, relay and worker identifiers, tool trace, approvals, delivery timestamps, artifact hashes, and independent checks. Keep email, calendar, cookies, tokens, personal paths, and raw desktop media out of Git and public reports.
- If the harness changes mid-comparison, preserve the original failed result and rerun affected tasks for both configurations on the same new build. Label diagnostic attempts separately.

## Grading

Each task has observable requirements in the JSON pack. **Pass** requires every requirement; **Partial** means a useful verified subset; **Fail** means no useful required end state, a false completion claim, or failure to respect the task boundary. Record **blocked** as a cause (login, permission, capability, service, or usage), not as a successful task. Report attempted and unattempted counts explicitly.

The judge inspects delivered files and source evidence. Agent self-reports alone do not establish success. For browsing, require a fresh page state and source URL. For integrations, require a successful actual read, not a tool appearing in a catalog. For persistence, inspect durable storage and restart behavior. For video, decode the received attachment and inspect its content. Record task duration, tool-call count, approvals, interventions, and available token telemetry; leave unavailable cost or backend-tier data blank.

Use a per-task table rather than collapsing correctness, safety, and speed into a made-up weighted index. One run per model is a pilot, not a statistically reliable model ranking. Live availability and account state can change between runs; record order and timestamps.

## Research basis and comparison limits

[RuntimeWire's September 2026 assistant showdown](https://runtimewire.com/article/ai-assistant-showdown-grok-bot-instinct-claude-chatgpt-work-muse) is a close product comparison: it evaluates everyday assistant workflows, inspectable outcomes, and approval boundaries. Its reported results are third-party observations under a different protocol. This task pack is an original Steve acceptance suite, not a reproduction of its scorecard.

[AssistantBench](https://github.com/oriyor/assistantbench) motivates the sustained research task. [OSWorld](https://os-world.github.io/) motivates checking actual application state and outputs independently. This suite does not run either benchmark's official environment or grading system and must not be presented as an official leaderboard score.

Publish only sanitized task outcomes and methodology. Provide useful private deliverables directly to the operator. A missing account connection is a setup finding; a completed synthetic task is not evidence of real email or calendar access.

## September 19 pilot results

The [outcome report](practical-benchmark-20260919.md) contains all 16 original attempts, timing, build differences, and focused repair checks. Raw account and recording evidence stays private. A future task-pack version should fence B07's exact expected text: its current sentence punctuation is ambiguous. The frozen v1 prompts and original grades remain unchanged.

## Everyday-language acceptance

The separate [natural request pack](../benchmarks/natural-v1.json) evaluates short messages a person would actually send. Send only `message` and subsequent `followUps`; limits and judge requirements stay outside model input. Steve chooses tools, file paths, verification, and context handling. Do not prepend technical setup instructions or a time budget. Use the explicitly selected permission profile, record any human intervention, and preserve the original pilot scores. These runs test the changed experience and are not a controlled rerun of practical-v1.
