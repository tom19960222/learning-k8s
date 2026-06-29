# Lab multi-fault validation — ceph-incident-bundle (2026-06-30)

Run from the macOS workstation (no `timeout`/`gtimeout` → R6 warning fires every run, as designed; SSH ConnectTimeout/ServerAlive still bound everything) against the real lab: cephadm v19.2.3, 3 mon + 9 OSD (3/host), pool `.mgr` size 3 / min_size 2. Destructive scenarios: `ceph osd ok-to-stop` / quorum confirmed first, downtime kept under the 600s `mon_osd_down_out_interval` (no rebalance), HEALTH_OK reconfirmed after each rollback.

| # | scenario | injection | bundle result | exit | rollback |
|---|----------|-----------|---------------|------|----------|
| 12 | healthy baseline | none | VERIFY PASS, 6/6 nodes, 0 errors, **312 lines redacted**, secret-content verifier passed on live config | 0 | — |
| 13 | OSD down | `ceph osd ok-to-stop 0` (ok) → `orch daemon stop osd.0` → `HEALTH_WARN 1 osds down` | captured `OSD_DOWN: osd.0 ... is down` (text + JSON health-detail) | 0 | `orch daemon restart osd.0` → HEALTH_OK |
| 14 | MON loss (quorum kept) | `orch daemon stop mon.ceph-lab-mon-02` → `1/3 mons down, quorum mon-01,mon-03` | captured `MON_DOWN: mon.ceph-lab-mon-02 ... (out of quorum)` (text + JSON) | 0 | `orch daemon restart mon.ceph-lab-mon-02` → HEALTH_OK |
| 15a | node unreachable | inventory + `badnode=192.168.18.250` (no host) | `nodes/badnode/SKIPPED.txt`, other nodes collected, errors.log records `exited 255`; node_ok=2 node_failed=1 | 2 | — |
| 15b | seed unreachable | `--seed ikaros@192.168.18.250` | cluster_status=2 (every cephadm SSH bounded by ConnectTimeout=6, recorded in errors.log), all 6 nodes still collected, bundle produced | 2 | — |

## Interpretation

- **Incident scenarios (13, 14) exit 0**: the down OSD/mon is captured *as evidence inside the bundle* — that is success, not a collection failure. Exit 2 is reserved for the collector failing to gather (15a/15b).
- **Partial failures (15a/15b) exit 2 with a bundle still produced**: matches the README contract (preserve the scene; record what failed in errors.log/summary).
- **Redaction held on real data**: 312 redactions on the healthy run and the new `verify_no_secret_content` pass means no `key = <base64>` / PEM / forbidden-path material survived into a packaged bundle.

## Observations (non-blocking)

- **Workstation has no `timeout`/`gtimeout`** (and bash 3.2): the R6 warning fires every run; outer wrappers are inactive, so only SSH ConnectTimeout/ServerAlive bound remote calls. Installing coreutils (`brew install coreutils` → `gtimeout`) would restore full per-node bounding. On a Linux ops host `timeout` is present and the `--node-timeout` wrapper engages.
- **Dead-seed run is slow without a timeout binary**: each of ~24 cluster `cephadm shell` calls waits out `ConnectTimeout` against the dead seed (R1 keeps it *bounded* instead of hanging forever; previously there was no ConnectTimeout at all on the cluster SSH).
- **macOS bsdtar** emits harmless `LIBARCHIVE.xattr.com.apple.provenance` notes when streaming the helper libs to nodes; cosmetic only.
- **Hard SIGKILL of the process group** (e.g. an external `kill -9`) cannot be trapped, so a workdir can survive that specific case; the EXIT/INT/TERM trap covers the script's own interrupts/failures (proven by the C2 regression test).
