# VM Disk IO 調教實驗（rbd-io-perf）— PVE 版設計（spec）

> 日期：2026-07-07
> 取代：`2026-07-06-rbd-io-perf-experiments-design.md`（KubeVirt 版；前提於 2026-07-07 變更）
> 被測對象來源：`next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`、`rbd-io-experiment-plan.mdx`
> 研究 backlog：`experiments/rbd-io-perf/HYPOTHESES.md`（charter v2；33 條 hypotheses，3 killed）
> 範圍：在**實際在用的 Proxmox VE + Ceph cluster** 上，只動自有測試 VM / 測試 image 的參數，量出 QEMU / krbd / librbd / image-layout 各旋鈕相對 baseline 的真實效果；同步修正兩頁 MDX 已確認的錯誤。

## 1. 前提變更的依據

使用者判斷：KubeVirt（+ Multus）只是 control plane，不在 IO data path 上。此判斷正確，註腳有二：

1. KubeVirt 對效能的唯一影響是「control plane 幫你選了哪些 QEMU 預設」——H-001（cache 留空 → 自動 `none`+`native`）正是這種影響。QEMU / krbd 層的旋鈕結論在 PVE 上同樣成立。
2. PVE 有一個 datapath 級差異：RBD storage 預設 `krbd=0`，QEMU 走**內建 librbd driver**（`block/rbd.c`），不是頁面主軸的 krbd——沒有 `/dev/rbdX`、沒有 host iostat 邊界、cache 模式控制的是 `rbd_cache` 而非 host page cache（H-028，T1 已驗：block/rbd.c:961-963）。krbd 軸需要 `krbd=1` 的 storage 定義，**且使用者未調過 krbd → 可用性本身是 pre-flight 要驗的第一題（H-030）**。

## 2. 已確認的計畫錯誤（累計三條，皆 T1 source 驗證）

| # | 錯誤 | 證據 | 修法 |
|---|---|---|---|
| H-001 | 實驗 1 baseline（cache 留空）≡ 變體（cache=none）：KubeVirt 對 block device 自動 `none`+`native` | kubevirt `converter.go:387-423`、`manager.go:838-842` | 實驗 1 改 none / writethrough / writeback 三方對照；頁面敘述修正 |
| H-002 | baseline VMI 無 boot volume 開不起來；資料盤實為 `/dev/vdb`，fio `--filename=/dev/vda` 全錯 | `rbd-io-experiment-plan.mdx` L36-64、L76-97 | 頁面修正（VMI 補 boot；fio 改 vdb） |
| H-026 | 「不設 queues 的 baseline 是單 virtqueue」錯：QEMU v9.1 `num-queues` 預設 AUTO → vCPU 數 | qemu `virtio-blk.c:1997-1998`、`virtio-blk-pci.c:56-58` | 實驗 3 改反向對照（強制 `queues=1` vs 預設 auto）；頁面 blockMultiQueue 敘述修正（先補一個 T1 查證：libvirt 在 queues 未設時是否主動填 1） |

## 3. 環境與邊界

- **T3 環境**：使用者提供的生產 PVE cluster（node 清單、ssh 存取方式**待提供**，harness 參數化）；PVE 內建 ceph。pve-qemu / kernel / ceph 版本、OSD 拓樸（是否 hyperconverged）、pool 使用率、媒體與網路——全部由 pre-flight read-only 盤點，寫成 environment snapshot（H-033）。
- **操作邊界（使用者裁示）**：只碰自有測試 VM / 測試 image / 專屬測試 storage id。允許：(a) 既有 pool 建自有 image（含 object-size / striping）(b) 自有 image 的 `rbd image-meta conf_*` 覆寫 (c) 手動 `rbd map`（帶 map options）(d) storage.cfg 新增專屬 storage id（`krbd=1`，測完刪）。**禁止：任何 ceph cluster / daemon / config 變更、碰其他 VM、任何會讓其他 VM down 的操作**（慢可以接受）。
- **courtesy guardrails（H-031 / H-032）**：每輪監控並在以下情況 abort——ceph 出現**新增的** HEALTH_ERR 或持續 slow_ops（相對 pre-flight 基線差分；生產叢集 WARN 可能常態存在，不直接當條件）、pool 用量接近 nearfull 邊界、krbd 所在 node 可用記憶體低於門檻。測試 VM 優先放非 OSD node（若拓樸允許）；abort 條件參數化、預設開啟。
- **T1 對照與版本差異**：pinned submodules（qemu v9.1.0 / linux 6.8.0-52 / ceph v19.2.3）仍是 T1 基準；PVE 實機版本與 pinned 不同處在結論中誠實標註。kubevirt v1.5.0 anchors 只用於頁面修正。
- **guest**：固定版本 cloud image + PVE 原生 cloud-init（`--ciuser` / `--sshkeys` / DHCP）；fio 定版；guest IP 由 qemu-guest-agent 取得，ssh 直連。

