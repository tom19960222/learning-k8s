# ceph-time-sync-alerts — 實驗執行計畫

目標：驗證（並修正）「NTP 採集 script + ceph-ntp alert 規則」在極高敏感生產 Ceph cluster
的偵測能力。假設清單與現有證據見 `HYPOTHESES.md`（Gate 1 先 triage 再開跑）。

最終產出物（實驗收官後）：
1. 完整實驗報告（`skills/writing-experiment-reports/SKILL.md` 格式：逐實驗五欄 + 參數建議總表）
2. 修正版採集 script（`collect_time_sync.sh`，支援 timesyncd + chrony、防呆、meta-metrics）
3. 修正版 alert rules（三層防禦：kernel timex / NTP daemon / ceph health）
4. 設計說明（每條規則對應的失效模式、門檻依據、偵測延遲預算表）

## 1. 方法論

- 迴圈：`skills/researching-system-behavior/SKILL.md`（Frame → Enumerate → Falsify → Automate → Synthesize）
- 每個實驗都走 `inject → observe → collect → rollback → assert`，prediction 先寫死、機器比對
- 重用 `experiments/timesyncd/` harness：`fake_ntp_server.py`（可控上游、可指定回錯時間）、
  `clock_inject.py`（step / ppm 注入與 reset）、iptables udp/123 斷線注入、cleanup trap 慣例

## 2. 實驗環境（Azure lab — 連線資訊見 `~/Documents/code/azure-iac-lab/ACCESS.md`，不進版控）

實機為 `cyshih-kubevirt-ceph-lab`（japanwest）：3× K8s（1 control-plane + 2 worker）+
3× Ceph mon + 3× OSD，Ceph HEALTH_OK / 3 mon quorum / 9 OSD。整組可 `make deploy` 重建 —
是消耗性實驗環境，但破壞性實驗（E-09/E-11）仍走 Gate 2 紀律（練的就是生產程序）。

| 層級 | 使用節點 | 用途 |
|---|---|---|
| L1 | 本機 macOS | script/parser/promtool 單元測試（已完成，見 §E-05a/E-01 回填）|
| L2 | `cyshih-k8s-1`（worker，對 Ceph 零影響、對 K8s 影響最小）| parser 端到端覆核、metric 語意、offset 凍結曲線 |
| L3 | 3× K8s node 當 client；fake NTP server + Prometheus/Alertmanager 部署位置由 E-00 定（cephadm 內建 stack 或 K8s 部署）| alert 全鏈路、對稱 skew、共模、偵測延遲 |
| L4 | 3× mon + 3× OSD（真 Ceph）| MON_CLOCK_SKEW 賽跑、cephadm textfile 路徑、observer 失效 |

**Azure 特有注意事項（取代先前 PVE 版）**：
- **Hyper-V host time sync 是本環境的未知干擾源**：`hv_utils` 的 TimeSync 整合服務與
  `/dev/ptp_hyperv`（PTP 裝置）可能在 pause/resume 後撥動 guest 時鐘，干擾注入實驗。
  E-00 必查（`lsmod`、`/sys/class/ptp/*/clock_name`、chrony 是否吃 PHC refclock），
  實驗前決定是否需要抑制。
- **實驗窗口內不得 `make stop`/`make start`**：stop 會 deallocate 並清空 Ceph 資料
  （本地 NVMe），等於整個 L4 重來。實驗窗口與 lab 生命週期操作互斥。
- NSG 只放行工作機 IP 的 22/6443 → Prometheus/Alertmanager UI 走 SSH tunnel
  （`ssh -L 9090:localhost:9090 ...`）。
- 共享訂閱：只動 `cyshih-*` 資源。
- E-06 共模 +5min 會撥動 K8s node 時鐘：kubelet lease/cert 對 ±5min 容忍度 OK，
  但實驗中順手記錄 K8s 症狀（bonus 觀測，不是目標）。
- mon node 的時鐘注入回退：**只用 capture/restore + daemon resync**，Azure 沒有
  「snapshot 回滾單一 mon」的選項（本來也禁止 — 見 §5）。

## 3. 實驗總覽表

