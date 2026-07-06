# Framing Dialog

## Preliminary Research Checklist

Do this before asking the user anything:

- Identify the system's components and versions.
- Skim the main data/control paths in source.
- List the observability surfaces (metrics, logs, health outputs).
- Note anything surprising — surprises are question fuel.

## The Three Zones

Map the user's knowledge boundary one question at a time, across these three zones.

**Known** — builds anchors.
- "You run X with Y — is Z the invariant you rely on?"
- "When X happens, do you expect Y to hold every time?"

**Known-unknown** — extracts the user's implicit prediction.
- "You asked about X — what would you *expect* to happen?"
- "If X failed right now, what's your best guess at what you'd see first?"

**Unknown-unknown** — the pre-mortem zone.
- "Your questions never touched `<area seen in preliminary research>` — do you know how it behaves when `<failure mode>`?"
- "Nobody has mentioned `<observability surface>` yet — do you know what it reports when the system is actually broken?"

## The Conversion Rule

**"Any question the user cannot answer, or answers with 'not sure', is converted into a `proposed` hypothesis with `Origin: framing-dialog`."**

## Charter Fields

The dialog must fill these fields before it can close:

- **Goal** — one falsifiable sentence.
- **Scope** — in / out.
- **Version anchors** — project + version/commit; environment identifiers.
- **Tiers available** — which tiers are available in this environment (is there a live cluster? is it destructible?).

## Exit Condition

User confirms the charter; at least the known-unknown and unknown-unknown zones each contributed ≥1 backlog entry. A framing that only confirms known facts has failed.