## 4. 設計原則（相對 KubeVirt 版的增修）

沿用：prediction 先行 + `lib/verdict.py` 機器比對（三態 `confirmed` / `violated` / `indistinguishable`）、n≥3、pre-fill（H-005）、`--ramp_time`（H-008）、觀測窗對齊（H-009）、schedstat 差分（H-010）、生效驗證是前置條件、tainted 偵測、容量檢查與逐變體清理（H-025）、`experiments/` 家規（bash 3.2、TDD、shellcheck 0、stdout 機器行、mutating 要 `--yes-really-inject`）。

新增／改寫：

1. **A/B 交錯執行（H-029）**：同一實驗的 baseline 輪與變體輪交錯（A/B/A/B…），不做「先全 A 再全 B」；每輪記 `ceph -s` client io / pool stats 作併發負載上下文。生產環境重複次數起步 n≥3，噪音帶過大時升 n≥5。
2. **tainted 規則生產化（H-016）**：recovery / backfill → 該輪延後重試；scrub / 他人負載 → 記錄不作廢，靠交錯 + 重複吸收。
3. **變體切換**：`qm set` 改參數 → 自有 VM 冷重啟（stop → start）→ 生效驗證（`qm config`、QEMU cmdline `/proc/<pid>/cmdline`、krbd 軸加 `rbd showmapped` + sysfs）→ 全過才量。QEMU PID 斷言用 `/var/run/qemu-server/<vmid>.pid`（H-020）。
4. **雙軸觀測面**：krbd 軸 = guest iostat + host `/dev/rbdX` iostat + QMP `query-blockstats`；librbd 軸 = guest iostat + QMP `query-blockstats` + `rbd perf image iostat`（mgr read-only）。「虛擬化稅」在 librbd 軸的定義改為 guest await − QMP 端延遲。
5. **rxbounce 監看（H-004）**：krbd 軸全程收 node dmesg 增量（`bad crc` / socket closed）。

## 5. 實驗序列（PVE 版）

執行順序即編號；全部 automation-safe（無 gated cluster 實驗）。