| 編號 | 目的 | 變因（唯一）| 調整參數與值域 | 層級 | 破壞性 | 驗證假設 |
|---|---|---|---|---|---|---|
| E-00 | 環境盤點（不是實驗，是前提校正）| — | — | 全部 | 無 | 全部前提 |
| E-01 | parser 對 offset 字串全格式的行為 | offset 字串格式 | `812us`/`45.2ms`/`2.337s`/`+1min 2s`/`+1h 2min`/`n/a`/缺行/空輸出 | L1→L2 | 無 | H-001, H-007 |
| E-02 | 部分指令失敗時 textfile 的下場 | 失敗的指令 | packet_count 空 / `show` 失敗 / timedatectl hang（SIGSTOP）| L2 | 無 | H-003, H-006, H-031 |
| E-03 | offset 凍結 vs 真實漂移發散 | poll interval | `PollIntervalMaxSec` = 32 / 256 / 2048s；drift 100ppm；斷線 30min | L2 | 低（可逆）| H-005, H-008, H-022, H-023 |
| E-04 | chrony 環境下 script 全滅驗證（robustness，生產已確認用 timesyncd）| NTP daemon 種類 | timesyncd ↔ chrony 切換 | L2 | 低 | H-002, H-004 |
| E-05a | 現行+新規則的 promtool 單元測試（**機器到位前就能做**）| 合成 series 情境 | H-010~H-014/H-016/H-032 全部 label set、absent、稀疏 counter、for 轉換 | L1 | 無 | H-010–H-014, H-016, H-032 |
| E-05 | 現行 3 條 alert 實機判決（E-05a 通過後的 live 子集）| 注入模式 | 死分支（無注入）/ ±40ms 對稱 / poll 拉長 / 斷線 rate==0 / 條件輪替 | L3 | 低 | H-010–H-014, H-016 |
| E-06 | 全 cluster 同步漂移全盲驗證 | upstream 時間 | fake upstream 撥快 0 / +5min | L3 | 低 | H-015, H-034 |
| E-07 | 端到端偵測延遲預算（三種注入機制分開量）| 採集/評估節奏 | cron 15s/60s × scrape 15s/30s × for 0/1m/3m；注入=斷NTP+drift（持續）與一次性 step（transient，會自癒 H-033）| L3 | 低 | H-020 前半, H-033 |
| E-08 | 新版 script + rules 回歸驗證 | rule set 版本 | 舊 rules ↔ 新 rules，重放 E-05/E-06/E-07 全部注入 | L3 | 低 | 全部修正項 |
| E-09 | 與 MON_CLOCK_SKEW 賽跑 | 注入 skew 量 | mon node step +60ms / +100ms（> `mon_clock_drift_allowed`=50ms）| L4 | **中（真 mon）** | H-020, H-011 實地版 |
| E-10 | 觀測鏈自身失效 | 殺掉的環節 | 停 cron timer / 停 node-exporter / 寫壞 `.prom` | L4 | 低 | H-030, H-031, H-004 |
| E-11 | mgr 凍結時 node 層仍活著 | mon quorum | 停 2/3 mon（沿用 mon-quorum SP 流程）+ 同時注入 skew | L4 | **高（quorum）** | H-021 |

E-09 / E-11 為破壞性操作 → Gate 2：人工駕駛、逐步可回退、`ceph mon ok-to-stop` +
quorum 預檢、結束必須回 `HEALTH_OK` 才進下一步。E-11 標 optional：H-021 已有先前 SP
證據，只在 Gate 1 判定需要實地重證時才跑。

## 4. 單一實驗六欄詳表

### E-00 環境盤點

| 欄位 | 內容 |
|---|---|
| 目的 | 校正所有 T1 前提：目標機的 systemd 版本（parser 行為）、NTP daemon 種類、node_exporter collector 清單（timex 是否啟用）、cephadm textfile 實際路徑、Prometheus scrape/eval interval、現行 cron/timer 部署方式 |
| 變因 | 無（純觀測）|
| 調整的參數 | 無 |
| 做法 | 每台：`systemctl --version`、`systemctl status systemd-timesyncd chronyd chrony`、`timedatectl show`、`curl -s localhost:9100/metrics \| grep -c timex`、`ls /var/lib/ceph/*/node-exporter.*/etc/node-exporter`、Prometheus config dump。生效驗證：輸出存 `results/e00-inventory/<host>.txt` |
| 預期結果 | timesyncd（使用者已確認生產用 timesyncd，E-00 實地覆核版本與設定）；timex collector 啟用；textfile 路徑與 script 內建路徑一致 |
| 回填表 | （實測後填：systemd 版本＝？daemon＝？timex＝？路徑＝？scrape/eval＝？）|

### E-01 parser 邊界矩陣

