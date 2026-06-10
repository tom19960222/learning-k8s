# timesyncd Drift Lab — 執行計畫

這份是「給未來 agent / 使用者照著跑」的執行計畫書，**不在網站路由內**（位於 `next-site/content` 之外）。zh-TW 敘述，指令一律英文照抄。

整套實驗環繞四個問題設計，每個對應一支 `run/exp*.sh`：

1. **失聯恢復**（exp1）：NTP 失聯一段時間、client 又有頻率誤差（ppm）時，timesyncd 恢復連線後多久收斂？什麼條件下根本收不回來？
2. **399ms slew vs 401ms step**（exp2）：在 `NTP_MAX_ADJUST`（0.4s）門檻兩側各差 1ms，timesyncd 是平滑 slew 還是硬 step？兩種行為的 signature 長怎樣？
3. **重啟對時**（exp3）：`systemctl restart systemd-timesyncd` 之後，daemon 是不是馬上去對時？各種 offset 下修正要多久？
4. **PollIntervalMaxSec=256 穩定度**（exp4）：把 max poll 從預設 2048 拉到生產級的 256，長時 soak 下穩定度、資源占用、抗擾動能力如何？

設計理由、數學折疊推導與各 cell 矩陣的完整說明見 spec：
`docs/superpowers/specs/2026-06-10-timesyncd-drift-lab-design.md`

對應的兩篇網站文章（讀者向，分別講方法論與實驗結果）：
- `next-site/content/systemd/features/timesyncd-drift-lab-methodology.mdx`（頁 A：實驗方法論）
- `next-site/content/systemd/features/timesyncd-drift-lab-experiments.mdx`（頁 B：實驗結果，含「在你環境跑後對照」欄位）

## 0. 前提

- client VM：Ubuntu 22.04（systemd-timesyncd 受測）；server VM：Ubuntu 24.04（chrony）
- 皆可連 apt repo；皆可被你 SSH（root 或可 sudo -i）
- 兩台互通 udp/123 與 icmp
- 實體機配置（建議，不強制；scripts 相同）：實驗 1–3 兩 VM 同實體機更乾淨（同一顆振盪器、
  天然相對漂移 ≈ 0）；實驗 4 分開實體機更好（真實網路路徑、避免 noisy-neighbor 假陽性）。
  只想用一種配置就選分開實體機 + 校準（calibrate.sh 會把天然漂移變成已知量）
- **PVE 注意事項（重要）**：
  - 實驗窗口內停用該 VM 的 vzdump 備份、snapshot、live migration——三者都會凍結/跳動 guest 時鐘，直接汙染資料
  - 建議實驗窗口內 `systemctl stop qemu-guest-agent`（PVE 的 guest-set-time 會改 guest 時鐘）；preflight 會偵測並警告
  - 開跑前先拍 PVE snapshot（hypervisor 權限在你手上；時鐘玩壞了可以整台回滾）
- 實驗會大幅撥動 client 的 CLOCK_REALTIME（最大 ±86.4s）：**client VM 必須是乾淨實驗機**，
  不要掛任何在意時間的 workload（資料庫、cron 任務、TLS 服務）

## 1. 部署

```bash
# 在你的工作機
scp -r experiments/timesyncd root@<CLIENT_IP>:/root/
ssh root@<CLIENT_IP> 'cd /root/timesyncd && cp env.example.sh env.sh && vi env.sh'  # 填 SERVER_IP/CLIENT_IFACE
scp experiments/timesyncd/setup/setup-server.sh root@<SERVER_IP>:/root/
```

`env.sh` 至少要填 `SERVER_IP`（client 看得到 server 的那個 IP）與 `CLIENT_IFACE`（exp4 的 jitter 情境用 tc netem 套在這張網卡上）。`NTP_PORT` 與 `RESULTS_DIR` 有合理預設可不動。`env.sh` 已被 `.gitignore` 擋掉，不會被 commit。

## 2. L3 單機驗證（只需要 client VM，先做這個）

L3 的目的：在**只有 client 一台 VM** 的情況下，把所有腳本、注入、收斂判定、analyze 邏輯先驗一遍，不必先把 server 與真實網路架好。

原理：`CLOCK_MONOTONIC_RAW` 不受 adjtimex 影響 → fake server 在同一台 VM 上提供「未被打亂的真時」。即使我們用 `clock_inject.py` 把 client 的 CLOCK_REALTIME 撥歪、把 tick/freq 調出 ppm 誤差，loopback 上的 fake NTP server 回報的時間仍是乾淨的單調時鐘，所以 probe 量到的 offset 反映的就是「注入了多少、收回多少」。

