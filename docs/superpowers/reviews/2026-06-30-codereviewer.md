# Code Reviewer agent review — ceph-incident-bundle (2026-06-30)

Correctness / maintainability / security lens.

## HIGH (secret leaks)
- `lib/common.sh:68` — redaction regex misses real ceph secret format: keyrings/`ceph auth`/`mon dump`/config store `key = AQB...==` or `"key":"AQB..=="`, none containing the keyword list → pass through verbatim. Fix: add key-material patterns (`(^|[^a-z])key[[:space:]]*[:=]`, `caps`, base64 blob `[A-Za-z0-9+/]{32,}={0,2}`), redact value.
- `lib/common.sh:67-74` — line-by-line redaction can't handle multi-line PEM: `BEGIN ... PRIVATE KEY` header redacted but base64 body lines kept → whole key leaks. Fix: stateful — once `BEGIN..KEY` seen, redact until `END`.
- `run/collect.sh:199` + `collect-node.sh:175` — copied `*.gz` logs never redacted (`redact_bundle_text` glob excludes gz). Fix: gunzip→redact→(re)store as `.log`, or exclude `*.gz` from copy.
- `lib/verify-bundle.sh:24-26` — verifier blocks only filename substrings; `*.pem/*.key/*.crt/*.config` with key material passes → secrets ship in a VERIFY PASS bundle. Fix: add `*.pem/*.key/*.crt` filename patterns + content grep for `BEGIN * PRIVATE KEY` / `^\s*key\s*=`.

## MED
- `collect-node.sh:34-44` — `node_run_optional` ends `|| return 0`, swallows every optional-command failure → can't raise documented exit 2. Fix: distinguish "present but failed" (2) from "absent" (0), or document.
- `collect-node.sh:331-335` — node `cephadm ls` uses `|| true`, drops rc from `failed`. Fix: capture rc or document exception.
- `lib/common.sh:77` — `chmod --reference` GNU-only; on macOS/BSD workstation always fails (guarded `|| true`) → redacted file loses original mode. Fix: portable `stat`-based mode or deliberate `chmod 600`.
- `run/collect.sh:300-301` — `alias=$(parse_host_entry | sed -n 1p) || die`: `||` binds to pipeline not parse_host_entry; bad entry → sed succeeds → die never fires → silent empty alias/host. Fix: parse once into array, check rc directly.
- `collect-cluster-cephadm.sh:44-49` — crash-id grep `"(crash_id|id|name)"` can capture unrelated nested `name`/`id`. Fix: anchor to `crash_id` only.
- `collect-node.sh:160` + `collect.sh:172` — remote relies on GNU `tar -xzf -`/`-czf -`; BusyBox/minimal node may lack `-z` → corrupt/empty archive counted as node failure with poor diagnostic. Fix: probe, or `gzip -dc | tar -xf -`; clear errors.log reason.
- `verify-bundle.sh:23-30` — `verify_members` reads `find -print` with newline split; filename with newline could smuggle a forbidden component past `case`. Fix: `find -print0` + `read -r -d ''`.

## LOW
- `collect-node.sh:286-287` — `command_words=($command)` unquoted word-split/glob (SC2206). Fix: specs as arrays.
- `collect-node.sh:93` — non-root `node_file_size` redirection fails for unreadable file → marks copy failed (exit 2), conflating permission vs error. Fix: skip sentinel.
- `collect.sh:320` / `verify-bundle.sh:86` — macOS bsdtar embeds `./._*` AppleDouble members in final tar. Fix: `COPYFILE_DISABLE=1` on final `tar -czf` (already used at :172).
- `common.sh:97` — `mktemp`/`mv` in artifact dir; RO/full fs under `set -e` aborts whole run. Fix: trap to still emit summary/errors (partial bundle per exit-2 contract).
- `collect-cluster-cephadm.sh:26` — hard-coded `sudo cephadm shell`; seed where ssh user is root or cephadm needs no sudo → fails whole cluster collection. Fix: branch on remote root / use `sudo -n` / document.
- `collect.sh:317,321` vs README — verify under `set -e` exits 1 via errexit; an already-collected partial bundle (rc=2) reports 1, and tar at :320 only runs if dir-verify passed. Fix: capture verify rc, still produce tar, override to 1 only on real structural/secret failure.