| 欄位 | 內容 |
|---|---|
| 目的 | 證明/否證 H-001：offset ≥ 1min 時 parser 輸出錯誤值；並枚舉所有非常態輸出的下場 |
| 變因 | `timedatectl timesync-status` 的 Offset 字串格式（唯一變因，其他欄位固定）|
| 調整的參數 | 格式值域：`812us` / `-45.2ms` / `+2.337s` / `+59.9s` / `+1min 2.337s` / `+1h 2min 3s` / `+1d` / `n/a` / Offset 行缺失 / 整個指令 exit non-zero |
| 做法 | L1：fake `timedatectl`（PATH 覆蓋）逐格式跑 script，斷言 `.prom` 內容（TDD，進 `tests/`）。L2：真 timesyncd + `clock_inject.py` 注入 step 讓真實輸出落在 <1s、1–60s、>60s 三區，對照 fake 的結論。生效驗證：注入後 `timedatectl timesync-status` 肉眼確認格式再跑 script |
| 預期結果 | 先寫死：`+1min 2.337s` → 輸出 `1.000000000`（錯 62 倍）；`+1h 2min` → `1.000000000`；`n/a` → **輸出 `0.000000000`（匯報完美同步，lying；codex 修正 — 非 unavailable 分支）**；Offset 整行缺失（首次 sync 前的正常態）→ unavailable 分支；60s 以下全對。機器比對 `.prom` 實際值 |
| 回填表 | （每格式一列：輸入字串／預期輸出／實測輸出／verdict）|

### E-02 部分失敗與壞檔行為

| 欄位 | 內容 |
|---|---|
| 目的 | 證明/否證 H-003（無值行 → node_exporter 拒收整檔）與 H-006（D-Bus hang 無界阻塞）|
| 變因 | 三個資料來源指令中「哪一個失敗」|
| 調整的參數 | 失敗模式值域：packet_count 回空 / `timedatectl show` 失敗 / `timedatectl` hang（`kill -STOP systemd-timesyncd` 或 fake 卡住）/ 兩個 script instance 並發（H-035）|
| 做法 | L2 真 node_exporter：逐模式製造失敗 → 跑 script → `curl localhost:9100/metrics`。生效驗證：確認 `.prom` 內容確實含無值行再查 exporter 行為。hang 情境：量 script 阻塞時長、同時起第二個 script instance 觀察疊加與 `.tmp` 互踩 |
| 預期結果 | 先寫死：無值行 → `node_textfile_scrape_error=1`（target 級、無 file label）且該檔**全部** metrics 消失（含正常 offset 與 mtime series — textfile.go:269-314）；hang → script 阻塞**有界 ≈ 2×25s**（sd-bus `BUS_DEFAULT_TIMEOUT`，codex 修正 — 非無限），但仍超過 15–60s 採集週期 → instance 疊加。若 node_exporter 實際只丟單行 → H-003 violated（一樣是發現）|
| 回填表 | （模式／scrape_error 值／其他 metrics 存活？／script 阻塞時長）|

### E-03 offset 凍結 vs 真實漂移

| 欄位 | 內容 |
|---|---|
| 目的 | 量化 H-005 的凍結窗；順帶取得 H-008（rate==0 窗口）、H-022（maxerror 累加率）、H-023（NTPSynchronized 翻轉時機）的實測曲線 |
| 變因 | `PollIntervalMaxSec`（唯一變因；drift 與斷線時長固定）|
| 調整的參數 | PollIntervalMaxSec = 32 / **256（生產將採用的參數，主線 cell）** / 2048（預設組對照）；固定注入 100ppm（`clock_inject.py`）；固定斷線 30min（iptables OUTPUT udp/123 DROP，只動這條）|
| 做法 | 每 cell：暖機至 max poll → 注入 ppm → 斷線 → 每 5s 採樣四路訊號（script 的 offset、`ntp_probe` 量的真實 offset、`node_timex_offset_seconds`、`node_timex_maxerror_seconds`、`NTPSynchronized`）→ 30min 後解封 → 觀察收斂 → `clock_inject.py reset` 回退。生效驗證：斷線後 `timesync-status` packet count 停止增長 |
| 預期結果 | 先寫死：script offset 凍在斷線前值；真實 offset 線性發散 ~6ms/min；maxerror 穩定累加；`rate(packet_count[5m])` 在 poll=2048 的健康段（未斷線）就常態為 0（H-014 的 L2 版）；NTPSynchronized 30min 內不翻 no（待證）|
| 回填表 | （poll 值／凍結窗實測／發散率／maxerror 斜率／sync flag 翻轉時刻）|

### E-04 chrony 環境

| 欄位 | 內容 |
|---|---|
| 目的 | 證明 H-002（chrony 下全滅）並確立新 script 的雙 backend 需求規格 |
| 變因 | NTP daemon 種類 |
| 調整的參數 | systemd-timesyncd ↔ chrony（`apt install chrony` 自動接管）|
| 做法 | L2：切到 chrony → 跑 script → 檢查 `.prom` 與 Prometheus series 消失時序（staleness 5min）。同時記錄 `chronyc tracking -c` 的可用欄位（offset/root distance/stratum/leap/freq/skew）當新 script 的資料來源規格。回退：移除 chrony、restart timesyncd |
| 預期結果 | 先寫死：`timedatectl timesync-status` exit non-zero → unavailable 分支 → series 5min 後 absent → 三條 alert 全綠（H-004 連動證明）|
| 回填表 | （daemon／script 行為／series 消失時刻／alert 反應＝預期無）|

