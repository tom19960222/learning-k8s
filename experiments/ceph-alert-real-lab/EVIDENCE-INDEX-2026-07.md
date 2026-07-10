# Ceph Alert Real-Lab Evidence Index — 2026-07（S1–S22 全 22 場總帳）

這份文件是 2026-07-04 ~ 2026-07-06 在真 ceph lab 跑完的 22 個 alert 故障注入場景的
machine-readable evidence ledger。raw `results/` 目錄被 `.gitignore` 排除、**只存在本機**
（`/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/results/`），
git 裡先前只有最初 3 場的索引（`EVIDENCE-SUMMARY-2026-07-04.md`）。本文件把 22 場的
run 目錄、注入命令、ceph 端證據、Prometheus / Alertmanager / receiver 證據、negative
assertion、rollback 與 `HEALTH_OK` 確認逐場從 raw 檔重建，讓「22/22 通過」可從 git 稽核。

**重建方法**：每一欄都直接讀自 raw 檔（`run_capture` 的 `# command:` 標頭、
`prometheus-alerts-*.json` 的 `state`/`activeAt`、sink log 的 JSON rows、
`recovery/ceph-ready.txt` 的 health 行），一次性彙整腳本放 scratchpad、不進 repo；
**沒有任何欄位從 README 或網站 MDX 反推**。raw 缺的欄位一律標 `missing in raw`。

## 範圍宣告

### Lab 拓樸（讀自各 run 的 `baseline/ceph-s.txt`、`rook-cephcluster.txt`）

- cephadm cluster fsid `0c9bf37e-514a-11f1-b72a-bc24113f1375`，image
  `quay.io/ceph/ceph@sha256:af0c5903...`（tag `v19`，image id `aade1b12b8e6`）；
  `crash-post.txt` 內的 crash meta 記載 `"ceph_version": "19.2.3"`。
- `mon: 3 daemons, quorum ceph-lab-mon-01,ceph-lab-mon-02,ceph-lab-mon-03`
  （`.166` / `.167` / `.164`）；`mgr:` active + 1 standby；`osd: 9 osds: 9 up, 9 in`
  （`.169` / `.171` / `.174` 各 3 顆）。
- Rook external：`rook-cephcluster.txt` 顯示 CephCluster `Connected` / `HEALTH_OK`。
- 監控 stack（lab k8s namespace `ceph-alert-lab`）：Prometheus `v3.2.1` +
  Alertmanager `v0.28.1` + `alert-sink` webhook（receiver = `pager` / `slack` /
  `watchdog` 三路），manifest 由 `lib/monitoring.sh` render 到 `rendered/monitoring.yaml`。

### Rule 集版本（`experiments/ceph-alert-rules/rules/` 的 HEAD 時間軸）

22 場**不是在單一 rules snapshot 下跑完的**——rules 在戰役中被修了兩次，時間軸如下
（commit 時間換算成 UTC，與 run 目錄時戳同一時區）：

| rules commit | UTC 時間 | 內容 | 適用的 run |
|---|---|---|---|
| `5a01a77`（含 `cb7b036` production coverage v2） | 2026-07-04 15:35Z | monitoring v2 + inhibit rules | 2026-07-05 17:38Z 部署起的第一批（S9、S21、S13、S8、S7、S4、S6、S5、S14、S15 與 S1 前三次失敗） |
| `efcf5bb` | 2026-07-05 22:15Z | CephDaemonSlowOps 改 windowed max（spiky gauge 修正） | S1 最終 PASS（22:19Z）起至 07-06 09:52Z 前（S11、S12、S2、S17、S16、S18 與 S19 第一次失敗） |
| `23314bc` | 2026-07-06 09:52Z | data-integrity health alerts 窗化（transient mgr export 修正） | 07-06 09:53Z 後（S19 兩次 PASS、S20、S10、S3）；S19 第二次失敗（09:53:23Z 起跑）與 redeploy 幾乎同時，跑在哪一版下無法從 raw 斷定 |

**raw 佐證**：`rendered/monitoring.yaml`（本機，mtime 2026-07-06 09:53Z）內嵌的四份
rules 檔與 `23314bc` 的 `ceph-stability-first.yml` / `ceph-scoped-availability.yml` /
`ceph-production-coverage.yml` / `_default-mixin.yml` **逐字元一致**（已逐一 diff 驗證）——
這是最後一段（09:53Z redeploy 之後）rules 版本的硬證據。更早兩段的對應是由 commit
時間軸推定（raw 沒有留每次 redeploy 的 manifest 快照），無法排除當時 working tree
與 commit 有未提交差異——此為誠實限制。

### raw 只存本機 + 真 run 判別

- `results/` 下共 3,636 個目錄，其中**絕大多數是單元測試（fake `ssh`/`kubectl`）殘留**。
- 真機 run 的判別條件：`baseline/ceph-s.txt`（或 baseline run 的頂層 `ceph-s.txt`）
  含真 cluster fsid `0c9bf37e-...`。fake 測試的同名檔只有一行canned `HEALTH_OK`，
  不含 fsid。以此掃描得 **51 個真機 run**（21 個 scenario 名稱 × 各 1–10 次 + 2 個
  baseline run），涵蓋全部 22 場。
- 每場的「run of record」= 通過該場全部斷言（見下）的最後一次 run；其餘真 run 列在
  各場的「重試史」。PASS 判準（逐場依 `scenario_verify` 原始碼定義）：
  1. 每個 `wait_prometheus_alert` 目標在 `prometheus-alerts-<alert>-<label>.json`
     有 `state="firing"` 的 row（含 label 匹配）；
  2. 每個 `wait_sink_alert` 目標在 `sink-since-checkpoint.log` 有對應
     receiver+alertname 的 JSON row；
  3. 每個 `assert_prometheus_alert_not_firing` / `assert_sink_absent` 的目標在對應
     raw 檔中**不存在** firing / row；
  4. 每個 `wait_ceph_health_check` 目標有 `health-check-<CHECK>.txt` 且含該 check 行；
  5. `recovery/ceph-ready.txt` 回到 `HEALTH_OK`、`recovery/rook-cephcluster-ready.txt`
     `Connected`+`HEALTH_OK`、`recovery/prometheus-up-ceph.json` `up{job="ceph"}==1`。

### 場景編號

S1–S22 對應 scenario 名稱，依
`docs/superpowers/plans/2026-07-04-ceph-alert-production-coverage.md`（Tasks 5–22）與
`README.md` 情境一覽的既有編號（S1=slow-ops、S2=pg-availability、S3=mon-quorum-lost、
S4=osd-daemon-down、S5=osd-host-down、S6=mon-down-single、S7=exporter-blind、
S8=mgr-failover、S9=catch-all-risk、S10=low-priority-notice、S11=latency-outlier、
S12=net-slow-heartbeat、S13=mon-clock-skew、S14=daemon-crash、S15=osd-flapping、
S16=capacity-ladder、S17=pool-quota、S18=capacity-forecast、S19=data-damage、
S20=object-unfound、S21=mon-disk-low、S22=watchdog baseline 斷言）。

### framework 標準檔（每個 scenario run 皆有，逐場清單不再重複）

- `baseline/`：注入前快照——`ceph-s.txt`、`ceph-health-detail.txt`、`ceph-osd-tree.txt`、
  `ceph-quorum-status.json`、`mgr-metrics-192.168.18.{166,167}-9283.txt`（兩個 mgr
  exporter 的 `/metrics` dump；standby 那台為 134B 的空回應）、`rook-cephcluster.txt`、
  `rook-pods.txt`。
- `ready-before-injection/`：注入前 gate——`ceph-ready.txt`（`ceph -s` 須 `HEALTH_OK`）、
  `rook-cephcluster-ready.txt`、`prometheus-up-ceph.json`。
- `sink-checkpoint.log` / `sink-checkpoint-lines.txt` / `sink-checkpoint.log.err`：
  注入前 sink log 行數 checkpoint（之後的斷言只看 checkpoint 後的新 rows）。
