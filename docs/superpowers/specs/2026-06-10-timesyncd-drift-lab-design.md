# systemd-timesyncd 時鐘漂移恢復實驗（Drift Lab）— Design Spec

> Status: approved (brainstorming 階段確認)
> Date: 2026-06-10
> Scope: 在既有 `systemd` project 下新增兩頁專題文章（實驗方法論、實驗設計與結果），加上 repo root 的 `experiments/timesyncd/` agent 執行包（README + 全自動 scripts）。
> 前置依賴：systemd submodule（v260.1，既有 8 篇 timesyncd 文章的 source 基準）、linux submodule（kernel PLL / adjtimex 行為的 source 依據）。
> 執行環境：Proxmox VE 上兩台 VM（client = Ubuntu 22.04 / systemd-timesyncd 受測，server = Ubuntu 24.04 / chrony），只透過 SSH 操作，碰不到 hypervisor。

## 目標

回答四個問題，全部以可重現實驗驗證，並與 source 推導的預測對照：

1. **失聯恢復**：與 NTP server 失聯 1hr / 4hr / 24hr，時鐘頻率誤差 0 / ±10 / ±100 / ±1000 ppm 的組合下，恢復連線後多久誤差降到 50ms 以下？另加 ±400 / ±500 ppm × 1hr 邊界探針，定位 kernel 頻率補償極限（`MAXFREQ` ±500ppm）內/壓線/超出的三種行為。
2. **滑動修正速度**：399ms 偏移（刻意卡在 0.4s 跳錶門檻下）kernel 需要多久滑回 50ms 內？
3. **重啟對時行為**：systemd-timesyncd 重啟後是否馬上對時？偏移 10 / 50 / 100 / 500ms 時，修正到 50ms 內各需多久？
4. **低 max poll 穩定度**：`PollIntervalMaxSec=256`（秒）在生產級判準下（連 2 個 ping 封包都不能掉、ceph 生產關鍵系統、5 秒 downtime 都不可接受）會不會造成任何不穩定？

## 核心設計決策（brainstorming 確認）

### 1. 失聯階段用「數學折疊」，不做時間加速

既有文章 `timesyncd-outage-and-maintenance` 已從 source 證明：**沒有有效 NTP reply 時 timesyncd 完全不碰系統時鐘**（free-run）。所以失聯階段是確定性的：

```
累積 offset = 失聯時長 T × 頻率誤差 F
```

失聯 T 小時 × F ppm 直接折疊成兩個初始條件一次注入：(a) 累積 offset、(b) 殘留頻率誤差（晶振還在漂）。實驗只跑恢復階段（真實時間，受 kernel slew 上限約束本來就無法加速，最長 cell 約十幾分鐘）。比 10x/100x 時間加速**更準**（不是近似）且**更快**（失聯階段 0 秒）。

### 2. 誤差注入對應正確的 kernel 暫存器

| 模擬目標 | 機制 | 理由 |
|---|---|---|
| 失聯累積 offset | `clock_adjtime(ADJ_SETOFFSET)` | 原子注入、不停錶，比 `clock_settime` 無 race |
| ±100 / ±1000 ppm | `ADJ_TICK`（tick = 10000 ± 1 / ± 10 µs） | tick 是 timesyncd 與 kernel PLL **都不會改寫**的暫存器，注入後如真實晶振誤差持續存在，NTP 必須真的學會補償，保真度最高 |
| ±10 ppm | `ADJ_FREQUENCY` | tick 粒度只有 100ppm（1µs/10000µs）；freq register 會被 PLL 逐步改寫，但動力學等價：PLL 看到的「有效速率誤差」軌跡與真實晶振誤差相同（真實：晶振 +10ppm、register 0→-10ppm；模擬：晶振 0、register +10ppm→0） |

### 3. 量測獨立於受測物

不採信 timesyncd 自己回報的 offset。client 上跑 `ntp_probe.py`：raw socket 直接對 server 做 SNTP query（1Hz），記錄 `offset_ms, delay_ms` 到 CSV。LAN RTT sub-ms，對 50ms 判準綽綽有餘。

### 4. 校準扣除天然漂移

實驗前 `calibrate.sh`：停 timesyncd、歸零 freq/tick、用 probe 量 30–60 分鐘天然基線 ppm 存檔；`analyze.py` 從所有結果扣除。這讓 client/server 跑在不同實體機（兩顆晶振天然相對漂移 ±幾 ppm）時，±10ppm cell 也不被污染。

實體機配置建議（不強制，scripts 相同）：實驗 1–3 同實體機兩 VM 更乾淨（同一顆振盪器、天然相對漂移 ≈ 0）；實驗 4 分開實體機更好（真實網路路徑、避免 noisy-neighbor 假陽性）。只用一種配置就選分開實體機 + 校準。