### E-05a promtool 規則單元測試（機器到位前執行，L1）

| 欄位 | 內容 |
|---|---|
| 目的 | （codex finding 15）PromQL 語意是決定性的，不需要機器：用 `promtool test rules` 把 H-010~H-014、H-016、H-032 的全部 label set、absent-series、稀疏 counter 窗口、`for:` 身分轉換先窮舉完，L3 機器只留給「規則以外」的真實世界（exporter 時序、daemon 行為、通知遞送）|
| 變因 | 合成 series 情境（每 case 一組 input series + 預期 ALERTS 輸出）|
| 調整的參數 | 情境值域：死分支 6 個 metric absent / ±40ms 對稱 / 條件(1)↔(2) 轉換（同空 label set，for 不重置 — H-012 修正版）/ 條件(1)↔(3) 轉換（for 重置）/ poll 2048 稀疏 counter / 非 Ceph 主機 series 混入（H-032）|
| 做法 | 寫 `tests/promtool/*.test.yml`（TDD：先寫預期會揭露缺陷的 case）→ `promtool test rules` 對 `current/ceph-ntp-alerts.yml` 跑 → 每 case 斷言 exp_alerts。新規則寫好後同一套測試反向斷言 |
| 預期結果 | 先寫死：現行規則在死分支 case 全部零 alert；對稱 skew case 零 alert；`or on()` 身分轉換 case 依 H-012 修正版預測；稀疏 counter case 誤發。全部由 promtool 機器判定 |
| 回填表 | **已執行 2026-07-23（promtool 3.12.0）：9/9 全數 confirmed** — T1 對稱 ±40ms 沉默✓／T2 陽性對照 fire✓／T3 死分支+250ms 絕對偏差沉默✓／T4 稀疏 counter 10 分鐘即誤發✓／T5 健康節點因 poll=2048 永久 warning✓／T6 (1)→(2) 轉換不重置、3m 準時 fire✓／T7 (1)→(3) 轉換重置、5m 沉默 7m 才 fire✓／T8 app-42 主機令 Ceph alert 誤 fire✓／T9 採集死亡令 firing alert 靜默 auto-resolve✓。詳見 `tests/promtool/current-rules.test.yml`，gate = `bash tests/run-tests.sh` |

### E-05 現行 alert 實機判決（E-05a 通過後的 live 子集）

| 欄位 | 內容 |
|---|---|
| 目的 | 對現行 3 條 rule 的 7 個條件逐一給 fire/不 fire 判決，證明 H-010～H-014、H-016 |
| 變因 | 注入模式（每 scenario 一種，序列執行）|
| 調整的參數 | (a) 無注入健康態 24h（看 H-013/H-014 的 FP）；(b) node1 +40ms、node2 -40ms（H-011）；(c) 單 node step +200ms 網路乾淨（H-016）；(d) 單 node 斷線（rate==0 路徑）；(e) 條件輪替：先製造 spread 2min、再轉 unsync（H-012 的 for-reset）；(f) 死分支確認：對 6 個缺失 metric 下 `absent()` 查詢 + 全注入期間確認 `CephNTPServiceMisconfigured` 恆綠 |
| 做法 | L3 三 client + Prometheus/Alertmanager 載入**原封不動的現行規則**。每 scenario：記 baseline → 注入 → 觀察 `ALERTS{}` 與 Alertmanager API 到預測窗結束 → 回退（`clock_inject.py reset` / iptables 解封）→ assert 回 baseline。生效驗證：每次注入後先用 `ntp_probe` 確認 offset 確實到位再開始計時 |
| 預期結果 | 先寫死：(a) 24h 內 `CephNTPNetworkDegraded` 因 rate==0 至少誤發一次（若 poll 已拉 >300s）；(b) 我們的規則不 fire（abs bug）且真實 skew 80ms — 注意 Ceph 這時**也可能不叫**（timecheck 是 peer-對-leader 減 latency，Monitor.cc:5163-5170；對稱 skew 是雙方共同盲區，實測記錄 Ceph 反應當對照）；(c) 不 fire（jitter gate）；(d) fire 但要等 poll 凍結窗；(e) 依 H-012 修正版：(1)↔(2) 不重置、(1)↔(3) 重置；(f) 6 個 metric `absent()` 全真、該 3 條件永不 fire |
| 回填表 | （scenario／預測 fire?／實測 fire?／延遲／verdict）|

### E-06 全 cluster 同步漂移

