# Scenario Pre-Flight Checklist

Run through every line before executing a scenario. One line each, grouped.

## Prediction

- [ ] Signal named exactly as the monitoring system exposes it (alert name, metric name, or log line — no paraphrasing).
- [ ] Window justified: rule `for:` duration + scrape interval + margin, not a guessed number.
- [ ] Verdict comparison is scripted, not eyeballed.

## Safety

- [ ] Pre-check exists and aborts the scenario on failure.
- [ ] Injection is reversible.
- [ ] Rollback is verified by observed state, not by command exit code.
- [ ] Baseline capture happens before injection.
- [ ] Scenario is re-runnable without manual cleanup.

## Evidence

- [ ] Bundle directory created before injection.
- [ ] Every observation command's raw output is saved.
- [ ] Bundle survives scenario failure — collect happens before any cleanup path, including error paths.
- [ ] Committed summary index (`EVIDENCE-SUMMARY-<date>.md`) is updated.

## Isolation

- [ ] One fault per scenario.
- [ ] Shared cleanup (e.g. warning-history reset) is factored into a shared helper, not duplicated per scenario.