### 5. Source 錨定：kernel 三種修正機制、三個不同上限

「kernel slew 上限 500ppm」是 lore，source 驗證後實況是三種機制各有上限（實驗預測的基礎、方法論文章的核心一節）：

| 機制 | 上限 | Source | timesyncd 用嗎 |
|---|---|---|---|
| PLL 相位滑動（`ADJ_OFFSET`+`STA_PLL`） | **無 ppm 形式上限**：每秒修掉剩餘 offset 的 `1/2^(SHIFT_PLL+tc)`；offset 進場 clamp ±500ms（`MAXPHASE`）→ 有效上限 ~62,500ppm，指數衰減（32s poll 時 tc=1、τ≈7.5s） | `linux/kernel/time/ntp.c:130`（`ntp_offset_chunk`）、`:315`（MAXPHASE clamp）、`linux/include/linux/timex.h:120`（`SHIFT_PLL=2`）、`:135`（`MAXPHASE`） | ✅ 修 <0.4s 偏移的路徑 |
| 頻率補償（`time_freq` register） | **±500ppm 硬 clamp**（`MAXFREQ`）——可補償晶振誤差的極限 | `linux/include/linux/timex.h:136`、`ntp_update_offset` 結尾 `min/max(…, ±MAXFREQ_SCALED)` | ✅ 補償持續性晶振誤差 |
| 古典 `adjtime()` singleshot（`ADJ_OFFSET_SINGLESHOT`） | 固定 500µs/s = **恰好 500ppm**（`MAX_TICKADJ`；500ppm lore 的出處） | `linux/kernel/time/ntp.c:43`、`second_overflow` 的 `time_adjust` 消耗 | ❌ 不走這條 |

timesyncd 端與 tick 的常數：

| 常數 | 值 | 位置 |
|---|---|---|
| timesyncd 跳/滑門檻 `NTP_MAX_ADJUST` | 0.4 s | `systemd/src/timesync/timesyncd-manager.c:52`（`:247` 判斷 `fabs(offset) < NTP_MAX_ADJUST` → slew，否則 step） |
| tick 範圍與粒度 | 9000–11000 µs（±10%），粒度 100ppm | `linux/kernel/time/timekeeping.c:2360`（`900000/USER_HZ` ～ `1100000/USER_HZ`） |

### 6. Proxmox VE + SSH-only 約束

- **長時實驗 SSH 斷線存活**：run scripts 支援 detached 模式（`systemd-run --unit=tsexp-<name>` transient unit），進度落 `results/state.json` + log，`--status` 查進度；`all.sh` 斷點續跑建立其上。
- **iptables 防鎖死**：只動 `udp dport 123` 的 OUTPUT 規則，永不碰 INPUT、永不碰 TCP。hardcode 在 lib，preflight 驗證規則內容。時鐘跳變不影響既有 SSH 連線。
- **PVE 干擾源**：vzdump 備份 / snapshot / live migration 會凍結或跳動 guest 時鐘 → README 要求實驗窗口停用；qemu-guest-agent 的 `guest-set-time` 會污染注入誤差 → preflight 偵測並警告；preflight 記錄 clocksource（預期 `kvm-clock`）進 results。
- **依賴最小化**：Python 全 stdlib 零第三方；setup 用 apt 裝 chrony（server）與工具（client），VM 需可連 apt repo（README 前提）。

## 實驗矩陣

### 實驗 1：失聯恢復（25 cells）

主矩陣 3 時長 × 7 頻率誤差（0、±10、±100、±1000 ppm）= 21 cells，**加 `MAXFREQ` 邊界探針 ±400、±500 ppm × 1hr = 4 cells**（邊界行為由殘留 ppm 決定、與失聯時長無關，故只跑一種時長；±1000 × 三時長保留作冗餘交叉驗證）。折疊後初始 offset：

| | 0ppm | ±10ppm | ±100ppm | ±400ppm | ±500ppm | ±1000ppm |
|---|---|---|---|---|---|---|
| 1hr | 0（對照） | ±36ms | ±360ms | ±1.44s | ±1.8s | ±3.6s |
| 4hr | 0 | ±144ms | ±1.44s | — | — | ±14.4s |
| 24hr | 0 | ±864ms | ±8.64s | — | — | ±86.4s |

Source 推導預測（文章先寫預測、結果跑完回填）：