| 實驗 | 內容 | 軸 | 對應 hypotheses |
|---|---|---|---|
| preflight | read-only 盤點：版本 / 拓樸（OSD 節點）/ pool 容量 / storage.cfg / VM 預設 / governor / mClock profile（僅記錄）/ fio rbd engine 可用性 | — | H-030 前置、H-033、H-019(讀) |
| krbd-check | krbd 可用性三關：throwaway image `rbd map`→讀寫→unmap；features 相容；專屬 storage id（krbd=1）attach 測試 VM | krbd | H-030、H-006 |
| exp0 | PVE node 上 host 層天花板：手動 map 的 `/dev/rbdX` 跑完整矩陣，`ioengine=libaio` vs `io_uring`；librbd 天花板用 `fio --ioengine=rbd`（pre-flight 確認可用，否則略過並記錄） | 雙 | H-021、H-013(替代) |
| baseline | 測試 VM 以 **PVE 實際預設**（pre-flight 確立）跑矩陣；定噪音帶；回答虛擬化稅（H-003） | 預設軸 | H-003、H-007、H-033 |
| exp-axis（頭牌） | **krbd vs librbd**：同規格 image、同 VM、兩種掛法對打 | 雙 | H-027、H-028 |
| exp1' | cache：none / writethrough / writeback（+directsync 選配）；librbd 軸機制按 H-028 寫預測；buffered 對照工作負載重設計（H-023） | 雙 | H-001、H-023、H-028 |
| exp2 | iothread on/off（`qm set` disk 參數） | 預設軸 | — |
| exp3 | queues 反向對照：`--args` 強制 `queues=1` vs 預設 auto（=vCPU 數） | 預設軸 | H-026、H-024 |
| exp4 | aio：io_uring / native / threads（`qm` 直接暴露；io_uring 是 PVE 預設） | 預設軸 | — |
| exp5 | image layout：object-size 4M / 16M / striping（自建 image，逐顆掛測） | 雙 | H-005、H-025 |
| exp6 | queue_depth：手動 map + map options（64/128/256），以 raw path 掛給測試 VM | krbd | H-011、H-015 |
| exp8 | guest IO scheduler none vs 預設 | 預設軸 | — |
| exp9 | alloc_size 變體 + fstrim/discard 場景（手動 map options） | krbd | — |
| exp-ra | readahead：guest / host `read_ahead_kb`，seqread 主場 | 雙 | H-022 |
| exp-rx | rxbounce on/off（手動 map options；若監看已見 bad crc 則升級優先序） | krbd | H-004 |
| exp-rc | librbd `conf_rbd_cache` per-image 覆寫 on/off（與 QEMU cache 模式優先序先在 T1/T2 釐清） | librbd | H-028 |

「軸」欄說明：**預設軸** = baseline 所用的掛法，即 pre-flight 確立的 PVE 實際預設（預期為 librbd）；標「雙」的實驗在兩軸各跑；標 krbd / librbd 的實驗只在該軸有意義。若 exp-axis 顯示兩軸差異巨大，Gate 3 可裁示把部分「預設軸」實驗在另一軸補跑。

fio 矩陣 v2 不變：`{randread, randwrite} × {qd1, qd8, qd32}` + `seqread 1M` + `seqwrite 1M`，`--direct=1 --ioengine=libaio --ramp_time=15 --runtime=60 --time_based --output-format=json`，固定 randseed；特例（buffered 對照、numjobs、trim）依實驗宣告。

krbd 不可用時的降級：exp-axis / exp6 / exp9 / exp-rx 剪除或降為 exp0 的 host 層對照點，librbd 單軸續行——krbd-check 的結果決定，寫入 environment snapshot。

時間預算：每變體 ≈ 8 點 × 75s × n3 ≈ 35 分鐘（交錯執行含 baseline 重跑約 ×2）；全序列粗估 15–20 小時 wall-clock → harness 支援按實驗分段、斷點續跑（bundle 存在即跳過）；生產叢集可挑離峰時段分批。

## 6. Harness 架構

```
experiments/rbd-io-perf/
├── HYPOTHESES.md
├── README.md
├── lib/
│   ├── common.sh            # ssh 向量、log→stderr、die、bundle helper、abort guardrails
│   ├── pve.sh               # qm 包裝：建 VM、set 參數、冷重啟、qm config / pid 斷言、cloud-init
│   ├── rbdimg.sh            # 自有 image 生命週期：create（layout 參數）/ map / unmap / image-meta / rm
│   ├── fio.sh               # 矩陣 render、pre-fill、A/B 交錯輪次執行
│   ├── collect.sh           # guest/host iostat、QMP query-blockstats（qm monitor）、schedstat、dmesg、ceph -s（read-only）
│   └── verdict.py           # fio JSON 解析、mean/CoV、噪音帶、三態 verdict（bastion 端 python3）
├── run/
│   ├── preflight.sh         # read-only
│   ├── krbd-check.sh        # --yes-really-inject（建/刪 throwaway image、storage id）
│   ├── exp0-host-ceiling.sh
│   ├── baseline.sh
│   ├── scenario-exp-axis.sh
│   ├── scenario-exp{1,2,3,4,5,6,8,9,ra,rx,rc}-*.sh
│   ├── cleanup.sh           # best-effort：unmap、刪測試 VM/image/storage id
│   └── all.sh
├── tests/                   # fake ssh/qm/rbd + fio JSON fixtures；run-tests.sh
└── results/                 # git-ignored evidence bundles
```

