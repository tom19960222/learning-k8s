# 收官報告輸入：監看期間的發現（2026-07-30 ~ 08-06）

> 給撰寫最終實驗報告的 agent。
>
> **這份只寫 `INTERIM-REPORT-2026-08-04.md` 裡沒有的東西**，依「不放進去報告就是錯的」到「錦上添花」排序。
> 中期報告的 endpoint 矩陣、margin audit、premises 等請直接引用該檔，不要在這裡找。

**相關文件**

| 內容 | 路徑 |
|---|---|
| 結論主體（868 行） | `INTERIM-REPORT-2026-08-04.md` |
| 資料集封閉稽核 | `EVIDENCE-SUMMARY-2026-08-06.md` |
| 所有假說與教訓 | `HYPOTHESES.md` |
| gate 修正的成因／修法／驗證 | `git log dadf901^..45fe93e`（5 個 commit，message 完整） |
| 監看期交接 | `HANDOFF-2026-08-05.md` |

---

# 第一級：不放進去，報告就是錯的

## 1. 三個 harness 攔不到的資料陷阱

**共同點：verdict 全部 `recorded` / `tainted=False`，外表完全乾淨。** 報告若直接對 `results/` 做統計就會踩到。
`EVIDENCE-SUMMARY` 的 `tainted=0` **不會**反映這三項。

### (a) 被污染的注入前窗 —— 收官分析**必須排除**

```
rack-isolation-4k-low+balanced/r2/attempts/20260802T000016Z
注入前窗 28.967 ms（該組 25 筆的中位數 2.38 ms，12 倍）
→ p99_degradation_ratio 被壓成 0.48（同 cell 其他 replicate 是 5.66）
```

主指標是「量測窗 ÷ 注入前窗」，分母壞掉比值就沒有意義。發生率約 **1/25**，推測是 fio readiness barrier 期間的樣本落進那 60 秒窗。

**偵測方式**（監看期間每 2 小時跑一次，155 筆只抓到這一筆）：對每個 `(shape, pressure)` 取 `aggregate.json` 的 `windows.baseline.p99_ns`，偏離該組中位數 > 50% 即為離群。

### (b) measurement cap 決定 censored 格的比值 —— **不可跨 cap 合併平均**

```
flapping-4k-extreme 依 cap 分組：
  cap=2700  n=6  [3.09, 3.71, 4.56, 4.63, 4.80, 4.99]  中位 4.60
  cap=5400  n=2  [11.98, 12.13]                         中位 12.06
```

機制：`total_brownout_seconds ≈ 0.79–0.86 × cap`（2700 → 2116–2188、5400 → 4628–4630）。
故障從未解除，**量多久就壞多久** —— 累積型指標量的是「你看了多久」，不是「叢集有多糟」。

- **r3 是 rescue-replicate 核發的、cap 被放寬到 5400**，與 r1/r2（cap 2700）不可比
- **`max_stall_seconds` 是 cap 不變量**（cap=2700 → 21–28、cap=5400 → 22–24）→ censored 區間應改用它
- 這也**再次否證** flapping 的 profile 差異：先前看到的 191 vs 485 之類差距，有一部分就是 cap 不同造成的

### (c) `rack prepare 間隔 7s > 5s` 是假 taint —— **14 次，taint 原因第一名**

`lib/inject.sh` 的 `skew` 從 `arm_guard n1` 之前算到 `arm_chain n2` 之後，涵蓋 **4 次 SSH**，但真正造成隔離的只有中間的兩次 `arm_chain`。到 Azure 每次 ssh ≈1.75 秒 × 4 ≈ 7 秒 —— **歷史 4 次全部剛好 7 秒，是確定性的往返時間**。

**Ceph 的 ground truth 說兩台是同時失效的**：

| attempt | `prepare_skew_s` | osd1 down epoch | osd2 down epoch | 差 |
|---|---|---|---|---|
| 0728-072816 | 7 | 966 | 968 | 2 |
| 0728-075920 | 7 | 1364 | 1366 | 2 |
| 0801-035832 | 7 | 11806 | 11808 | 2 |
| 0801-053022 | 7 | 12185 | 12186 | 1 |

**不澄清會不當否定整批 rack-isolation / node-isolation 資料。**（此缺陷**未修**，因為它不阻擋 attempt 完成，中途改注入路徑風險高於收益。）

---

# 第二級：頭條科學結論

## 2. 負面結果才是主結果