| 欄位 | 內容 |
|---|---|
| 目的 | 證明 H-015：共模漂移下三條 alert 全盲；為新規則的「絕對時間參考」條件取得需求證據 |
| 變因 | fake upstream 的回報時間偏移 |
| 調整的參數 | upstream 偏移 = 0（對照）/ +5min（全 cluster 跟上）|
| 做法 | L3：三 client 全指向 fake NTP server（既有 `--skew-ms` 參數即可，+5min = `--skew-ms 300000`，已有測試覆蓋），`PollIntervalMaxSec=256` 固定（讓 24×poll ≈ 1.7h，時間預算才收斂）→ 等全部收斂到錯誤時間 → 觀察全部 alert 24×poll 週期。回退：fake server 偏移歸零 + 等收斂（注意 +5min > 0.4s → timesyncd 會 step，可觀察）。Prometheus host 自己不指向 fake server（保持正確時間當外部參考）|
| 預期結果 | 先寫死：spread≈0、sync=1、daemon offset ≈0，且 **kernel timex 三訊號也全綠**（offset=PLL 殘餘量收斂、maxerror 正常重置、sync_status=1 — H-034，同步採樣驗證）→ 三條 alert 全綠。唯一看得到異常的是第四路：Prometheus 端 `node_time_seconds - timestamp(...)`（新規則候選訊號，驗證可行性、量測 scrape/RTT 偏差與雜訊水位，決定門檻）|
| 回填表 | （偏移／alert 反應／候選訊號讀值與雜訊）|

### E-07 端到端偵測延遲預算

| 欄位 | 內容 |
|---|---|
| 目的 | 量化「注入 → Alertmanager firing」全鏈路延遲的組成，決定新規則的 for/採集節奏，回答「第一時間」到底能多快 |
| 變因 | 鏈路節奏參數（一次動一個，其餘固定在基準組）|
| 調整的參數 | cron/timer 間隔 15s/60s × scrape interval 15s/30s × `for` 0/1m/3m（基準組 60s/15s/1m）。注入分兩種機制分開量（codex finding 16 / H-033）：(i) **持續 skew** = 先 iptables 斷 NTP 再 step +100ms（timesyncd 的 clock-change watcher 想 resync 也連不上 → skew 持續存在，這是主線）；(ii) **transient step** = NTP 連線下 step +100ms（watcher 立即 resync 自癒 — 量「短暫異常能不能被抓到」這個獨立問題）|
| 做法 | L3：每組合 × 每機制重複 3 次，記錄六個時間戳（注入、`.prom` 更新 mtime、Prometheus series 變化、ALERTS pending、Alertmanager firing、**receiver 收到通知**）。回退：解封 iptables + 還原注入前捕捉的 timex 狀態。生效驗證：注入後 `ntp_probe` 確認 offset 持續存在（機制 i）或已被修正（機制 ii）|
| 預期結果 | 先寫死延遲模型：`poll 快照延遲(0~poll) + cron(0~間隔) + scrape(0~間隔) + eval(0~間隔) + for + AM group_wait` — 實測值應落在模型區間；若超出 → 模型漏了環節（發現）。機制 (ii) 預測：自癒快於偵測鏈 → 現行規則全程無反應（快車道規則的需求證據）。產出：延遲預算表，標出瓶頸項（預測：poll 快照延遲是最大項 → 新 script 應併用 timex 誤差狀態訊號）|
| 回填表 | （組合／3 次實測 p50/p95／模型預測區間／verdict）|

### E-08 新版 script + rules 回歸

| 欄位 | 內容 |
|---|---|
| 目的 | 對根據 E-01～E-07 產出的新 script / 新 rules，重放全部注入，證明缺陷已修且無新 FP |
| 變因 | rule set 版本（舊 ↔ 新；注入序列固定）|
| 調整的參數 | 重放 E-05 (a)–(f)、E-06、E-07 基準組 |
| 做法 | 同 E-05/E-06/E-07 流程，producer ≠ verifier：新規則由本 session 寫、驗證由獨立 agent／codex 跑注入清單並填回填表。健康 soak（codex finding 18 強化）：新規則接**非 paging receiver** 跑數天（涵蓋 reboot、維護操作、poll 相位）斷言零 FP；同時測 Alertmanager inhibition — node down（`up==0`）時時鐘 alert 應被抑制不疊 page |
| 預期結果 | 先寫死：E-05 (b)(c)(f) 從「不 fire」翻成「fire」；(a) 的 FP 消失；E-06 由第四路獨立訊號接住；E-07 延遲（量到 receiver）≤ 設計目標（值待 E-07 後定）；多日 soak 零 FP、inhibition 正確 |
| 回填表 | （scenario／舊 verdict／新 verdict）|

### E-09 與 MON_CLOCK_SKEW 賽跑（L4，破壞性 → Gate 2 人工駕駛）