- `sink.log` / `sink-since-checkpoint.log`：alert-sink（webhook receiver）收到的
  alert rows（JSON lines，含 receiver / alertname / labels / severity）。
- `postcheck/`：rollback 後快照（同 `baseline/` 檔組）。
- `recovery/`：復原 gate 輪詢——`ceph-ready.txt`、`rook-cephcluster-ready.txt`、
  `prometheus-up-ceph.json`（輪詢中重複覆寫，最後一次寫入即通過當下）。
- 有 negative sink 斷言的場另有 `sink-absent-check.log` / `sink-absent-since-checkpoint.log`。

## 缺口與保留（對帳結果，先講醜話）

22 場都找得到完整 run，但以下事項必須誠實標注：

- **G-1（S11 latency-outlier）**：唯一一個「run 目錄內沒有 in-run `HEALTH_OK` 復原證據」
  的場。正向斷言全過（`CephOSDLatencyOutlier` firing + slack 送達 + pager absent），但
  rollback 後 `recovery/ceph-ready.txt` 最後一次輪詢（23:01:22Z）仍是
  `HEALTH_WARN: 9 OSD(s) experiencing slow operations in BlueStore`（BLUESTORE_SLOW_OP_ALERT
  的 24h latch），`recovery/` 也因此缺 `rook-cephcluster-ready.txt` 與
  `prometheus-up-ceph.json`（gate 短路，後兩項未執行）。cluster 回到 `HEALTH_OK` 的證據是
  **跨 run** 的：下一場 S12（`net-slow-heartbeat-20260705T231409Z.FyTXF8`）的
  `ready-before-injection/ceph-ready.txt`（23:14:15Z）顯示 `HEALTH_OK`。latch 清除
  helper（`clear_bluestore_slow_ops`）在 `f22efc4`（23:13Z）才共用到 latency-outlier，
  晚於本場執行。
- **G-2（S3 mon-quorum-lost 的 inhibit 證據是 synthetic）**：quorum 真的 lost 時 mgr
  exporter 凍結，`CephMonDownScoped` 的 expr 無資料可評估，真 fault 永遠做不出
  「兩個 alert 時間重疊」讓 inhibit 可觀測（11:35Z 那次 run 就是這樣 fail 的）。
  最終 PASS run 改用 synthetic POST 直打 Alertmanager `/api/v2/alerts` 驗證
  inhibit 設定：`alertmanager-alerts-CephMonDownScoped.json` 顯示 synthetic alert
  （labels `ceph_daemon="mon.synthetic"`）`state: suppressed`、
  `inhibitedBy: ["c425f3928619a998"]`。這驗的是 Alertmanager 抑制設定本身，不是真
  fault 的抑制行為。
- **G-3（S14 daemon-crash 的 crash 上報是手動代送）**：SIGSEGV 是真的打在真 ceph-osd
  process 上（crash spool 出現新 crash dir 為證），但這座 lab 的 `ceph-crash` sidecar
  壞掉（無 `client.crash` auth），crash meta 由 harness 從 spool 讀出、經 admin shell
  `ceph crash post -i -` 代送（`crash-post.txt`）。被替代的只有傳輸層，fault 本身是真的。
- **G-4（rules 版本橫跨三個 commit）**：見範圍宣告。特別是 S1 的最終 PASS 用的是
  `efcf5bb` 重設計後的 `CephDaemonSlowOps`（前三次失敗即因舊版 spiky gauge 抓不到）；
  S19 的兩次 PASS 用的是 `23314bc` 窗化後的 `CephDataDamage`（前兩次失敗）。
  「22/22」的正確解讀是「每場都在**其最終 rules 版本**下通過」，不是單一 snapshot 一次跑綠。
- **G-5（部分場景沒有 ceph 端 health-check 證據檔）**：S3、S5、S7、S8、S11、S15、S18
  的 `scenario_verify` 原始碼不含 `wait_ceph_health_check`，故 raw 無
  `health-check-*.txt`（表中標 `missing in raw`，並在小節說明該場 ceph 端證據實際是
  什麼）。
- **G-6（sink log 有跨場殘留）**：Alertmanager 的 resolve / repeat 通知會落在下一場的
  checkpoint 之後，例如 S10 的 `sink-since-checkpoint.log` 裡有前一場 S20 的
  `CephObjectUnfound` / `CephDataDamage` pager rows；S16/S18 的重負載 bench 也讓
  `CephClientBlocked{SLOW_OPS}`、`CephClientRisk{BLUESTORE_SLOW_OP_ALERT}` 以副作用
  身分進了 pager。各場斷言只檢查自己的目標 alert，副作用 rows 如實留在 raw。
- **G-7（S22 的舊 baseline 無 watchdog 斷言）**：07-04 的 `baseline-20260704T095200Z.7rOZq6`
  是 v1 harness（無 sink 斷言檔）；S22 的 PASS 證據是 07-05 的
  `baseline-20260705T181625Z.ORyUqe`。
- 多場在最終 PASS 前有失敗重試（S1×3、S3×1、S8×1、S14×1、S15×2、S16×1、S17×1、
  S18×9、S19×2，另有 07-04 v1 phase 的 6 個 run）——全部列在各場「重試史」，
  無一場「找不到完整 run」。

## 22 場總表

「receiver 證據」欄的檔名都指 `sink-since-checkpoint.log`（縮寫 `sink-since`）內的
JSON row；activeAt 取自該場 `prometheus-alerts-*.json` 中目標 alert 的 firing row。