**九個 cell group 獨立顯示「組內變異 ≥ 組間差異」**，型態一致：**n=1 看起來顯著、補到 n=2~3 就被吞掉**。

最乾淨的單一證據 —— `osd-down-4k-low`（**全 campaign 樣本最多、全部 `cap=2700`、全部 `censored=false`**）：

| profile | recovery(s) | 中位數 | 組內全距 |
|---|---|---|---|
| balanced | 671 / 759 / 889 | 759 | **218** |
| high_client_ops | 796 / 835 | 816 | 39 |
| high_recovery_ops | 720 / 751 / 787 | 751 | 67 |

**中位數差 8 秒，balanced 組內全距 218 秒。** p99（3.52–3.95）與 `max_stall`（20–22）同樣全部重疊。

**建議寫法**：`recovery`、`p99_degradation_ratio`、`max_stall_seconds` 在本 campaign 的樣本數下**均不具 profile 鑑別力**。這不是「還沒測出來」，是**測了九次都沒有**。

被推翻的候選訊號（過程本身值得寫）：

| 時點 | 當時看到的 | 補樣本後 |
|---|---|---|
| osd-down-4k-low recovery | high_recovery_ops 三筆都低於另兩組最小值 | balanced 的 r3 = 671，比 high_recovery_ops 最小值 720 還低 |
| rack-isolation-4k-extreme achieve_ratio | 三 profile 排序清楚 | high_client_ops 第二筆 0.7833 vs 1.0272，組內 0.244 > 組間 0.171 |
| node-isolation-4k-mid p99 | high_recovery_ops 代價最大 | balanced 補到 n=2 變 7.32/8.94，兩組完全重疊 |

## 3. 唯一存活的正面訊號

`achieve_ratio` @ **`osd-down` / 4k/extreme**（不限速，target = 校準天花板 63,634 IOPS）：

| profile | n | 值 | 組內全距 |
|---|---|---|---|
| high_client_ops | 2 | 1.0247 / 1.0250 | **0.0003** |
| balanced | 2 | 0.9042 / 0.9064 | **0.0022** |
| high_recovery_ops | 2 | 0.8822 / 0.8840 | **0.0018** |

**組間 0.02–0.14 vs 組內 0.002 → 相差 10–70 倍**，排序完全符合 mClock 設計意圖（high_client_ops 保住 client 吞吐、high_recovery_ops 讓給 recovery）。

⚠️ **rack-isolation 的同一指標不成立**（見上表）。**報告只能保留 osd-down 這組。**

---

# 第三級：方法論發現（最可複用的部分）

## 4. 有效性 gate 六次假警報、零真陽性

| # | 根因 |
|---|---|
| 1–2 | 校準環境無 sampler 併行 → 參考**條件**不可比 |
| 3 | 新組合前 3 個 replicate 樣本不足 |
| 4 | 參考池混不同故障型 → **母體**不可比 |
| 5 | 全域門檻 vs 逐組合離散度 → **門檻粒度**不對 |
| 6 | 全域計數 vs 逐組合門檻 → **計數粒度**不對 |
| 7 | achieve-ratio 的絕對檢查被拿去累積「連續漂移」→ **語意**錯配 |

**共同結構：判準的某個維度沒跟著資料的實際結構走。**
**門檻數值從頭到尾一次都沒調過**（`BASELINE_P99_TOLERANCE=0.15`、MAD 乘數 3.0、`BASELINE_ACHIEVE_MIN=0.85`、`DRIFT_LIMIT=3`）。

**最根本的一條**：gate **量錯了東西** —— 它用「善後復測」（backfill 情境 MAD 29.2%、全距 8.5×），而**更好的儀器就在旁邊**：注入前窗跨 8 天在 8 個組合的 MAD 只有 **1.1–9.5%**。

**可複用通則**：以「歷史同條件中位數」為基準的 drift gate，**失敗模式集中在「同條件」的定義，不在門檻**。設計時應先窮舉會讓量測條件系統性偏移的所有變因，再決定分層維度。

最終處置（使用者裁示）：drift 改為**只告警不停佇列**（`45fe93e`），判定側與所有資料有效性 gate 一律未動，訊號照記進 `baseline-check.json` 供事後稽核。

## 5. chaos 在此量測架構下不可驗證

| | chaos | 正常故障型 |
|---|---|---|
| `covered_seconds` | ~1826 | ~1800 |
| `gaps` / `gap_seconds` | **0 / 0** | 0 / 0 |
| **`evidence_seconds`** | **547 / 592 / 608（≈33%）** | **9–10** |