evidence bundle 內容照 KubeVirt 版（prediction / 原始輸出 / verdict / 併發負載上下文），`EVIDENCE-SUMMARY-<date>.md` 進 git。

## 7. 階段切分與 gates

| Phase | 內容 | Gate |
|---|---|---|
| 1 | harness 骨架 + tests（純本機）；**批次 1 頁面修正**（H-001 / H-002 / H-026——H-026 先補 libvirt T1 查證再動筆） | tests + shellcheck + `make validate` 全綠 |
| 2 | 真機：preflight → krbd-check → exp0 → baseline（噪音帶出爐） | **Gate 2：等使用者提供 PVE 存取方式並說 go**；krbd-check 結果決定軸計畫；baseline CoV 過大先停下調整 |
| 3 | exp-axis 起的全部旋鈕實驗（A/B 交錯、分段跑） | 每 scenario assert 過才下一個；guardrail abort 即停 |
| 4 | Gate 3 synthesis：結果表、`HYPOTHESES.md` 收斂、批次 2 頁面增補（rxbounce / mClock 解讀 / librbd 軸機制 / 實驗 0 / seqread / H-011 重推 / PVE snapshot 標註） | **Gate 3：findings triage 由使用者選路線** |

## 8. 頁面修正清單

**批次 1（已確認，Phase 1）**：同前版（H-001 cache 敘述、H-002 VMI/vdb）+ **H-026**：`rbd-io-tuning-catalog` blockMultiQueue 條目與 `rbd-io-experiment-plan` 實驗 3 的「baseline 單 queue」前提修正（附 qemu 錨點；先完成 libvirt 中間層 T1 查證）。

**批次 2（待實測，Phase 4）**：rxbounce 條目（④ 層）、librbd 軸 cache 機制（H-028，⑤ 層 Callout 擴充）、實驗 0 / seqread / readahead 補進實驗計畫頁、queue_depth 機制重推（H-011）、krbd vs librbd 對照結果、結果表每變體一列 + PVE environment snapshot 標註。

## 9. 風險與邊界

- **生產叢集**：所有注入只及自有資源；guardrails 見 §3；實驗負載可能讓其他 VM 變慢（使用者已接受），但任何「新增 ERR / 持續 slow_ops」立即 abort + cleanup。
- **hyperconverged krbd 風險（H-031）**：永不主動觸發；靠節點選擇 + 記憶體監控 + abort 門檻防禦。
- **版本漂移**：PVE 版本與 pinned submodules 不同——結論標註實機版本；機制敘述仍錨 pinned source，行為差異處標記「待 PVE 版本對照」。
- **krbd 不可用**：降級路徑已定義（§5）；不影響 librbd 軸與批次 1 頁面修正。
- **絕對數字不可外推**：只下「此環境內相對差異」結論，沿用頁面既有原則。

## 10. 驗收標準

1. `bash experiments/rbd-io-perf/tests/run-tests.sh` 全綠；`shellcheck lib/*.sh run/*.sh tests/*.sh` 0；`make validate` exit 0。
2. 批次 1 頁面修正 merge（三條 confirmed 錯誤都有 source 錨點）。
3. Phase 2–3 完成後：preflight snapshot、krbd-check 結論、exp0 / baseline / 各 scenario 的 evidence bundle 齊備並被 `EVIDENCE-SUMMARY-<date>.md` 索引；`HYPOTHESES.md` P0/P1 條目離開 `proposed`。
4. Gate 3 後：批次 2 頁面增補 merge；結果表填實測數字或 `indistinguishable`；其他 VM 零 down 事件（guardrail log 佐證）。