| S# | scenario / run 目錄 | 注入方式（讀自 run_capture `# command:`） | ceph 端證據（檔＋關鍵行） | Prometheus / receiver 證據（檔＋activeAt） | negative assertions | rollback ＋ HEALTH_OK | verdict |
|---|---|---|---|---|---|---|---|
| S1 | `slow-ops-20260705T221900Z.Le0WeV` | cgroup v2 `io.max` 把 osd.4（`.171`，`/dev/sdc`，majmin 8:32）限到 rbps/wbps=262144（`throttle.txt`）＋ `rados bench -p alert-slow-ops 420 write -t 64`（`rados-bench.txt`） | `health-check-SLOW_OPS.txt`：`[WRN] SLOW_OPS: 1 slow ops, oldest one blocked for 30 sec, osd.4 has slow ops`（同檔另有 BLUESTORE_SLOW_OP_ALERT） | `prometheus-alerts-CephClientBlocked-name.json`：`CephClientBlocked{name="SLOW_OPS"}` firing，activeAt `2026-07-05T22:20:07Z`；`prometheus-alerts-CephDaemonSlowOps-ceph_daemon.json`：`CephDaemonSlowOps{ceph_daemon="osd.4"}` firing，activeAt `2026-07-05T22:20:07Z`；sink-since：pager `CephClientBlocked/SLOW_OPS`、slack `CephDaemonSlowOps{osd.4}` | （本場無 negative 斷言） | `rollback-unthrottle.txt`（io.max 還原 max）、`rollback-kill-rados-bench.txt`、`rollback-pool-cleanup-1.txt`（刪 pool）、bluestore latch 清除 6 檔；`recovery/ceph-ready.txt` `HEALTH_OK`（22:21:41Z） | PASS |
| S2 | `pg-availability-20260705T233337Z.fghfbC` | 停 sentinel object acting set 兩顆 OSD：`stop-osd-1.txt`（osd.7@`.174`）、`stop-osd-2.txt`（osd.5@`.171`） | `health-check-PG_AVAILABILITY.txt`：`[WRN] PG_AVAILABILITY: Reduced data availability: 3 pgs inactive, 3 pgs peering` | `prometheus-alerts-CephClientBlocked-name.json`：`CephClientBlocked{name="PG_AVAILABILITY"}` firing，activeAt `2026-07-05T23:35:07Z`；`prometheus-alerts-CephPGUnhealthyStates-name.json`：`CephPGUnhealthyStates{name="alert-pg-availability"}` firing，activeAt `2026-07-05T23:33:52Z`；sink-since：pager 兩者皆有 | （無） | `rollback-restart-1/2.txt`（重啟兩顆 OSD）、`rollback-pool-delete.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（23:37:39Z） | PASS |
| S3 | `mon-quorum-lost-20260706T121047Z.jCUko6` | 停 mon-01（`.166`）與 mon-03（`.164`）（`stop-mon-1/2.txt`），再停 active mgr（`stop-active-mgr.txt`，mgr.ceph-lab-mon-01.jvgpfh）走 empty-series 路徑 | health-check：missing in raw（腳本無此斷言，G-5）；ceph 端證據＝`stopped-mons.txt`/`stopped-mgr.txt`（實際停掉的 daemon 清單）＋`prometheus-ceph-mon-quorum-lost-expr.json`（rule expr 評值 `"0"`＝quorum-lost 條件成立） | `prometheus-alerts-CephMonQuorumLost-none.json`：`CephMonQuorumLost` firing，activeAt `2026-07-06T12:12:07Z`；sink-since：pager `CephMonQuorumLost` | inhibit：`alertmanager-alerts-CephMonDownScoped.json` synthetic `CephMonDownScoped` `suppressed`、`inhibitedBy:["c425f3928619a998"]`（G-2） | `rollback-restart-1/2.txt`（兩顆 mon）、`rollback-restart-mgr.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（12:14:22Z） | PASS |
| S4 | `osd-daemon-down-20260705T190910Z.iszPzn` | `stop-osd.txt`：`systemctl stop ...@osd.0.service`（`.169`） | `health-check-OSD_DOWN.txt`：`[WRN] OSD_DOWN: 1 osds down` | `prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json`：`CephOSDDaemonDownScoped{ceph_daemon="osd.0"}` firing，activeAt `2026-07-05T19:09:39Z`；sink-since：pager `CephOSDDaemonDownScoped`、slack `CephOSDDown/OSD_DOWN` | `prometheus-alerts-CephOSDHostDownScoped-hostname.json` 內無 `CephOSDHostDownScoped` firing row（單顆 down 不觸發 host-down）✔ | `rollback-start-osd.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（19:15:19Z） | PASS |
| S5 | `osd-host-down-20260705T191745Z.X9kV6n` | 停 `.171` 整台 3 顆 OSD：`stop-osd-1/2/3.txt`（osd.3/4/5，`target-osds.txt`） | health-check：missing in raw（G-5）；ceph 端證據＝`postcheck/ceph-health-detail.txt`（rollback 後尚存的 OSD_DOWN 記錄）與 prom 端 `CephOSDDown`/`CephOSDHostDown` firing rows | `prometheus-alerts-CephOSDHostDownScoped-hostname.json`：`CephOSDHostDownScoped{hostname="ceph-lab-osd-02"}` firing，activeAt `2026-07-05T19:18:09Z`；sink-since：pager `CephOSDHostDownScoped`（另 slack `CephOSDDown`、`CephOSDHostDown`） | `prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json` 內 osd.3/4/5 均無 `CephOSDDaemonDownScoped` firing row（host-down 時不逐顆叫）✔ | `rollback-start-1/2/3.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（19:24:26Z） | PASS |
| S6 | `mon-down-single-20260705T191541Z.5aTpqF` | `stop-mon.txt`：停 mon-03（`.164`，非 active-mgr 所在） | `health-check-MON_DOWN.txt`：`[WRN] MON_DOWN: 1/3 mons down, quorum ceph-lab-mon-01,ceph-lab-mon-02` | `prometheus-alerts-CephMonDownScoped-ceph_daemon.json`：`CephMonDownScoped{ceph_daemon="mon.ceph-lab-mon-03"}` firing，activeAt `2026-07-05T19:16:24Z`；sink-since：pager `CephMonDownScoped` | `prometheus-alerts-CephMonQuorumLost-none.json` 內無 `CephMonQuorumLost` row（單 mon down 不觸發 quorum-lost）✔ | `rollback-start-mon.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（19:17:20Z） | PASS |
| S7 | `exporter-blind-20260705T190305Z.l6KleG` | `disable-prometheus-module.txt`：`ceph mgr module disable prometheus` | health-check：missing in raw（G-5；本場故障點是 metrics 管線，ceph health 本來就不變）；ceph 端證據＝`postcheck/mgr-metrics-*.txt` 縮成 229B 錯誤回應 | `prometheus-alerts-CephMetricsAbsent-none.json`：`CephMetricsAbsent` firing，activeAt `2026-07-05T19:03:22Z`；`prometheus-alerts-CephExporterAllDown-none.json`：`CephExporterAllDown` firing，activeAt `2026-07-05T19:03:22Z`；sink-since：pager 兩者皆有（副作用：`CephMonQuorumLost` 也 firing 進 pager——exporter 全滅時 `or vector(0)` 的既知行為，v1 發現的再現） | （無） | `rollback-enable-prometheus-module.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（19:08:40Z） | PASS |
| S8 | `mgr-failover-20260705T185603Z.DbEpCq` | `mgr-fail.txt`：`ceph mgr fail` 後 `stop-standby-mgr.txt` 停新 standby（`.167`） | health-check：missing in raw（G-5）；ceph 端證據＝`mgr-dump-after-fail.json`（failover 後 mgr map）、`mgr-failover-continuity.json` | `prometheus-alerts-CephMgrNoStandby-none.json`：`CephMgrNoStandby` firing，activeAt `2026-07-05T18:57:22Z`；sink-since：slack `CephMgrNoStandby` | `prometheus-alerts-CephMetricsAbsent-none.json` 內 `CephMetricsAbsent` 僅 `pending` 無 firing（failover 中 metrics 不中斷）✔；`sink-absent-since-checkpoint.log` 無 pager `CephMgrNoStandby` row ✔ | `rollback-start-standby-mgr.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（19:02:35Z） | PASS |
| S9 | `catch-all-risk-20260705T181733Z.AP3yeM` | `config-set-down-out-interval.txt`：`ceph config set mon mon_osd_down_out_interval 0` | `health-check-OSD_NO_DOWN_OUT_INTERVAL.txt`：`[WRN] OSD_NO_DOWN_OUT_INTERVAL: mon ceph-lab-mon-01 has mon_osd_down_out_interval set to 0` | `prometheus-alerts-CephClientRisk-name.json`：`CephClientRisk{name="OSD_NO_DOWN_OUT_INTERVAL"}` firing，activeAt `2026-07-05T18:17:52Z`；sink-since：pager `CephClientRisk/OSD_NO_DOWN_OUT_INTERVAL` | （無） | `rollback-config-rm-down-out-interval.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（18:23:38Z） | PASS |
| S10 | `low-priority-notice-20260706T110427Z.5uGDxz` | `config-set-noout.txt`：`ceph osd set noout` | `health-check-OSDMAP_FLAGS.txt`：`[WRN] OSDMAP_FLAGS: noout flag(s) set` | `prometheus-alerts-CephLowPriorityNotice-name.json`：`CephLowPriorityNotice{name="OSDMAP_FLAGS"}` firing，activeAt `2026-07-06T11:04:52Z`（`for: 30m` 走好走滿）；sink-since：slack `CephLowPriorityNotice/OSDMAP_FLAGS`（severity info） | `sink-absent-since-checkpoint.log` 無 pager `CephLowPriorityNotice` row ✔（log 中的 pager rows 是前一場 S20 的殘留，G-6） | `rollback-config-unset-noout.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（11:35:32Z） | PASS |
| S11 | `latency-outlier-20260705T222226Z.CWR0VV` | cgroup v2 `io.max` 輕度限速 osd.7（`.174`，先 4MiB/s `throttle.txt`，重試段 1MiB/s `retry-throttle.txt`）＋ `rados bench -p alert-latency-outlier 1120 write -t 16` | health-check：missing in raw（G-5）；ceph 端證據＝`postcheck/ceph-health-detail.txt`（rollback 後殘存的 BlueStore latch 記錄） | `prometheus-alerts-CephOSDLatencyOutlier-ceph_daemon.json`：`CephOSDLatencyOutlier{ceph_daemon="osd.7"}` firing，activeAt `2026-07-05T22:44:52Z`；sink-since：slack `CephOSDLatencyOutlier` | `sink-absent-since-checkpoint.log` 8 個 pager rows 中無 `CephOSDLatencyOutlier` ✔（pager rows 是限速副作用 SLOW_OPS / BLUESTORE_SLOW_OP_ALERT，G-6） | `rollback-unthrottle.txt`、`rollback-kill-rados-bench.txt`、`rollback-pool-cleanup-1.txt`；**in-run `HEALTH_OK`：missing in raw**——`recovery/ceph-ready.txt` 最後為 `HEALTH_WARN`（BlueStore latch），`HEALTH_OK` 證據在下一場 S12 的 ready gate（23:14:15Z，G-1） | PASS*（G-1） |
| S12 | `net-slow-heartbeat-20260705T231409Z.FyTXF8` | `tc-qdisc-add.txt`：`tc qdisc add dev ens18 root netem delay 1200ms`（`.174`；`armed-revert-liveness.txt` 證明 auto-revert 計時器已武裝，PID 2174775） | `health-check-OSD_SLOW_PING_TIME.txt`：`[WRN] OSD_SLOW_PING_TIME_FRONT: Slow OSD heartbeats on front (longest 1130.466ms)` | `prometheus-alerts-CephOSDSlowHeartbeat-none.json`：`CephOSDSlowHeartbeat{name="OSD_SLOW_PING_TIME_FRONT"}` firing，activeAt `2026-07-05T23:15:37Z`；sink-since：pager `CephOSDSlowHeartbeat` | （無） | `rollback-tc-qdisc-del.txt`、`rollback-kill-armed-sleeper.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（23:19:29Z） | PASS |
| S13 | `mon-clock-skew-20260705T183710Z.Y9Njvc` | `stop-time-sync.txt`：停 mon-03 的 `chrony`；`skew-clock-forward.txt`：`date -s '+2 seconds'` | `health-check-MON_CLOCK_SKEW.txt`：`[WRN] MON_CLOCK_SKEW: clock skew detected on mon.ceph-lab-mon-03` | `prometheus-alerts-CephMonClockSkew-none.json`：`CephMonClockSkew{name="MON_CLOCK_SKEW"}` firing，activeAt `2026-07-05T18:40:52Z`；sink-since：pager `CephMonClockSkew` | （無） | `rollback-skew-clock-back.txt`（`date -s '-2 seconds'`）、`rollback-start-time-sync.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（18:43:51Z） | PASS |
| S14 | `daemon-crash-20260705T200301Z.SeR8yr` | `kill-segv.txt`：`kill -SEGV 2259806`（真 ceph-osd PID，經 podman-init 父 PID 解析）；crash spool 出現新 crash（`crash-spool-before/after.txt` diff → `crash-id.txt`）；`crash-post.txt` 手動代送 crash meta（G-3） | `health-check-RECENT_CRASH.txt`：`[WRN] RECENT_CRASH: 1 daemons have recently crashed` | `prometheus-alerts-CephDaemonRecentCrash-none.json`：`CephDaemonRecentCrash{name="RECENT_CRASH"}` firing，activeAt `2026-07-05T20:03:22Z`；sink-since：slack `CephDaemonRecentCrash` | `sink-absent-since-checkpoint.log` 無 pager `CephDaemonRecentCrash` row ✔ | `rollback-crash-archive.txt`（`ceph crash archive <id>`）；`recovery/ceph-ready.txt` `HEALTH_OK`（20:08:55Z） | PASS |
| S15 | `osd-flapping-20260705T204103Z.dnQV30` | osd.1（`.169`）連續 stop/start ×2 輪（`stop-osd-1/2.txt`、`start-osd-1/2.txt`；每輪以 `osd-tree-poll-*.json` 與 `prometheus-osd-up-poll-*.json` 確認狀態翻轉被 scrape 到） | health-check：missing in raw（G-5）；ceph 端證據＝`osd-tree-poll-1..4.json`（up/down 翻轉的 osd tree 快照） | `prometheus-alerts-CephOSDFlapping-ceph_daemon.json`：`CephOSDFlapping{ceph_daemon="osd.1"}` firing，activeAt `2026-07-05T20:42:37Z`；sink-since：pager `CephOSDFlapping` | （無） | `rollback-start-osd.txt`（確保最終 started）；`recovery/ceph-ready.txt` `HEALTH_OK`（20:43:20Z） | PASS |
| S16 | `capacity-ladder-20260706T010516Z.xhDJkj` | 量測最滿 OSD 使用率（`measured-fullest-osd-util-percent.txt`）後動態設三階 ratio：`set-nearfull-ratio.txt` 0.00173、`set-backfillfull-ratio.txt` 0.00202、`set-full-ratio.txt` 0.00231，配 `bench-round-1..8.txt`（`rados bench 60s -t 64` ×8 輪）與 `osd-df-round-1..8.json` | `health-check-OSD_NEARFULL.txt`：`[WRN] OSD_NEARFULL: 8 nearfull osd(s)`；`health-check-OSD_FULL.txt`：`[ERR] OSD_FULL: 3 full osd(s)` | `prometheus-alerts-CephOSDNearFull-none.json`：firing，activeAt `2026-07-06T01:17:37Z`；`...CephOSDBackfillFull-none.json`：firing，activeAt `01:27:52Z`；`...CephClientBlocked-name.json`：`{name="OSD_FULL"}` firing，activeAt `01:33:07Z`；`...CephHealthError-none.json`：firing，activeAt `01:33:06Z`；sink-since：slack `CephOSDNearFull`、pager `CephOSDBackfillFull`、pager `CephClientBlocked/OSD_FULL`（同場亦見 `POOL_FULL`）、pager `CephHealthError` | NearFull 階段 `sink-absent-since-checkpoint.log` 無 pager `CephOSDNearFull` row ✔（log 內 pager SLOW_OPS rows 為 bench 副作用，G-6） | 三階 ratio 還原（`rollback-set-{nearfull,backfillfull,full}-ratio.txt` → 0.85/0.9/0.95）、`rollback-pool-delete.txt`、bluestore latch 清除 6 檔；`recovery/ceph-ready.txt` `HEALTH_OK`（01:39:20Z） | PASS |
| S17 | `pool-quota-20260706T001714Z.wfXovq` | `set-quota.txt`：pool `alert-quota` `max_bytes 33554432`（32MiB）；`put-near-quota-1..4.txt` 各塞 4MiB 到 81%；`put-past-quota-5..9.txt`（帶 `timeout 30`）打到滿 | `health-check-POOL_FULL.txt`：`[WRN] POOL_FULL: 1 pool(s) full` | `prometheus-alerts-CephPoolNearQuota-name.json`：`CephPoolNearQuota{name="alert-quota"}` firing，activeAt `2026-07-06T00:17:52Z`；`prometheus-alerts-CephClientBlocked-name.json`：`{name="POOL_FULL"}` firing，activeAt `00:28:37Z`；sink-since：slack `CephPoolNearQuota`、pager `CephClientBlocked/POOL_FULL` | （無） | `rollback-pool-delete.txt`、`rollback-remove-tmpfile.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（00:30:20Z） | PASS |
| S18 | `capacity-forecast-20260706T083041Z.GnwZ4J` | 3 條並行連續 `rados bench` stream（`forecast-bench-stream1/2/3.txt`，各 ~301KB 輸出，撐滿整個注入窗）拉出 `ceph_cluster_total_used_bytes` 成長斜率 | health-check：missing in raw（G-5；`predict_linear` 預測型 alert 本來就沒有對應 ceph health check）；ceph 端證據＝bench stream 輸出與 `postcheck/ceph-health-detail.txt` | `prometheus-alerts-CephCapacityForecast-none.json`：`CephCapacityForecast` firing，activeAt `2026-07-06T08:56:47Z`（`for: 30m`）；sink-since：slack `CephCapacityForecast` | `sink-absent-since-checkpoint.log` 無 pager `CephCapacityForecast` row ✔（log 內 pager SLOW_OPS / BLUESTORE rows 為重負載副作用，G-6） | `rollback-kill-rados-bench.txt`、`rollback-pool-cleanup-1.txt`、bluestore latch 清除 6 檔；`recovery/ceph-ready.txt` `HEALTH_OK`（09:32:50Z） | PASS |
| S19 | `data-damage-20260706T105635Z.usah0u` | `stop-osd.txt` 停 osd.0 → `objectstore-tool-corrupt.txt`：`ceph-objectstore-tool --pgid 35.1d victim set-bytes`（65536B urandom 覆寫單一 replica）→ `start-osd.txt` → `deep-scrub.txt`：`ceph pg deep-scrub 35.1d` | `health-check-OSD_SCRUB_ERRORS.txt`：`[ERR] OSD_SCRUB_ERRORS: 2 scrub errors` | `prometheus-alerts-CephDataDamage-none.json`：`CephDataDamage{name="OSD_SCRUB_ERRORS"}` 與 `{name="PG_DAMAGED"}` 皆 firing，activeAt `2026-07-06T10:57:52Z`；sink-since：pager `CephDataDamage/OSD_SCRUB_ERRORS`、pager `CephDataDamage/PG_DAMAGED` | （無） | `rollback-pg-repair.txt`（`ceph pg repair 35.1d`）、`rollback-health-poll-1/2.txt`（等修復）、`rollback-ensure-osd-started.txt`、`rollback-pool-cleanup-1.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（11:00:00Z） | PASS |
| S20 | `object-unfound-20260706T110029Z.FpGOgz` | 6 步驟（size=2/min_size=1 pool）：`step-1-stop-osd-a.txt`（osd.2）→ `step-2-put-new-version.txt`（改寫 victim object）→ `step-3-set-norecover.txt` → `step-4-start-osd-a.txt` → `step-5-stop-osd-b.txt`（osd.5）→ `step-6-unset-norecover.txt` | `health-check-OBJECT_UNFOUND.txt`：`[WRN] OBJECT_UNFOUND: 1/5 objects unfound (20.000%)` | `prometheus-alerts-CephObjectUnfound-none.json`：`CephObjectUnfound{name="OBJECT_UNFOUND"}` firing，activeAt `2026-07-06T11:01:37Z`；sink-since：pager `CephObjectUnfound/OBJECT_UNFOUND` | （無） | `rollback-start-osd-b.txt`、`rollback-ensure-osd-a-started.txt`、`rollback-health-poll-1..4.txt`（等 unfound 找回）、`rollback-osd-dump-flags.txt`（確認 norecover 已解除）、`rollback-pool-cleanup-1.txt`；`recovery/ceph-ready.txt` `HEALTH_OK`（11:04:02Z） | PASS |
| S21 | `mon-disk-low-20260705T182401Z.u3sK95` | 依 mon-01 實測 `Use% 18%`（`mon-01-df.txt`，free 82%）動態推導門檻（`mon-disk-thresholds.env`：warn=85、crit=83）：`config-set-warn.txt` → `config-set-crit.txt` 兩階段 | `health-check-MON_DISK_LOW.txt`：`[WRN] MON_DISK_LOW: mon ceph-lab-mon-01 is low on available space`；`health-check-MON_DISK_CRIT.txt`：`[ERR] MON_DISK_CRIT: mons ceph-lab-mon-01,ceph-lab-mon-03 are very low on available space` | `prometheus-alerts-CephMonDiskLow-none.json`：firing，activeAt `2026-07-05T18:24:22Z`；`prometheus-alerts-CephMonDiskCritical-none.json`：firing，activeAt `18:34:37Z`；sink-since：slack `CephMonDiskLow`、pager `CephMonDiskCritical` | Low 階段 `sink-absent-since-checkpoint.log` 無 pager `CephMonDiskLow` row ✔ | `rollback-config-rm-warn.txt`、`rollback-config-rm-crit.txt`（還原預設）；`recovery/ceph-ready.txt` `HEALTH_OK`（18:36:47Z） | PASS |
| S22 | `baseline-20260705T181625Z.ORyUqe` | 無注入（Watchdog 是 `vector(1)` 恆 firing 的 dead-man-switch，驗整條 Prometheus→Alertmanager→sink 管線） | `ceph-s.txt` / `ceph-health-detail.txt`：部署時 cluster `HEALTH_OK`（頂層檔，baseline.sh 直寫） | sink-since：watchdog receiver 收到 `{"receiver":"watchdog","alertname":"Watchdog","severity":"none","source":"ceph_coverage"}`；activeAt：missing in raw（baseline.sh 只斷言 sink 送達，未 dump prometheus alerts；Watchdog 的 activeAt 可在後續各場的 prometheus-alerts json 中看到，如 S9 檔內 `2026-07-05T18:16:12Z`） | （無） | 無需 rollback（read-only）；HEALTH_OK＝當下 `ceph-s.txt` | PASS |

## 逐場明細（重試史＋raw 檔案清單）

以下每場列出：run of record 的時間窗（`baseline/ceph-s.txt` 的 `# started` →
`recovery/ceph-ready.txt` 最後 `# ended`）、同 scenario 其他真機 run（重試史）、
scenario 專屬檔案清單（framework 標準檔見範圍宣告，不重複列）。