```bash
ssh root@<CLIENT_IP>
cd /root/timesyncd
# env.sh 設 SERVER_IP=127.0.0.1
python3 -m unittest discover -s tests -v          # 應 26 PASS
systemd-run --unit=tsexp-fakentp --collect python3 lib/fake_ntp_server.py --bind 127.0.0.1 --port 123
mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=127.0.0.1\nFallbackNTP=\n' > /etc/systemd/timesyncd.conf.d/99-driftlab.conf
systemctl restart systemd-timesyncd
./setup/calibrate.sh --minutes 5                  # L3 煙霧用短校準
./run/exp1-drift-recovery.sh --duration-h 1 --ppm 100   # 預期 ~360ms、十幾秒收斂
./run/exp2-slew-399ms.sh
./run/exp3-restart-sync.sh --offset-ms 100
./run/exp4-poll256-soak.sh --scenario inject-80ms        # exp4 縮時煙霧（自帶結束條件，不吃 --hours）
```

每步的預期輸出與 PASS 判準如下。

1. **單元測試** `python3 -m unittest discover -s tests -v`
   - 預期：`Ran 26 tests`、結尾 `OK`。
   - PASS 判準：exit 0、26 個測試全過。涵蓋 clock_inject 折疊算式、ntp_probe、step_detector、analyze 的收斂/校準/verdict 邏輯。

2. **啟 fake server + 把 timesyncd 指到 127.0.0.1**
   - `systemd-run --unit=tsexp-fakentp ...` 把 fake NTP server 跑在 transient unit 裡（SSH 斷線也活著）。
   - drop-in 把 `NTP=127.0.0.1`、清掉 `FallbackNTP`，`systemctl restart systemd-timesyncd` 後生效。
   - PASS 判準：`systemctl status tsexp-fakentp` 為 active；`timedatectl timesync-status` 的 server 顯示 127.0.0.1。

3. **短校準** `./setup/calibrate.sh --minutes 5`
   - 停 timesyncd、暫存器歸零、free-run 量 5 分鐘，產出 `results/calibration.json`。
   - 預期輸出：結尾 `校準完成 → .../calibration.json`。
   - PASS 判準：`calibration.json` 出現，且 `client_ppm` 絕對值落在 VM 正常範圍（< 50）。L3 同機 loopback 下這個值通常很小。

4. **exp1 單 cell** `./run/exp1-drift-recovery.sh --duration-h 1 --ppm 100`
   - 數學折疊：1h × 100ppm → 注入 ≈ 360ms offset + 殘留 100ppm，腳本只跑恢復段。
   - 產出：`results/exp1/cell-1h_100ppm/result.json`。
   - PASS 判準：`result.json` 的 `converged=true`，`t_converge` 落在秒級到分鐘級（折疊後約 360ms 的 offset，十幾秒就該收回）。

5. **exp2 對照** `./run/exp2-slew-399ms.sh`
   - 跑 399ms 與 401ms 兩個 cell（門檻 0.4s 的下側與上側）。
   - 產出：`results/exp2/cell-399ms/` 與 `cell-401ms/` 各自的 `result.json` 與 `steps.csv`。
   - PASS 判準：399ms 那側是**一串小 slew 事件、無大 step**；401ms 那側出現**單筆 ≈ 400ms 的 step**。腳本會在 log 印 `step 事件 N 筆，最大單筆 Mms`，照這個對照即可。

6. **exp3 重啟對時** `./run/exp3-restart-sync.sh --offset-ms 100`
   - 收斂 → 注入 100ms → 立刻 `systemctl restart systemd-timesyncd`，量 restart 後第一次 `Contacted time server` 的 monotonic 延遲。
   - 產出：`results/exp3/cell-100ms/result.json`（含 `contact_latency_s`）。
   - PASS 判準：`converged=true`，`contact_latency_s` 為秒級（restart 後幾乎立刻去對時）。

7. **exp4 縮時煙霧** `./run/exp4-poll256-soak.sh --scenario inject-80ms`
   - 選 `inject-80ms` 是因為它**以收斂為結束條件、不靠 soak 時長**，所以不必傳 `--hours`。其餘 soak 情境（baseline-2048 / soak-256 / restart / outage-30m / jitter）才吃 `--hours`（整數小時，bash 算式）。
   - 此情境會對 `poll=256` 與 `poll=2048` 各跑一次：暖機到 max poll 後注入 80ms，因為 80ms < 0.4s 門檻，全程應為 slew、不准有 step。
   - 產出：`results/exp4/inject-80ms/poll-256/` 與 `poll-2048/` 兩個子目錄，外加 `results/exp4/inject-80ms/verdict.json`。
   - PASS 判準：`verdict.json` 為 `{"pass": true}`；兩個子目錄各有 `verdict.md` 且無 step 違規。

**L3 驗不到、必須留給 L4 的清單**：

- 真實網路延遲與抖動（loopback 沒有 RTT，jitter 情境的 netem 才模擬得出來）
- 真 chrony server 的行為（fake server 只回單調時鐘，不做真實 NTP 演算法）
- 長時 soak 的穩定度（L3 只跑縮時煙霧，看不出 24h 漂移與資源累積）
- PVE 排程備份/migration 對 guest 時鐘的干擾（只有實機 hypervisor 才會踩到）

## 3. L4 全套（兩台 VM）

