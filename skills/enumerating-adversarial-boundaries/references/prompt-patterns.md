# Prompt Patterns Reference

Full prompt text for the three patterns referenced from `SKILL.md`. Copy the prompt text
directly; fill in the bracketed placeholders for the system under study.

## Pre-mortem

> Assume `<artifact>` failed silently during a real incident. Write five distinct causes,
> at least one involving the observation path itself, at least one involving
> human/process factors.

**When it beats the matrix:** the matrix enumerates single-cell failures well but under-covers
compound failures — chains where a benign-looking event in one component cascades through
two or three others before anything pages. Pre-mortem's "already failed, work backward"
framing surfaces those chains because it forces a causal story instead of an isolated cell.

## Negative-space

> Enumerate the complete set of `<all possible states/codes/inputs>` for `<system>`. For
> each, name the existing `<rule/handler/doc>` that covers it, or mark UNCOVERED. Output
> only the UNCOVERED list.

**When it beats the matrix:** the matrix only covers cells someone thought to add as a row
or column. Negative-space instead starts from the full state/code/input space the system
can actually produce, so it finds missing coverage the matrix's axes never had a slot for
in the first place — the classic case being a catch-all rule that silently absorbs codes
nobody enumerated.

## Multi-persona

Dispatch the same design to independent reviewers with distinct lenses, for example:

- an operator woken at 3am, reasoning only from what the alert says;
- a correctness reviewer working strictly against the pinned source;
- an adversary actively trying to make the artifact mislead an observer.

Run personas in parallel, with each one **not** seeing any other persona's output.
Deduplicate the combined results afterward.

**When it beats the matrix:** the matrix assumes a single, correct framing of the system —
one set of components, one set of signals. Personas find framing blind spots: things that
are invisible under the reviewer's default framing but obvious once someone adopts a
different one (the operator who only trusts the page, the adversary who assumes the
telemetry itself is the attack surface).