### S1 `slow-ops` — `slow-ops-20260705T221900Z.Le0WeV`（22:19:00Z → 22:21:41Z）

**重試史**（7 個真機 run）：
- `slow-ops-20260704T095228Z.mvlaD3`、`slow-ops-20260704T100013Z.3Ftncn`：v1 phase
  失敗嘗試（未觸發 SLOW_OPS；後者 recovery 亦未完成）。
- `slow-ops-20260704T101128Z.jVmRwg`：v1 phase 的 PASS（`EVIDENCE-SUMMARY-2026-07-04.md`
  第一列；當時 rules 尚無 `CephDaemonSlowOps`）。
- `slow-ops-20260705T204354Z.jMjDmZ`（fail：`CephDaemonSlowOps` 無 firing 證據＋
  recovery 未回 `HEALTH_OK`；85 個檔含大量 bluestore 清 latch 重試）、
  `slow-ops-20260705T212218Z.00djqC`（fail：`SLOW_OPS` 與 `CephDaemonSlowOps` 皆無）、
  `slow-ops-20260705T215544Z.IxIjfh`（fail：`CephDaemonSlowOps` 無）——三連敗即
  spiky gauge 問題；`efcf5bb`（22:15Z）改 windowed max 後 22:19Z 一次通過。

**scenario 專屬檔案**：
- `selected-target.env`：自動選定的注入目標（osd.4、`.171`、`/dev/sdc`、majmin 8:32、cgroup io.max 路徑）。
- `ceph-volume-method.txt` / `ceph-volume-lvm-list.json` / `ceph-volume-cephadm.err` / `ceph-volume-host.err`：backing device 探測（cephadm 法成功、host 法的 stderr）。
- `osd-find.json` / `osd-map.json`：sentinel object 的 acting set 定位。
- `pool-setup-1..4.txt`：建 pool `alert-slow-ops`（size 3 / min_size 2）＋放 sentinel。
- `throttle.txt`：cgroup v2 `io.max` 設 262144 B/s 的注入命令與結果。
- `rados-bench.txt`（10KB）：`rados bench 420s write -t 64` 輸出（exit 143＝rollback 時被 kill，預期）；`rados-bench.pid` / `rados-bench.child.pid`。
- `health-check-SLOW_OPS.txt`：`ceph health detail` 命中 SLOW_OPS 的當下快照。
- `prometheus-alerts-CephClientBlocked-name.json` / `prometheus-alerts-CephDaemonSlowOps-ceph_daemon.json`：`/api/v1/alerts` dump（各含目標 firing row）。
- `rollback-kill-rados-bench.txt` / `rollback-unthrottle.txt` / `rollback-pool-cleanup-1.txt`：三段 rollback。
- `bluestore-slow-ops-health.txt` / `bluestore-slow-ops-health-poll.txt` / `bluestore-warn-{lifetime,threshold}-{set,rm}.txt`：BLUESTORE_SLOW_OP_ALERT latch 的 age-out 清除（shrink→poll→restore 全程留檔）。