```bash
# server
ssh root@<SERVER_IP> 'bash /root/setup-server.sh'
# client：env.sh 改回真 SERVER_IP，移除 fake server 與 127.0.0.1 設定
systemctl stop tsexp-fakentp 2>/dev/null || true
./setup/setup-client.sh
./run/all.sh --detach --soak-hours 24     # 全套無人值守；正式 soak 24h
./run/all.sh --status                      # 隨時查進度（SSH 重連也行）
```

說明：

- `setup-server.sh` 在 server 上裝 chrony 並設成 LAN NTP server（預設只服務 RFC1918 私有網段；要放行特定網段用 `--allow <CIDR>`）。跑完會印 `chronyc tracking`。
- 回到 client：把 `env.sh` 的 `SERVER_IP` 改回真 server IP，先 `systemctl stop tsexp-fakentp` 把 L3 的 fake server 收掉，再跑 `setup-client.sh`（裝依賴、把 timesyncd drop-in 指回真 server、開啟 CPU/Memory accounting 供 exp4 監測）。
- `all.sh --detach --soak-hours 24` 跑校準 → exp1 → exp2 → exp3 → exp4 全套無人值守，並以 `--detach` 丟進 transient unit；`--detach` 與 `--soak-hours` 在 `all.sh` 裡任意順序皆可。整套可中斷後重跑，已完成的 cell 會自動跳過續跑。
- `all.sh --status` 隨時查進度，會印出 `tsexp-all` 的狀態與 `results/all-state.json` 的各階段標記，SSH 重連後一樣能查。

## 4. 每步預期輸出與 PASS 判準（表格）

| 步驟 | 指令 | 預期 | PASS 判準 |
|---|---|---|---|
| 單元測試 | python3 -m unittest … | 26 tests OK | exit 0 |
| 校準 | calibrate.sh | calibration.json 出現 | `client_ppm` 絕對值 < 50（VM 正常範圍） |
| exp1 單 cell | --duration-h 1 --ppm 100 | result.json converged=true | t_converge 秒級–分鐘級 |
| exp1 ±1000ppm | … | converged=false | timeout 1800s 是預期結果（finding） |
| exp2 | … | 399ms 無大 step、401ms 單一 ≈400ms step | result.json + steps.csv |
| exp3 | … | contact_latency_s 秒級 | 四 cell 都 converged |
| exp4 | … | 各情境 verdict.md | 全 PASS |

## 5. 故障排除

- **SSH 斷線**：所有長任務都跑在 `tsexp-*` transient unit 裡，重連後 `--status` / `journalctl -u tsexp-all -f`（對應的 unit 名：`tsexp-exp1` / `tsexp-exp2` / `tsexp-exp3` / `tsexp-exp4` / `tsexp-all` / `tsexp-calibrate`）。
- **時鐘玩壞了**：`python3 lib/clock_inject.py reset` 把 tick/freq/offset 暫存器歸零並步進回真時，再 `systemctl restart systemd-timesyncd`；最後手段是 PVE snapshot 回滾整台 VM。
- **iptables 殘留**：`iptables -L OUTPUT -n | grep 123`，手動 `iptables -D OUTPUT -p udp --dport 123 -j DROP` 移除封鎖規則（腳本只動 OUTPUT + udp/123，永不碰 INPUT、永不碰 TCP）。
- **tc 殘留**：`tc qdisc del dev <iface> root` 清掉 jitter 情境留下的 netem。
- **timesyncd 一直不 sync**：`timedatectl timesync-status` 看 client 端狀態，並到 server 端 `chronyc tracking` 確認 server 自己有對上上游。
- **exp4 的自動清理**：exp4 已掛 TERM/EXIT cleanup trap（`cleanup_side_effects`），所以 `systemctl stop tsexp-exp4` 會自動清掉 poll drop-in（`/etc/systemd/timesyncd.conf.d/50-driftlab-poll.conf`）、iptables 與 tc 等持久副作用（冪等）。上面的手動清理是這個自動兜底失效時的 fallback。

## 6. 時間預算

| 階段 | wall-clock |
|---|---|
| L3 全部 | ~1h |
| 校準 | 0.5–1h |
| exp1（25 cells） | ~5–6h（±1000 的 6 cells 各吃滿 30min timeout） |
| exp2 | ~0.5h |
| exp3 | ~1h |
| exp4 quick（4h soak） | ~10h |
| exp4 正式（24h soak） | ~50h |

## 7. 收尾

```bash
# 工作機上
scp -r root@<CLIENT_IP>:/root/timesyncd/results experiments/timesyncd/
git add experiments/timesyncd/results
git commit --no-gpg-sign -m "timesyncd-drift-lab: L4 實測結果"
```

把 `results/` 收回 repo 並 commit 後，再用裡頭的 `result.json` / `verdict.md` / `summary.md` 回填網站頁 B（`timesyncd-drift-lab-experiments.mdx`）的「在你環境跑後對照」欄位——讓文章裡標註「待實測」的數字換成你環境的真實量測值。
