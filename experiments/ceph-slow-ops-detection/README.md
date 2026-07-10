# ceph-slow-ops-detection — BlueStore 暫態卡頓與 slow ops 的快速偵測（Prometheus-only）

研究問題（詳見 `HYPOTHESES.md` charter）：

1. SSD firmware 造成的暫態卡頓（5~8 顆 OSD 同秒卡 5~8 秒）如何主動偵測？
   —— 這類事件永遠到不了 `osd_op_complaint_time`（30s）門檻，SLOW_OPS 全盲。
2. 真的卡住 client 的 slow ops，偵測延遲能否壓進 30~60 秒？

## 目錄

- `HYPOTHESES.md` — charter、gate 決策、22 條 hypothesis backlog（含 status/prediction/evidence）
- `rules/ceph-slow-ops-fast.yml` — R1/R2/R3 三條新規則（與既有 `ceph-alert-rules` 並存）
- `lib/` — 共用 helper（ssh、Prometheus API、bundle、verdict 機器比對）
- `run/` — E-00~E-06 + finale，一 scenario 一 fault，全部 inject→observe→collect→rollback→assert
- `tests/` — `bash tests/run-tests.sh` 總 gate（unit + promtool + 由 run-tests 呼叫）
- `results/` — 每次 run 的 evidence bundle（gitignored）；索引見 `EVIDENCE-SUMMARY-*.md`

## 跑實驗的前提

- lab cluster（3 mon + 9 OSD，cephadm v19.2.3）+ monitoring stack：
  `ceph orch apply ceph-exporter && ceph orch apply node-exporter && ceph orch apply prometheus --placement=<host>`
- 本機可直連 lab 的 Prometheus（`192.168.18.166:9095`）與各 host ssh。
- scenario 之間 `BLUESTORE_SLOW_OP_ALERT` 會 latch（by design，見 H-008），
  pre-check 已豁免；`run/seq-finale.sh` 負責清 latch、刪 bench pool、驗最終 HEALTH_OK。

## 執行順序

```bash
bash run/e00-negative-control.sh   # 負向對照（無注入）
bash run/e01-single-osd-transient.sh
bash run/e02-multi-osd-same-node.sh
bash run/e03-idle-blindspot.sh
bash run/e04-sustained-throttle.sh
bash run/e05-exporter-freeze.sh
bash run/e06-threshold-tuning.sh
bash run/seq-finale.sh             # 善後 + H-008/H-020 收尾驗證
```

每個 script 的 stdout 只有一行 `VERDICT <scenario> confirmed|violated`；
`violated` 是「prediction 被推翻」＝有發現，不是執行失敗。