**60 倍落差**，evidence 全是 `no-check (supervisor)`，每段 60–90 秒。
成因：chaos 30 分鐘打 **44 個事件**（`chaos: OK seed=4242 events=44`）反覆隔離多台 node，coverage supervisor 的 SSH 打卡被自己注入的故障打斷。

**資料其實完整（`gaps=0`），壞的是打卡證明。** 三格 × 三次 attempt 全部 taint、`aggregate.json` 從未產生 → **零數值資料，三格皆 needs-human**。

這是 **H-033「被測系統的故障會反過來干擾量測工具」的極端版本**，指向明確改進方向：**coverage 打卡不該依賴會被故障影響的路徑**。

## 6. supervisor 分不出「死了」與「刻意停手」

舊版只用 `pgrep` 判斷存活。佇列被 gate 刻意 halt 時，它每 2 分鐘拉起一次、每次立刻再 halt，**空轉 40 次（43 分鐘）**才因上限停手。
修正後（`e42ce7f`）在真實環境驗證：偵測到 `halted=True` 就留言收工，**重啟計數 0**。

順帶抓到一個更難查的方向：舊 pattern `pgrep -f 'run/faults.sh'` 會匹配到 **`shellcheck ... run/faults.sh`**，而 `tests/gate.sh` 每次都跑 shellcheck —— **佇列真的死了時 supervisor 反而會一路沉睡**。

---

# 第四級：報告框架上的陷阱

## 7. 跨壓力／跨形態比較會得出相反結論

rack-isolation 的 p99 劣化：**4k/low 5.7–6.2 → 4k/mid 5.6–8.2 → 4k/extreme 1.4**。
extreme 的 baseline 本來就 ~52ms（seq/extreme ~105ms），絕對衝擊被巨大分母壓平。

反方向：flapping @ 4k/low 的 baseline 只有 2.4ms，比值爆到 **313–476**。

**同一個故障在不同壓力下的比值差兩個數量級。** extreme 與 seq 區間應改看絕對值（`max_stall_seconds` / `total_brownout_seconds`）。

## 8. campaign 不會自然收斂（若要說明為何在此停手）

`cov-upgrade` 在變異係數超標時要求補樣本（`MAX_N = 5`），但**這些 cell 的高變異是物理性的、補了不會變小** → 負回饋失效。
實測：`pending` 連續 7 次檢查停在 17，完成與 amendment 一比一（8 小時完成 +5、amendment +5，淨進度 0）。

**本身也是一條方法論教訓**：以變異係數為觸發的自動補樣本機制，遇到本質高變異的量會無限要求。

## 9. 環境雜訊（解釋部分 taint，非 harness 缺陷）

中斷前日誌出現 `ssh: connect to host 20.89.226.108 port 22: Operation timed out` / `Network is unreachable`。
**網路瞬斷造成 coverage supervisor 少打一次卡（25 秒）**，導致 `coverage-proof` 判 taint。gate 判斷正確（證據確實缺了），但成因無害。

---

# 給報告作者的三個提醒

1. **`EVIDENCE-SUMMARY` 的 `tainted=0` 是最重要的品質指標**（156 筆全部乾淨），但「乾淨」不等於「可用」—— 第一級那三個陷阱都不會反映在這個數字裡。
2. **不要用 n=1 下任何結論。** 本 campaign 用九次教訓證明；監看期間我自己也犯過兩次（recovery 軸、achieve_ratio 的 rack 組），都被下一筆資料打臉。
3. **誠實寫「量不到」。** 硬湊一個 profile 排名會被下一個補到 n=3 的人推翻 —— 我們已經自己推翻九次。

---

# 資料集最終狀態

```
audit: 156/177 cells=63 missing=21 duplicate=0 censored=24 tainted=0 needs-human=7 descope=0
```

- **完成 156 個 execution，63 個 cell 全部有資料**（chaos 3 格除外）
- **`tainted=0`、`duplicate=0`**
- `censored=24`（全是 flapping，預期行為）
- `needs-human=7`：4 個舊的 + **chaos 3 格**
- 缺件 21：chaos 3 格（0/1）+ 18 格 r3/r4 補樣本（2–3 / 3–4），**不影響結論**

叢集收工時狀態：**129 PG 全部 active+clean、8 OSD up+in、無殘留隔離規則**。
兩個 `HEALTH_WARN` 是實驗刻意設的 `noscrub,nodeep-scrub` 旗標與衍生警告，非損害。

**Campaign 總計約 230 小時、約 $1,846。**