### S2 `pg-availability` — `pg-availability-20260705T233337Z.fghfbC`（23:33:37Z → 23:37:39Z）

**重試史**：`pg-availability-20260704T101846Z.iHPK7a`、`...T102730Z.v5y7kq` 為 v1 phase
（後者是 `EVIDENCE-SUMMARY-2026-07-04.md` 第二列的 PASS；當時無 `CephPGUnhealthyStates`
規則，故不計入 v2 的 run of record）。

**scenario 專屬檔案**：
- `pool-setup-1..4.txt`：建 `alert-pg-availability` pool ＋ sentinel。
- `osd-map.json` / `osd-find-5.json` / `osd-find-7.json`：acting set（osd.5、osd.7）定位。
- `stop-osd-1/2.txt`、`stopped-osds.txt`、`target-osds.txt`：停兩顆 acting OSD 的命令與名單。
- `health-check-PG_AVAILABILITY.txt`：PG_AVAILABILITY 當下 health detail。
- `prometheus-alerts-CephClientBlocked-name.json` / `prometheus-alerts-CephPGUnhealthyStates-name.json`：兩個目標 alert 的 dump。
- `rollback-restart-1/2.txt` / `rollback-pool-delete.txt`：重啟 OSD、刪 pool。

### S3 `mon-quorum-lost` — `mon-quorum-lost-20260706T121047Z.jCUko6`（12:10:47Z → 12:14:22Z）

