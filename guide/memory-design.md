# Memory and personalization

Agent name and personality are explicit local settings, separate from user facts and access permissions. Both relay and operator receive the current identity. Personalization can change tone; it cannot authorize actions.

Steve's durable store owns stated preferences and dated plan summaries. Operators receive the current active preferences with statement dates and source types. The private, atomically generated `STEVE_MEMORY.md` is read-only to operators and excluded from Git. Corrections replace current values; forgetting removes active values without claiming to erase conversation history. Tentative plans remain distinct from verified commitments.

[Dhravya Shah's Instinct memory analysis](https://x.com/DhravyaShah/status/2101745550752428340) suggests useful patterns: a compact profile, dated facts, on-demand context and read-only memory for the answering agent. It is a third-party reconstruction; its author did not inspect Instinct's code. Steve adopts those principles through its existing local store, without copying speculative internals or adding a hosted memory dependency. Dates and sources travel with preferences so a compact summary does not silently become timeless authority.