| 欄位 | 內容 |
|---|---|
| 目的 | 實地證明 H-020：node alert 領先 Ceph 自身偵測；並在真 cephadm 環境驗證 textfile 路徑與新 script 部署 |
| 變因 | 注入 skew 量 |
| 調整的參數 | 非 leader mon node 上 step +60ms / +100ms（皆 > 50ms 門檻；不動 leader、不接近 mon lease 秒級危險區）|
| 做法 | 預檢：`ceph -s` HEALTH_OK + quorum 3/3 + **注入前捕捉該 node 的 adjtimex 完整狀態存檔**。注入（codex finding 16：一次性 step 會被 timesyncd clock-change watcher 秒級自癒 — H-033）：先 iptables 斷該 node 的 udp/123、再 `clock_inject.py` step，讓 skew 持續存在 → 同時計時觀察：新 node alert firing 時刻 vs `ceph_health_detail{name="MON_CLOCK_SKEW"}`=1 時刻 vs `ceph health detail` 出現 MON_CLOCK_SKEW → 收集完整 → 回退：解封 iptables → timesyncd 自動 resync 收斂 → **還原捕捉的 timex 狀態**（不是硬編碼 reset）→ `ceph -s` 回 HEALTH_OK + `ceph crash ls` 無新 crash 才算收工。每步人工確認 |
| 預期結果 | 先寫死：node alert 在 ≤2min firing；MON_CLOCK_SKEW **常態** ~5min timecheck + mixin for 1m 才 firing（非硬上界 — timecheck round 可延至 3×interval，election 會立即觸發新 round，Monitor.cc:4826-4875）；領先幅度常態 ≥ 3min，記錄實際分布。若 Ceph 更快 → H-020 violated（重大發現，回頭查 timecheck 觸發條件）|
| 回填表 | （skew／node alert 時刻／MON_CLOCK_SKEW 時刻／領先幅度／回退後 HEALTH_OK 確認）|

### E-10 觀測鏈自身失效（L4）

| 欄位 | 內容 |
|---|---|
| 目的 | 證明 H-030/H-031/H-004：現行規則對「監控自己死了」全盲；驗證新 meta-alert（mtime 過期、scrape_error、absent）接得住 |
| 變因 | 殺掉的環節 |
| 調整的參數 | 停 script timer / 停 node-exporter container / 寫入壞格式 `.prom`（三 scenario）|
| 做法 | 每 scenario：注入 → 等 2× 預期偵測窗 → 記錄新舊規則各自反應 → 回退（重啟 timer/container、覆寫好檔）。cephadm 的 node-exporter 是 managed daemon，停用用 `ceph orch daemon stop`，回復用 `ceph orch daemon start` |
| 預期結果 | 先寫死：舊規則三 scenario 全綠（盲）；新規則分別由 mtime 過期 alert / `up==0`（既有基礎設施 alert，E-00 確認存在與否）/ `node_textfile_scrape_error==1` alert 接住 |
| 回填表 | （scenario／舊規則反應／新規則反應／偵測延遲）|

### E-11 mgr 凍結時 node 層存活（L4，高破壞性，optional → Gate 1 決定）

| 欄位 | 內容 |
|---|---|
| 目的 | 實地重證 H-021：mon quorum 掉時 ceph_health_detail 凍結，node 層時鐘監控仍活著 |
| 變因 | mon quorum 狀態 |
| 調整的參數 | 停 2/3 mon（沿用 mon-quorum-blind-spot SP 的既定流程與回退）+ 同時在存活 node 注入 skew |
| 做法 | 完全依 mon-quorum SP 的人工駕駛程序；skew 注入與觀察同 E-09。既有 SP 已證 mgr 凍結行為，本實驗只驗「node 層訊號不受影響」一點 |
| 預期結果 | 先寫死：quorum 掉後 `ceph_health_detail` 凍結（已知）；node 層 `node_ntp_*` / `node_timex_*` / 新 alert 全程正常運作 |
| 回填表 | （quorum 狀態／ceph 端訊號／node 端訊號／verdict）|

## 4.5 已備妥的資產（機器前工作，2026-07-23 完成）