- `|offset| < 50ms`（1hr×10ppm）：立即合格，收斂 ≈ 0
- 50–400ms：PLL 相位滑動（τ≈7.5s）→ **十幾秒內收斂**（slew 無 500ppm 限制，見決策 5；360ms ≈ 15s、144ms ≈ 8s）
- `> 400ms`：timesyncd 首個 sample 直接跳錶，秒級
- ±400ppm：可鎖定，freq register 仍有 100ppm headroom
- ±500ppm：**脆弱鎖定**——freq register 頂死 clamp，任何天然漂移（±幾 ppm）即破界，可能間歇性失準
- ±1000ppm：超過 `MAXFREQ`，預測**永不穩定收斂**（淨漂移 ≥500ppm；poll 短時 offset 徘徊在十幾 ms、poll 拉長後跨 poll 漂移 > 0.4s 反覆跳錶）。timeout 30 分鐘記 non-convergent——本身是 finding（生產晶振故障/VM 計時異常的 signature）。

### 實驗 2：399ms 滑動修正（2 cells）

399ms（門檻下 1ms → 純 PLL 相位滑動，預測 `ln(399/50) × 7.5s ≈ 16s` + 首個 sample 延遲）+ **401ms 對照**（門檻上 1ms → 跳錶，秒級）。對照重點不是快慢（兩者都是秒級），而是**平滑滑動 vs 不連續跳變**——step detector 把 0.4s 懸崖的本質差異打在圖上。

### 實驗 3：重啟對時（4 cells）

收斂狀態注入 offset {10, 50, 100, 500ms} → `systemctl restart systemd-timesyncd` → 量測 (a) restart 到第一次 clock 調整的延遲（journal + probe 交叉，回答「是否馬上對時」）、(b) 到 <50ms 時間。預測：10ms 無感、50ms 邊界、100ms slew 約 5–10s、500ms 跳錶秒級。

### 實驗 4：`PollIntervalMaxSec=256` 穩定度（6 情境）

| 情境 | 內容 | 判準 |
|---|---|---|
| `baseline-2048` | 預設設定 soak N 小時（預設 4h，正式建議 24h） | 對照基線 |
| `soak-256` | 256s 設定 soak 同時長 | 與基線逐項比 |
| `restart` | soak 中 restart timesyncd | 不准出現 step |
| `outage-30m` | NTP 失聯 30 分鐘後恢復 | 恢復無 step、offset 平滑 |
| `inject-80ms` | 穩態注入 80ms 偏移 | 256s vs 2048s 偵測延遲對比（低 max poll 的實際效益） |
| `jitter` | `tc netem` 5ms±3ms 延遲 1 小時 | PLL constant 降低後是否失穩（驗證 `timesyncd-low-max-poll-simulation` 的推論） |

全程持續監測（每情境同時跑）：

- 100Hz ping（`ping -i 0.01`）→ 判準 **0 丟包**
- step detector：`CLOCK_REALTIME` vs `CLOCK_MONOTONIC_RAW` 差值跳變 > 1ms 即記錄 → 判準：除預期跳錶外為 0，且永不倒退
- 5 秒 deadline 哨兵（模擬 ceph mon lease watchdog）→ 判準 0 miss
- timesyncd CPU / 記憶體（cgroup）、udp/123 封包計數（nft counter）、journal error 掃描
- 產出 PASS/FAIL verdict 表

### 收斂判定（全實驗統一）

`|offset| < 50ms` 持續 60 秒，取首次進入該狀態的時刻。

### 每 cell 標準生命週期

```
preflight → 狀態重置（停 timesyncd、歸零暫存器、硬步進回真時、|offset|<1ms 確認；原 5ms 在 L3 實測證實太鬆——殘留 4.2ms 會把 399ms cell 推過 0.4s 門檻變 step）
→ 注入初始條件 → 啟動 probe → 解封 NTP / 啟動 timesyncd → 等收斂或 timeout
→ 收斂判定 → 寫結果 → 清理（trap 保證失敗也復原）
```

預估 wall-clock：校準 ~1h、實驗 1 約 5–6h（±1000 的 6 cells 各吃滿 30min timeout，其餘多在分鐘級）、實驗 2 ~0.5h、實驗 3 ~1h、實驗 4 預設 ~10h（quick 4h）。全程可無人值守。

## 產出物

### 網站文章（`next-site/content/systemd/features/`，zh-TW 台灣用語）

**頁 A `timesyncd-drift-lab-methodology` — 實驗方法論**

- 四個問題為什麼不能等真實時間測
- 數學折疊正當性（free-run 確定性，引 `timesyncd-outage-and-maintenance` + source）
- adjtimex 三暫存器解剖（offset / freq / tick）：誰會被 PLL 改寫、誰不會，對齊 `linux/kernel/time/` source
- kernel 三種修正機制與三個上限（PLL 相位滑動無 ppm 上限 / `MAXFREQ` ±500ppm 頻率補償 / 古典 `adjtime()` 固定 500ppm）——釐清「kernel slew 只有 500ppm」的 lore 出處，關鍵常數 source 位置（上表）
- 量測架構：probe 獨立性、校準、收斂判定
- 單 kernel 驗證 trick：`CLOCK_MONOTONIC_RAW` 不受 adjtimex 影響 → fake NTP server 當獨立基準

