# Synthesis Rules

## The Three Routes

Each finding must take all three routes:

- **Report** — the finding written for a future reader (evidence summary, feature page) with its evidence anchors.
- **Artifact** — a concrete change: rule, script, runbook, config. **"A finding that changes no artifact is trivia."** If a finding is genuinely informational, the artifact route may be satisfied by a documented decision *not* to change anything, recorded with a reason — but that must be explicit, never silent.
- **Feedback** — if the finding revealed a new failure class, append it to `../../enumerating-adversarial-boundaries/references/axes.md` with provenance and a generalized "Check:" question.

## Gate 3 Procedure

Present findings grouped by verdict (`violated` first — they carry the most information), each with proposed route contents; human selects depth/publication; only then execute routes; set entries to `synthesized`.

## Loop Closure

`violated` entries spawn follow-up hypotheses (`Origin: feedback`); the loop ends when Gate 3 yields no new backlog entries, or the human closes the charter.