**重試史**：
- `mon-quorum-lost-20260704T103154Z.W6kB7d`：v1 phase PASS（empty-series 路徑；
  `EVIDENCE-SUMMARY-2026-07-04.md` 第三列，含 stale-telemetry 發現）。
- `mon-quorum-lost-20260706T113554Z.Yjk5gJ`（fail）：`CephMonQuorumLost` firing、pager
  送達，但 `alertmanager-alerts-CephMonDownScoped.json` 裡完全沒有 `CephMonDownScoped`
  （mgr exporter 凍結 → 該 alert 無資料可評估），`wait_alertmanager_inhibited` 超時——
  G-2 的直接證據；之後改用 synthetic POST 驗 inhibit。

**scenario 專屬檔案**：
- `active-mgr.env` / `mgr-dump-before-stop.json`：注入前 active mgr 定位（mgr map dump 192KB）。
- `stop-mon-1/2.txt`、`stopped-mons.txt`：停 mon-01 / mon-03。
- `stop-active-mgr.txt`、`stopped-mgr.txt`：停 active mgr（走 empty-series 路徑）。
- `prometheus-ceph-mon-quorum-lost-expr.json`：rule expr 直接查詢，評值 `"0"`。
- `prometheus-alerts-CephMonQuorumLost-none.json`：`CephMonQuorumLost` firing dump。
- `synthetic-inhibit-post-CephMonQuorumLost-CephMonDownScoped.json`（0B，POST 成功時 wget 回應體為空）＋ `alertmanager-alerts-CephMonDownScoped.json`：synthetic inhibit 驗證。
- `rollback-restart-1/2.txt` / `rollback-restart-mgr.txt`：重啟兩顆 mon 與 mgr。

### S4 `osd-daemon-down` — `osd-daemon-down-20260705T190910Z.iszPzn`（19:09:10Z → 19:15:19Z）

**重試史**：無（一次過）。

**scenario 專屬檔案**：
- `stop-osd.txt` / `rollback-start-osd.txt`：停／啟 osd.0（`.169`）。
- `health-check-OSD_DOWN.txt`：OSD_DOWN health detail。
- `prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json`：目標 firing dump。
- `prometheus-alerts-CephOSDHostDownScoped-hostname.json`：negative 斷言用 dump（無 host-down firing row）。

### S5 `osd-host-down` — `osd-host-down-20260705T191745Z.X9kV6n`（19:17:45Z → 19:24:26Z）

**重試史**：無。

**scenario 專屬檔案**：
- `target-osds.txt`：`.171` 上的 osd 3/4/5。
- `stop-osd-1..3.txt` / `rollback-start-1..3.txt`：停／啟三顆。
- `prometheus-alerts-CephOSDHostDownScoped-hostname.json`：目標 firing dump。
- `prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json`：negative 斷言 dump（osd.3/4/5 均無 per-daemon firing）。

### S6 `mon-down-single` — `mon-down-single-20260705T191541Z.5aTpqF`（19:15:41Z → 19:17:20Z）

**重試史**：無。

**scenario 專屬檔案**：
- `stop-mon.txt` / `rollback-start-mon.txt`：停／啟 mon-03。
- `health-check-MON_DOWN.txt`：MON_DOWN health detail。
- `prometheus-alerts-CephMonDownScoped-ceph_daemon.json`：目標 firing dump（30s `for:`，activeAt 19:16:24Z）。
- `prometheus-alerts-CephMonQuorumLost-none.json`：negative 斷言 dump（無 quorum-lost row）。

### S7 `exporter-blind` — `exporter-blind-20260705T190305Z.l6KleG`（19:03:05Z → 19:08:40Z）

**重試史**：無。

**scenario 專屬檔案**：
- `disable-prometheus-module.txt` / `rollback-enable-prometheus-module.txt`：mgr prometheus module 開關。
- `prometheus-alerts-CephMetricsAbsent-none.json` / `prometheus-alerts-CephExporterAllDown-none.json`：兩個目標 firing dump（同檔可見副作用 `CephMonQuorumLost` firing——exporter 全滅時 quorum 規則 fallback 到 `or vector(0)`，證實 v1 發現在 v2 規則下仍會發生，屬預期告警行為）。

### S8 `mgr-failover` — `mgr-failover-20260705T185603Z.DbEpCq`（18:56:03Z → 19:02:35Z）

**重試史**：`mgr-failover-20260705T184416Z.z6w8Ve`（fail：
`prometheus-alerts-CephMgrNoStandby-none.json` 無 firing row）。

**scenario 專屬檔案**：
- `mgr-fail.txt`：`ceph mgr fail`。
- `mgr-dump-after-fail.json`：failover 後 mgr map（確認新 active）。
- `mgr-failover-continuity.json`：failover 期間 metrics 連續性查詢。
- `standby-mgr.env` / `stop-standby-mgr.txt` / `rollback-start-standby-mgr.txt`：定位並停／啟 standby mgr（`.167`）。
- `prometheus-alerts-CephMgrNoStandby-none.json`：目標 firing dump。
- `prometheus-alerts-CephMetricsAbsent-none.json`：negative 斷言 dump（僅 pending，無 firing）。

### S9 `catch-all-risk` — `catch-all-risk-20260705T181733Z.AP3yeM`（18:17:33Z → 18:23:38Z）

**重試史**：無（v2 戰役第一場，監控 stack 剛部署完，`sink-checkpoint.log` 僅 193B）。

**scenario 專屬檔案**：
- `config-set-down-out-interval.txt` / `rollback-config-rm-down-out-interval.txt`：config 注入／還原。
- `health-check-OSD_NO_DOWN_OUT_INTERVAL.txt`：health detail 命中行。
- `prometheus-alerts-CephClientRisk-name.json`：目標 firing dump。

### S10 `low-priority-notice` — `low-priority-notice-20260706T110427Z.5uGDxz`（11:04:27Z → 11:35:32Z，`for: 30m` 全程）

**重試史**：無。

**scenario 專屬檔案**：
- `config-set-noout.txt` / `rollback-config-unset-noout.txt`：noout 設／解。
- `health-check-OSDMAP_FLAGS.txt`：health detail 命中行。
- `prometheus-alerts-CephLowPriorityNotice-name.json`：目標 firing dump。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：pager 無 `CephLowPriorityNotice` 的 negative 證據（內有 S20 殘留 rows，G-6）。

### S11 `latency-outlier` — `latency-outlier-20260705T222226Z.CWR0VV`（22:22:26Z → 23:01:22Z，PASS*）

**重試史**：無其他 run；本 run 內含一次設計內重試（`retry-throttle.txt` 把限速從
4MiB/s 收緊到 1MiB/s 後 `CephOSDLatencyOutlier` 才過 10m `for:`）。