**頁 B `timesyncd-drift-lab-experiments` — 實驗設計與結果**

- 四組實驗完整步驟（與 scripts 一一對應：執行哪個 script、預期跑多久）
- 每組附 source 推導預測表；結果欄留空、標「在你環境跑後對照」（符合 CLAUDE.md lab 驗證等級）
- 跑完回填實測，預測 vs 實測對照是文章核心價值

互鏈：`timesyncd-outage-and-maintenance`（free-run 證明）、`timesyncd-low-max-poll-simulation`（256s 理論推演）、`timesyncd-restart-impact`（重啟路徑）。

### 整合

- `projects.ts` systemd 條目：`features` 加 2 slug；featureGroups「時間同步 (timesyncd)」加同 2 slug；learningPaths 的 intermediate 與 advanced 各加一筆（閱讀順序：methodology → experiments）
- `next-site/content/systemd/quiz.json` 各加 3–5 題
- 圖一律靜態 PNG 進 `next-site/public/diagrams/systemd/`（不用 Mermaid）

### Agent 執行包（repo root，網站存取不到）

```
experiments/timesyncd/
  README.md               ← agent 執行計畫：前提、ssh/scp 部署、執行順序、
                             每步預期輸出與 PASS 判準、故障排除（zh-TW 敘述 + 英文指令）
  env.example.sh          ← SERVER_IP 等變數（複製成 env.sh 填值）
  lib/
    common.sh             ← preflight、狀態重置、cleanup trap、log、detach 輔助
    ntp_probe.py          ← 1Hz SNTP probe → CSV（raw socket、stdlib only）
    clock_inject.py       ← ctypes 呼叫 clock_adjtime：SETOFFSET / TICK / FREQUENCY
    step_detector.py      ← REALTIME vs MONOTONIC_RAW 跳變監視
    fake_ntp_server.py    ← L3 驗證用（MONOTONIC_RAW 基準假 server）
    analyze.py            ← CSV → 收斂時間 / 統計 / PASS-FAIL verdict（md+json）
  setup/
    setup-server.sh       ← 24.04：chrony 設成 LAN server（一次性）
    setup-client.sh       ← 22.04：timesyncd 指向 server、deps、安全網檢查
    calibrate.sh          ← 基線漂移校準（預設 30min，--minutes 可調）
  run/
    exp1-drift-recovery.sh   ← --duration-h X --ppm Y 單 cell；--all 21 cells
    exp2-slew-399ms.sh       ← 含 401ms 對照
    exp3-restart-sync.sh     ← --offset-ms N；--all
    exp4-poll256-soak.sh     ← --scenario <名稱> --hours N；--all
    all.sh                   ← 全套無人值守（校準→1→2→3→4），斷點續跑
  results/                ← CSV + summary，commit 進 repo（文章回填依據）
```

執行模型：scripts 在 VM 上就地執行（scp 部署），每實驗一條指令，內建 preflight / cleanup / timeout / 結果落檔；長時實驗用 systemd-run detached + `--status` 輪詢。

## 交付前驗證（L1–L4）

| 層級 | 內容 | 環境 |
|---|---|---|
| L1 靜態 | `bash -n` + shellcheck 全部 shell；`python3 -m py_compile` 全部 py | 本機 Mac |
| L2 單元 | `analyze.py` 餵合成 CSV 驗證收斂判定/校準扣除；`clock_inject.py` struct 編排 dry-run | 本機 Mac |
| L3 端到端 | **PVE 上的 client VM（22.04）單機 rig**：`fake_ntp_server.py`（MONOTONIC_RAW 基準）跑 localhost、timesyncd `NTP=127.0.0.1`，完整跑通 exp1 一 cell、exp2、exp3 一 cell、exp4 縮時情境 | PVE client VM |
| L4 真實 | 全套 4 實驗 | PVE 兩台 VM |

L3 用真實 client VM（而非本機 OrbStack）：同 kernel、同 systemd 版本、同 PVE 環境，連 preflight 的 PVE 檢查都能驗證；Mac 零負載。**不需額外 VM**——單 kernel rig 設計上單機自足。建議使用者在交付 VM 前先拍 PVE snapshot（hypervisor 權限在使用者手上）。Server VM 等 L3 過了再開即可。

L3 驗不到、留給 L4：真實網路延遲、真 chrony、長時 soak、PVE 排程備份干擾——README 明文標注。

## 工作流程備註

- 接續動作：`superpowers:writing-plans` 產 implementation plan → 實作
- Commit / push 用 repo 慣例：`git commit --no-gpg-sign`、`GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 ...' git push`，前置 `make validate` exit 0
- 結果回填屬後續 session：使用者跑完 L4（或由 agent 跑），results/ 進 repo 後再回填頁 B
