# ceph-time-sync-alerts — 實機證據日誌（Azure lab, 2026-07-23 起）

主機一律用 hostname（public IP 見 azure-iac-lab/ACCESS.md，不進版控）。
UTC 時間戳。詳細 bundle 在 results/（gitignored）；本檔是可追溯的摘要索引。

## 環境（E-00, 05:1x UTC）
- 9 台全同質：systemd 249.11 / kernel 6.8.0-1062-azure / chrony→PHC0(hyperv) 共模
- cephadm 19.2.5 無監控堆疊 → 已佈：node-exporter×6（textfile ✓、timex 不可啟用=H-037）、
  Prometheus+Alertmanager @ osd-2（scrape/eval 10s、job=node、external cluster label）
- 信任域切分：mon×3 + osd-0/1 + k8s-1 → timesyncd→k8s-0(10.0.1.5)、poll 256；
  osd-2 + k8s-0 + k8s-2 保持 chrony→PHC

## 首小時檢核（05:3x–05:4x UTC）
- v2 collector 端到端：systemd 249 真實輸出全欄位正確（含 `2min 8s` 多單位、`Jitter: 0` 裸零）
- H-037 判決：`--collector.timex` → kingpin `cannot be repeated` → 6 台 node-exporter 全滅
  → 修 spec 只留 textfile；EMIT_TIMEX adjtimex fallback 上線，6 台 timex 齊
- H-002/H-007 live confirmed（osd-2 fail-loud；k8s-1 never-synced 無 Offset 行）
- Timer 停擺演練（osd-1, 05:40:59Z–05:47Z）：series 全程存活、值凍結、heartbeat 洩底；
  恢復 1 個 timer 週期內 — H-030 修正版機制 confirmed
- Drift 雜訊水位：6 台 +2.5~+5.0ms（scrape max 0.156s）→ 1s 門檻 200x 裕度

## E-05(a) 健康態 baseline 規則行為（05:40 起持續觀測）
- 載入後 60s 內健康 5 台全 pending `CephNTPNetworkDegraded`（poll=256≥128 反向條件）
- **活體新現象**：pending 集合震盪（5 台 ↔ 1 台）— rate==0 分支偶發非空時 `or on()`
  把 poll 分支整個丟棄 → 其他節點 for 重置 → 健康叢集上 warning 永遠 pending/偶發 firing、
  行為不確定（H-012×H-013×H-014 交互，比 promtool 合成情境更嚴重）

## E-05(d) 上游失聯注入（osd-0）
- inject: `iptables -A OUTPUT -p udp --dport 123 -j DROP`（時刻見下）
- prediction: age 線性爬升；rate[5m]==0 於 ~5min 後對 osd-0 恆真；baseline Degraded
  可能因 or-on() 壓制其他節點；daemon offset 凍結；NTPSynchronized 維持 yes（H-023）
- rollback: `iptables -D OUTPUT -p udp --dport 123 -j DROP` + 確認 packet count 恢復增長
- inject 05:47:13Z / rollback 06:15:23Z（iptables 確認乾淨；packet 恢復待下個 poll ≤256s）
- 實測曲線（obs1–13，每 2min）：
  - age 線性 90→1535s（v2 Stalled 768s 會在 +12min 落點、Critical 1800s 在 +30min）
  - rate[5m]==0 自 +5min 起恆真（baseline Degraded 對 osd-0 firing）
  - `NTPSynchronized` 全程 =1 — **25 分鐘失聯完全不可見**（H-023 live）
  - daemon offset 凍結在 +26µs 全程不動（H-005 live）
  - `node_timex_maxerror` 線性 0.0465→0.769（斜率 496µs/s ≈ kernel 理論 500µs/s，H-022 live）
- **or-on() 災難實錄（H-012/H-013 追加證據）**：05:50 健康 4 台（mon×3+osd-1）達 firing
  （poll≥128 永久 FP 完全體）；05:52 osd-0 的 rate==0 分支非空 → `or on()` 丟棄 poll 分支
  → **4 個 firing alert 瞬間 auto-resolve**，僅剩 osd-0 — 生產上 = 4 個 page + 4 個假 resolve，
  而那些節點狀態零變化。alert 身分/條件互踩在真 Prometheus 的破壞力比 promtool 合成情境更大