**scenario 專屬檔案**：
- `selected-target.env` / `ceph-volume-*` / `osd-find.json` / `osd-map.json`：目標定位（osd.7、`.174`）。
- `pool-setup-1..4.txt`：建 `alert-latency-outlier` pool。
- `throttle.txt` / `retry-throttle.txt` / `rollback-unthrottle.txt`：兩段限速與還原。
- `rados-bench.txt`（78KB）：長時 bench（1120s -t 16）輸出。
- `prometheus-alerts-CephOSDLatencyOutlier-ceph_daemon.json`：目標 firing dump（同檔可見副作用 SLOW_OPS / BLUESTORE / CephDaemonSlowOps rows）。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：pager 無 `CephOSDLatencyOutlier` 的 negative 證據。
- `rollback-kill-rados-bench.txt` / `rollback-pool-cleanup-1.txt`：清 bench 與 pool。
- **注意**：`recovery/` 僅有 `ceph-ready.txt`（`HEALTH_WARN`，G-1）；本場無 bluestore latch 清除檔（helper 當時尚未接進本 scenario，`f22efc4` 才補）。

### S12 `net-slow-heartbeat` — `net-slow-heartbeat-20260705T231409Z.FyTXF8`（23:14:09Z → 23:19:29Z）

**重試史**：無。

**scenario 專屬檔案**：
- `target-iface.txt`：注入介面 `ens18`。
- `tc-qdisc-add.txt`：netem delay 1200ms 注入。
- `armed-revert.pid` / `armed-revert-liveness.txt`：預武裝 auto-revert 計時器（`kill -0` 驗活）。
- `health-check-OSD_SLOW_PING_TIME.txt`：OSD_SLOW_PING_TIME_FRONT 命中行。
- `prometheus-alerts-CephOSDSlowHeartbeat-none.json`：目標 firing dump。
- `rollback-tc-qdisc-del.txt` / `rollback-kill-armed-sleeper.txt`：拆 qdisc、殺計時器（後者 exit 255＝pkill 無匹配亦可，`|| true` 保護）。

### S13 `mon-clock-skew` — `mon-clock-skew-20260705T183710Z.Y9Njvc`（18:37:10Z → 18:43:51Z）

**重試史**：無。

**scenario 專屬檔案**：
- `time-sync-unit.txt`：偵測到的時間同步 unit（`chrony`）。
- `stop-time-sync.txt` / `skew-clock-forward.txt`：停 chrony、撥快 2 秒。
- `health-check-MON_CLOCK_SKEW.txt`：MON_CLOCK_SKEW 命中行。
- `prometheus-alerts-CephMonClockSkew-none.json`：目標 firing dump。
- `rollback-skew-clock-back.txt` / `rollback-start-time-sync.txt`：撥回、重啟 chrony。

### S14 `daemon-crash` — `daemon-crash-20260705T200301Z.SeR8yr`（20:03:01Z → 20:08:55Z）

**重試史**：`daemon-crash-20260705T192451Z.inpmM0`（fail：`kill -SEGV 2251917` exit 0
但 `health-check-RECENT_CRASH.txt` 始終沒有 RECENT_CRASH 行，也無 crash spool 檔——
舊版腳本 kill 的 PID 不是真 ceph-osd；PASS run 的腳本改為解析 podman-init 子 process
拿真 ceph-osd PID 並 diff crash spool，見 `scenario-daemon-crash.sh` 檔頭註解與 G-3）。

**scenario 專屬檔案**：
- `target-osd-container.txt` / `target-osd-pid.txt`：目標 container 與真 ceph-osd host PID（2259806）。
- `crash-spool-before.txt` / `crash-spool-after.txt` / `crash-id.txt`：crash spool 前後 diff → 新 crash id。
- `kill-segv.txt`：`kill -SEGV` 注入。
- `crash-post.txt`：crash meta（base64）經 admin shell 代送 `ceph crash post`（G-3）。
- `health-check-RECENT_CRASH.txt`：RECENT_CRASH 命中行。
- `prometheus-alerts-CephDaemonRecentCrash-none.json`：目標 firing dump。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：pager 無 `CephDaemonRecentCrash` 的 negative 證據。
- `rollback-crash-archive.txt`：`ceph crash archive` 清 RECENT_CRASH。

### S15 `osd-flapping` — `osd-flapping-20260705T204103Z.dnQV30`（20:41:03Z → 20:43:20Z）

**重試史**：`osd-flapping-20260705T200918Z.9r8S02`、`...T202428Z.4EBJMx`（皆 fail：
`prometheus-alerts-CephOSDFlapping-ceph_daemon.json` 無 firing row——規則 expr 為
`changes(ceph_osd_up[15m]) >= 4`，前兩次的翻轉未讓計數過線）。

**scenario 專屬檔案**：
- `stop-osd-1/2.txt` / `start-osd-1/2.txt`：osd.1 兩輪 stop/start。
- `osd-tree-poll-1..4.json`（＋`.log`）：每次翻轉後 `ceph osd tree` 確認 up/down 狀態。
- `prometheus-osd-up-poll-1..4.json`：每次翻轉後查 `ceph_osd_up`，確認 Prometheus 真的 scrape 到翻轉。
- `prometheus-alerts-CephOSDFlapping-ceph_daemon.json`：目標 firing dump。
- `rollback-start-osd.txt`：確保 osd.1 最終 started。

### S16 `capacity-ladder` — `capacity-ladder-20260706T010516Z.xhDJkj`（01:05:16Z → 01:39:20Z）

**重試史**：`capacity-ladder-20260706T003038Z.GUOzaq`（fail：四階段斷言全缺＋recovery
未完成——ratio/寫入量計算未把 OSD 推過門檻）。

**scenario 專屬檔案**：
- `measured-fullest-osd-util-percent.txt` / `measured-fullest-osd-util-ratio.txt`：實測最滿 OSD 使用率（動態門檻的輸入）。
- `set-{nearfull,backfillfull,full}-ratio.txt`：三階 ratio 注入（0.00173 / 0.00202 / 0.00231）。
- `pool-create.txt` / `pool-set-size.txt` / `pool-set-min-size.txt`：`alert-capacity` pool。
- `bench-round-1..8.txt` / `osd-df-round-1..8.json`：8 輪 bench ＋ 每輪 `osd df` 快照（爬梯過程）。
- `health-check-OSD_NEARFULL.txt` / `health-check-OSD_FULL.txt`：兩階 health 命中行。
- `prometheus-alerts-CephOSDNearFull-none.json` / `...CephOSDBackfillFull-none.json` / `...CephClientBlocked-name.json` / `...CephHealthError-none.json`：四階目標 firing dump。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：NearFull 階段 pager 無 `CephOSDNearFull` 的 negative 證據。
- `rollback-set-{nearfull,backfillfull,full}-ratio.txt`：還原 0.85 / 0.9 / 0.95。
- `rollback-pool-delete.txt` ＋ bluestore latch 清除 6 檔。

### S17 `pool-quota` — `pool-quota-20260706T001714Z.wfXovq`（00:17:14Z → 00:30:20Z）

**重試史**：`pool-quota-20260705T233756Z.33q5jb`（fail：`CephPoolNearQuota` 過了，但
POOL_FULL 階段未達成——`CephClientBlocked{name="POOL_FULL"}` 無 firing 證據）。

**scenario 專屬檔案**：
- `pool-setup-1..4.txt` / `set-quota.txt`：`alert-quota` pool ＋ 32MiB quota。
- `create-tmpfile.txt` / `rollback-remove-tmpfile.txt`：4MiB 測試檔備／清。
- `put-near-quota-1..4.txt`：受控寫到 81%。
- `put-past-quota-5..9.txt`：打滿 quota（帶 `timeout 30`，滿了會 block 是預期）。
- `ceph-df-check-1..9.json`：每步 `ceph df` 快照。
- `health-check-POOL_FULL.txt`：POOL_FULL 命中行。
- `prometheus-alerts-CephPoolNearQuota-name.json` / `prometheus-alerts-CephClientBlocked-name.json`：兩階目標 firing dump。
- `rollback-pool-delete.txt`：刪 pool。