| 資產 | 路徑 | 狀態 |
|---|---|---|
| baseline script/rules 存檔 | `current/` | 勿改（E-05 對照組）|
| E-05a promtool 判決（舊規則）| `tests/promtool/current-rules.test.yml` | 11 test 全 confirmed |
| E-01 L1 parser 判決（舊 script）| `tests/parser/run-parser-tests.sh` | 11 判決全 confirmed |
| **v2 採集 script** | `v2/collect_time_sync.sh` + timer units | L1 測試 28/28 綠；含 heartbeat、age 防時鐘倒退、chmod-先-發布、零值 parse（codex r2 修正）|
| **v2 alert 規則（16 條）** | `v2/ceph-time-sync-alerts.yml` | promtool 14 組全綠（含健康基線零 FP、spike 免疫斷言）；`[draft-EXX]` 門檻待實驗定案 |
| v2 規則測試產生器 | `tests/promtool/gen-v2-rules-test.py` | 改情境改這支再重產，勿手改 test.yml |
| Alertmanager inhibition 草稿 | `v2/alertmanager-inhibition.yml` | 防單一事故 4+ page fanout；E-08 receiver 級驗證 |
| E-00 盤點腳本（唯讀意圖）| `run/e00-inventory.sh` | codex r2 硬化版（有界執行、三態錯誤標記、有效設定、監控堆疊探查）；備妥未執行 |
| 回退 harness | `experiments/timesyncd/lib/clock_inject.py` `capture`/`restore` | TDD 完成 |

v2 規則的 `job="ceph-node"` scope 與 `[draft-EXX]` 門檻（timex 0.05 / stalled 768/1800 /
drift 1s/10s / poll<64 / maxerror 1s）都等 E-00/E-03/E-06/E-07 實測後定案 — 現在的值
是依 source 常數與生產參數（PollIntervalMaxSec=256）推的設計起點。

## 4.6 上機首小時檢核（E-00 之後、部署任何東西之前 — codex r2 findings 14/15）

L1 的綠燈是 fake timedatectl + 合成 series 給的；首小時要打掉的是「L1 驗不到的真實世界」：

1. **node-exporter argv**（H-037）：確認 textfile 目錄與 timex collector 的實際狀態；
   若 timex 被停用（cephadm 預設），timex 兩車道無資料 — 先決定補設定或標記車道不可用。
2. **collector 端到端**：部署 v2 script（單台）→ 確認每個 metric 出現在 `/metrics`；
   對照兩個真實 poll 週期的 `LC_ALL=C timedatectl timesync-status` 原文 vs emit 值。
3. **restart timesyncd**：觀察未同步窗口的輸出（H-007：Offset 行缺失 → collector_error
   短暫 =1，`CollectorError` 的 for:10m 應該擋住不誤發）。
4. **timer 停擺演練**（H-030 真實機制）：停 timer > 5 分鐘 → 確認 series 仍在、值凍結、
   `CephNodeTimeSyncDataStale` 真的 fire；恢復 timer → resolve。
5. **Drift 車道雜訊水位**（E-06 前置）：連續記錄
   `node_time_seconds - timestamp(node_time_seconds)` 的 min/max/p99 與 scrape duration —
   決定 1s 門檻是否成立；同時確認 Prometheus 自身的時間來源（若與節點同 NTP 上游，
   共模車道形同虛設 — 架構層面要另找異質參考）。
6. **Alertmanager 路由**：inhibition/grouping 套用後，注入一次 150ms outlier，
   數 receiver 實際收到幾則通知（目標：1 則，不是 4+）。

## 5. 安全邊界與回退（全實驗共用）

- 時鐘注入一律用 `clock_inject.py`；**注入前先捕捉 adjtimex 完整狀態存檔，回退 =
  還原捕捉值**（codex finding 17：`clock_inject.py reset` 硬編碼 tick=10000/freq=0，
  不是還原 — 需先擴充 harness 支援 capture/restore）→ restart NTP daemon → 確認收斂
- **PVE snapshot 回滾僅限 L2/L3 的獨立實驗 VM**；L4 的 mon node **禁止** snapshot
  回滾 — 把單一 mon 的持久狀態回捲到其他 mon 之前不是安全的分散式系統復原
  （codex finding 17）。mon 出問題的正規復原路徑：daemon restart → 必要時
  依 Ceph 文件重建該 mon
- iptables 只動 OUTPUT + udp/123 DROP 一條，永不碰 INPUT/TCP；解封指令寫死在 scenario 內
- L4 預檢一律 `ceph -s` HEALTH_OK + quorum 完整才准注入；mon 相關操作用
  `ceph mon ok-to-stop <id>`（不是 osd ok-to-stop）；收尾必須回 HEALTH_OK 才進下一步
- 所有長任務跑 transient unit（`tsexp-*` 慣例），SSH 斷線不中斷；證據 bundle 先落盤再 cleanup
- 破壞性實驗（E-09/E-11）人工駕駛，不丟背景 subagent

## 6. 時間預算

