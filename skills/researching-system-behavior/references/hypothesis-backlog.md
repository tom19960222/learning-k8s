# Hypothesis Backlog Template

The complete `HYPOTHESES.md` template:

```markdown
# <topic> — Hypothesis Backlog

## Charter
- Goal: <one falsifiable research goal>
- Scope: <in / out>
- Version anchors: <project + version/commit; environment identifiers>
- Tiers available: <T1 source path; T2 doc sources; T3 environment + destructibility>

## Hypotheses

### H-001: <single falsifiable sentence: under X, Y happens within Z>
- Status: proposed
- Tier: T3
- Origin: <framing-dialog | matrix "<cell>" | pre-mortem | negative-space | persona | feedback>
- Prediction: <required before status: predicted — exact signal, expected value, window>
- Evidence: <required before confirmed/violated — file:line, bundle dir, command output path>
- Artifacts: <required before synthesized — files changed because of this finding>
- Notes:
```

## Rules

- Numbering is `H-NNN`, append-only (never renumber).
- Killed hypotheses get `Status: proposed` struck through with a one-line reason rather than deletion (rejected ideas must stay visible or they will be re-proposed every round).
- One file per research effort, living in that effort's working directory.
