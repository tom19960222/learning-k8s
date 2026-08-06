---
layout: doc
title: ceph-mclock-profiles evidence summary 2026-08-06
---

# Evidence Summary — ceph-mclock-profiles

> 由 `lib/verdict.py audit` 自動產生（唯讀）；資料集封閉後執行。

| 項目 | 值 |
|---|---|
| 產生時間（UTC） | 2026-08-06T03:15:08Z |
| results 目錄 | `/Users/ikaros/Documents/code/learning-k8s/.claude/worktrees/bridge-cse_01W3khzyRKGDNfM5yFHeVNGV/experiments/ceph-mclock-profiles/results` |
| manifest | `/Users/ikaros/Documents/code/learning-k8s/.claude/worktrees/bridge-cse_01W3khzyRKGDNfM5yFHeVNGV/experiments/ceph-mclock-profiles/results/manifest.json` |
| manifest sha256 | `5ad1050965a7c13e` |
| cells（manifest） | 63 |
| executions（base） | 147 |
| executions（base + amendments） | 177 |
| executions（DONE） | 156 |

## 缺件（未達預期 replicate 數）

| cell | 已完成 | 應完成 | 已 descope |
|---|---|---|---|
| `chaos-4k-extreme+balanced` | 0 | 1 | 否 |
| `chaos-4k-extreme+high_client_ops` | 0 | 1 | 否 |
| `chaos-4k-extreme+high_recovery_ops` | 0 | 1 | 否 |
| `flapping-4k-extreme+high_client_ops` | 2 | 3 | 否 |
| `flapping-4k-low+balanced` | 2 | 3 | 否 |
| `flapping-4k-low+high_client_ops` | 2 | 3 | 否 |
| `node-isolation-4k-mid+balanced` | 2 | 3 | 否 |
| `node-isolation-4k-mid+high_client_ops` | 2 | 3 | 否 |
| `node-isolation-4k-mid+high_recovery_ops` | 2 | 3 | 否 |
| `none-seq-high+high_recovery_ops` | 2 | 3 | 否 |
| `osd-down-4k-extreme+high_client_ops` | 3 | 4 | 否 |
| `osd-down-4k-low+balanced` | 3 | 4 | 否 |
| `osd-down-4k-low+high_recovery_ops` | 3 | 4 | 否 |
| `rack-isolation-4k-extreme+high_client_ops` | 2 | 3 | 否 |
| `rack-isolation-4k-low+balanced` | 3 | 4 | 否 |
| `rack-isolation-4k-low+high_recovery_ops` | 3 | 4 | 否 |
| `rack-isolation-4k-mid+high_client_ops` | 3 | 4 | 否 |
| `rack-isolation-4k-mid+high_recovery_ops` | 3 | 4 | 否 |
| `seq-contention-seq-extreme+high_client_ops` | 2 | 3 | 否 |
| `seq-contention-seq-extreme+high_recovery_ops` | 2 | 3 | 否 |
| `seq-contention-seq-mid+balanced` | 2 | 3 | 否 |

## duplicate finalization（同一 replicate 多個 DONE attempt）

_（無）_

## right-censored 觀測（`time-to-recovery-complete > cap`，有效資料）

- `flapping-4k-extreme+balanced` / `r1`
- `flapping-4k-extreme+balanced` / `r2`
- `flapping-4k-extreme+balanced` / `r3`
- `flapping-4k-extreme+high_client_ops` / `r2`
- `flapping-4k-extreme+high_client_ops` / `r3`
- `flapping-4k-extreme+high_recovery_ops` / `r1`
- `flapping-4k-extreme+high_recovery_ops` / `r2`
- `flapping-4k-extreme+high_recovery_ops` / `r3`
- `flapping-4k-low+balanced` / `r2`
- `flapping-4k-low+balanced` / `r3`
- `flapping-4k-low+high_client_ops` / `r2`
- `flapping-4k-low+high_client_ops` / `r3`
- `flapping-4k-low+high_recovery_ops` / `r1`
- `flapping-4k-low+high_recovery_ops` / `r2`
- `flapping-4k-low+high_recovery_ops` / `r3`
- `flapping-4k-mid+balanced` / `r1`
- `flapping-4k-mid+balanced` / `r2`
- `flapping-4k-mid+balanced` / `r3`
- `flapping-4k-mid+high_client_ops` / `r1`
- `flapping-4k-mid+high_client_ops` / `r2`
- `flapping-4k-mid+high_client_ops` / `r3`
- `flapping-4k-mid+high_recovery_ops` / `r1`
- `flapping-4k-mid+high_recovery_ops` / `r2`
- `flapping-4k-mid+high_recovery_ops` / `r3`

## tainted（不得作為有效 replicate）

_（無）_

## needs-human（taint 重試預算耗盡，佇列已跳過）

- `none-seq-high+high_recovery_ops/r1`：連續 3 次 taint/abort（最後一次：coverage-proof 標記 tainted）
- `flapping-4k-extreme+high_client_ops/r1`：連續 3 次 taint/abort（最後一次：preflight-final-clean）
- `flapping-4k-low+balanced/r1`：連續 3 次 taint/abort（最後一次：coverage-proof 標記 tainted）
- `flapping-4k-low+high_client_ops/r1`：連續 3 次 taint/abort（最後一次：coverage-proof 標記 tainted）
- `chaos-4k-extreme+balanced/r1`：連續 3 次 taint/abort（最後一次：coverage-proof 標記 tainted）
- `chaos-4k-extreme+high_client_ops/r1`：連續 3 次 taint/abort（最後一次：coverage-proof 標記 tainted）
- `chaos-4k-extreme+high_recovery_ops/r1`：連續 3 次 taint/abort（最後一次：preflight-final-clean）

## descope

_（無）_

## measurement_cap 修訂（journal `cap-update`）

| fault | cap（秒） |
|---|---|
| `node-isolation` | 2700 |
| `osd-down` | 2700 |
| `rack-isolation` | 2700 |
| `seq-contention` | 3150 |