### S18 `capacity-forecast` — `capacity-forecast-20260706T083041Z.GnwZ4J`（08:30:41Z → 09:32:50Z）

**重試史**（9 個失敗 run，本場最難搞）：
- `...T014344Z.tvwK21`、`...T025737Z.i263vy`（fail：`CephCapacityForecast` 未 firing
  ＋ recovery 未完成）。
- `...T050546Z.koMYdA`、`...T050704Z.jyFDOc`、`...T050736Z.DKFMjd`、`...T050811Z.GwNe60`、
  `...T050848Z.59Ma8f`：五個短命 run，都在 pool setup 早段中止（目錄內只有
  `pool-create.txt`／`pool-set-size.txt` 等前置檔，無任何 verify 證據）。
- `...T073258Z.y3XLho`、`...T075949Z.dNqMEE`（fail：`CephCapacityForecast` 無 firing
  row。檔名為 `forecast-bench-loop-stream*`＝舊「分輪迴圈」設計；PASS run 的檔名是
  `forecast-bench-stream*`＝改為連續執行到底的 stream 設計後才過）。

**scenario 專屬檔案（run of record）**：
- `pool-create.txt` / `pool-set-size.txt` / `pool-set-min-size.txt`：`alert-forecast` pool（pg 32）。
- `forecast-bench-stream1/2/3.txt`（各 ~301KB）＋ `.pid` / `.child.pid`：3 條並行連續 `rados bench` stream 全程輸出。
- `prometheus-alerts-CephCapacityForecast-none.json`：目標 firing dump（activeAt 08:56:47Z，`for: 30m` 撐滿後 sink 送達）。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：pager 無 `CephCapacityForecast` 的 negative 證據。
- `rollback-kill-rados-bench.txt` / `rollback-pool-cleanup-1.txt` ＋ bluestore latch 清除 6 檔。

### S19 `data-damage` — `data-damage-20260706T105635Z.usah0u`（10:56:35Z → 11:00:00Z）

**重試史**：
- `data-damage-20260706T093332Z.AADRAM`、`...T095323Z.j1egEb`（fail：`CephDataDamage`
  無 firing 證據）。第一次失敗在 `23314bc`（09:52Z，data-integrity alerts 窗化）之前；
  第二次（09:53:23Z 起跑）與 redeploy 幾乎同時，無法從 raw 斷定跑在哪一版 rules 下。
- `data-damage-20260706T102759Z.pMJdjG`：第一次 PASS（10:27Z）；
  `...T105635Z.usah0u`（10:56Z）再跑一次、同樣 PASS——兩份 raw 都完整，取最後一次為
  run of record。

**scenario 專屬檔案**：
- `pool-setup-1..4.txt`：`alert-damage` pool ＋ victim object。
- `osd-find.json` / `osd-map.json`：victim 的 acting set / pgid（35.1d）定位。
- `stop-osd.txt` → `objectstore-tool-corrupt.txt`（`set-bytes` 覆寫 65536B garbage）→ `start-osd.txt` → `deep-scrub.txt`：四步注入鏈。
- `osd-tree-poll-1..4.json`（＋`.log`）/ `pg-query-poll-1.json`（＋`.log`）：OSD 狀態與 PG 狀態輪詢。
- `health-check-OSD_SCRUB_ERRORS.txt`：scrub error 命中行。
- `prometheus-alerts-CephDataDamage-none.json`：目標 firing dump（OSD_SCRUB_ERRORS ＋ PG_DAMAGED 兩個 name variant 皆 firing）。
- `rollback-pg-repair.txt` / `rollback-health-poll-1/2.txt` / `rollback-ensure-osd-started.txt` / `rollback-pool-cleanup-1.txt`：repair→等健康→清 pool。

### S20 `object-unfound` — `object-unfound-20260706T110029Z.FpGOgz`（11:00:29Z → 11:04:02Z）

**重試史**：無。

**scenario 專屬檔案**：
- `pool-setup-1..4.txt`：`alert-unfound` pool（size=2 / min_size=1）＋ victim。
- `osd-map.json` / `osd-find-2.json` / `osd-find-5.json`：兩顆 acting OSD（osd.2、osd.5）定位。
- `step-1-stop-osd-a.txt` … `step-6-unset-norecover.txt`：6 步注入鏈（含 `rados put` 造出兩版本、`norecover` 開關）。
- `osd-tree-poll-1..3.json`（＋`.log`）：步驟間 OSD 狀態確認。
- `health-check-OBJECT_UNFOUND.txt`：OBJECT_UNFOUND 命中行（1/5 objects unfound）。
- `prometheus-alerts-CephObjectUnfound-none.json`：目標 firing dump。
- `rollback-start-osd-b.txt` / `rollback-ensure-osd-a-started.txt` / `rollback-health-poll-1..4.txt` / `rollback-osd-dump-flags.txt` / `rollback-pool-cleanup-1.txt`：復原鏈（等 unfound 找回、確認 flags 乾淨、刪 pool）。

### S21 `mon-disk-low` — `mon-disk-low-20260705T182401Z.u3sK95`（18:24:01Z → 18:36:47Z）

**重試史**：無。

**scenario 專屬檔案**：
- `mon-01-df.txt`：mon-01 資料碟實測 `Use% 18%`（門檻推導輸入）。
- `mon-disk-thresholds.env`：推導結果 used_pct=18 / free_pct=82 / warn=85 / crit=83。
- `config-set-warn.txt` / `config-set-crit.txt`：兩階段 config 注入。
- `health-check-MON_DISK_LOW.txt` / `health-check-MON_DISK_CRIT.txt`：兩階 health 命中行。
- `prometheus-alerts-CephMonDiskLow-none.json` / `prometheus-alerts-CephMonDiskCritical-none.json`：兩階目標 firing dump。
- `sink-absent-check.log` / `sink-absent-since-checkpoint.log`：Low 階段 pager 無 `CephMonDiskLow` 的 negative 證據。
- `rollback-config-rm-warn.txt` / `rollback-config-rm-crit.txt`：還原預設。

### S22 `watchdog` — `baseline-20260705T181625Z.ORyUqe`（18:16:25Z 起）

**重試史**：`baseline-20260704T095200Z.7rOZq6` 是 v1 phase 的 baseline（無 watchdog
sink 斷言檔，G-7），不計入。07-05 之後的其餘 `baseline-*` 目錄皆為 fake 測試殘留
（無 fsid）。

**檔案清單**（baseline.sh 直寫頂層，無 framework 子目錄）：
- `ceph-s.txt` / `ceph-health-detail.txt` / `ceph-osd-tree.txt` / `ceph-quorum-status.json`：cluster 快照（`HEALTH_OK`）。
- `mgr-metrics-192.168.18.166-9283.txt`（30KB，active）/ `mgr-metrics-192.168.18.167-9283.txt`（134B，standby 空回應）：兩個 exporter 端點的 `/metrics`。
- `rook-cephcluster.txt` / `rook-pods.txt`：Rook external 狀態。
- `sink-checkpoint.log`（0B，剛部署完無歷史）/ `sink-checkpoint-lines.txt` / `sink-checkpoint.log.err`：checkpoint。
- `sink.log` / `sink-since-checkpoint.log`：各一條 watchdog receiver 的 `Watchdog` row——S22 的 PASS 證據。

## 與既有文件的關係

- `EVIDENCE-SUMMARY-2026-07-04.md`：v1 phase（3 場、舊 rules）的索引，所引用的
  `slow-ops-20260704T101128Z.jVmRwg`、`pg-availability-20260704T102730Z.v5y7kq`、
  `mon-quorum-lost-20260704T103154Z.W6kB7d` 在本文件中列為 S1/S2/S3 的重試史（v1
  發現——stale telemetry、BLUESTORE 伴生、POOL_APP_NOT_ENABLED——仍成立）。
- 本文件是 22 場宣稱的**唯一 git 內總帳**；網站 MDX 頁引用數字時應以本文件為準。