| 階段 | wall-clock |
|---|---|
| E-05a promtool 測試（**機器到位前**，含 harness capture/restore 擴充）| ~1 天（純本機）|
| E-00 + E-01 + E-02 | ~0.5 天 |
| E-03（3 cells × 暖機+30min 斷線）| ~1 天（poll=2048 cell 暖機久）|
| E-04 | ~2h |
| E-05（live 子集，promtool 已涵蓋的不重跑；含 24h 健康觀察）| ~1 天 |
| E-06（poll=256 固定 → 24×poll ≈ 1.7h + 收斂緩衝）| ~4h |
| E-07（延遲矩陣 3 參數 × 2 注入機制 × 3 重複）| ~1.5 天 |
| 新 script/rules 設計 + E-08 回歸（多日非 paging soak 與其他實驗並行）| ~2 天 + soak 3–5 天（背景）|
| E-09 + E-10（人工駕駛窗口）| ~0.5 天 |
| E-11（optional）| ~0.5 天 |

## 7. 新 script / rules 的設計方向（實驗後定案，先立靶）

四層防禦（codex review 後修正：timex 不是絕對時間真值，共模防禦需要獨立第四路）：

| 層 | 訊號 | 更新頻率 | 捕捉的失效 | 不能捕捉 |
|---|---|---|---|---|
| kernel 誤差狀態（node_exporter 內建 timex，零新增成本）| `node_timex_offset_seconds`（**PLL 剩餘修正量**，非絕對誤差）/ `maxerror_seconds`（誤差上界，斷線後 500µs/s 累加）/ `sync_status` | 每次 scrape、kernel 持續更新 | 修正中/未收斂（offset 大）、失聯持續（maxerror 爬升）| 共模錯誤時間（收斂後全部顯示健康 — H-034）；快速失聯（sync 翻轉要 ~8.9h）|
| NTP daemon 狀態（新 script）| offset / root distance / last-sync-age / packet count / poll interval / server 身分；timesyncd 為主 backend（生產已確認），chrony 接管時 fail-loud（`collector_error` 置位）；恆輸出全部 metric + heartbeat + `collector_error` | timer 15–60s | daemon 視角上游品質、poll 快照、上游失聯（last-sync-age）| poll 間隙的即時漂移；共模 |
| 獨立絕對時間參考（第四路，E-06 驗證可行性）| Prometheus 端 `node_time_seconds - timestamp(...)`（不同信任域的時鐘比對）；Prometheus host 自身對異質 NTP source 同步且被監控 | 每次 scrape | **共模漂移**（唯一能抓 H-015 的路）| 亞秒級精度（受 scrape/RTT 偏差限制，門檻由 E-06 量測定）|
| Ceph health（既有 `CephMonClockSkew` 保留）| `ceph_health_detail{name="MON_CLOCK_SKEW"}` | mon timecheck 常態 5min | 最終後果確認（慢但權威）| 對稱 skew（peer-對-leader 減 latency 的盲區）；mon quorum 掉時 mgr 凍結（H-021）|
| meta（觀測鏈自保）| `node_textfile_scrape_error`（target 級，降級處理）+ 我方 heartbeat absent（歸因）、mtime 過期、per-node missing-series（inventory join）、`up` | 每次 eval | 監控自己死了 | — |

規則修正原則（對應 review + codex findings）：
- 拆掉 `or on()` 混合條件、每條件獨立 alert 保留 instance label；spread 改 `max(o)-min(o)`；
  絕對 offset 獨立成條件（不 and jitter）；刪除 poll≥128 反向條件；
  packet rate 窗口與 for 跟 `PollIntervalMaxSec=256`（生產已確認將採用）綁定設計 —
  256 下 rate[5m]==0 健康態不誤發（T4b 證實）、但偵測失聯要 ~600s gap，只當粗粒度後備；
  快速失聯偵測主力 = last-sync-age（門檻 ~3×256s=768s 起跳，實際值由 E-03 實測定）
- **雙車道**（codex finding 19）：快車道 = 高幅度高信度條件即時 fire + `keep_firing_for`
  （接住 timesyncd 快速自癒的 transient step — 修好了不代表沒發生過）；
  慢車道 = 低門檻 + 持續性（`for`）；observer 失效獨立為 warning 車道；
  三車道用 Alertmanager inhibition/grouping 整流（`up==0` 抑制時鐘 alert），不各自為政
- **Scope**（codex finding 10）：所有 selector 帶 cluster/job label；期望節點清單 join 產生
  per-node missing-series alert，不用全域 `absent()`
- 門檻對齊 Ceph 失效模式（50ms=mon WARN 前哨 → warning；接近/超過 mon 危險區與絕對大
  offset → critical）；severity 與 for 由 E-07 延遲預算表定案
- annotation 誠實原則（codex finding 14）：區分「觀測到的事實／可能的後果／已證實的影響」，
  不寫 source 撐不起的因果（如 object version conflicts）；timezone/RTC 不一致降為
  non-paging 的組態 hygiene 檢查（不影響 Unix time，主要是 boot/recovery 與 log 可讀性問題）
