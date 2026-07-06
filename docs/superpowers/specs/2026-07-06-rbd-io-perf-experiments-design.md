# VM Disk IO 調教實驗（rbd-io-perf）— 設計（spec）

> **已被取代（superseded）**：前提於 2026-07-07 變更——T3 環境改為生產 Proxmox VE + Ceph cluster、只動 VM 參數不動 ceph。現行設計見 `2026-07-07-rbd-io-perf-pve-experiments-design.md`。本檔保留為 KubeVirt 版設計的歷史紀錄；其中 H-001 / H-002 的頁面修正結論仍然有效。
>
> 日期：2026-07-06
> 被測對象來源：`next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`、`rbd-io-experiment-plan.mdx`
> 研究 backlog：`experiments/rbd-io-perf/HYPOTHESES.md`（25 條 hypotheses，Gate 1 已裁示全收）
> 範圍：把實驗計畫頁的 9 個實驗修正成可信、可自動化的受控實驗，在 homelab 真機量出各旋鈕相對 baseline 的真實效果；同步修正兩頁 MDX 已確認的錯誤。

## 1. 目標

1. **修計畫**：`rbd-io-experiment-plan` 的實驗設計含兩個已確認錯誤（見 §2）與多個量測有效性缺口——修正後每個實驗量的才是它宣稱在量的東西。
2. **建 harness**：`experiments/rbd-io-perf/` 下的自動化 harness，走 `inject → observe → collect → rollback → assert` 契約，prediction 先行、verdict 由機器比對，符合 `experiments/` 家規（bash 3.2、TDD、shellcheck 0、stdout 只放機器行）。
3. **跑實驗**：VM/client 層（automation-safe）全自動；cluster 層（osd_op_num_shards、mClock）gated 手動觸發。
4. **回饋頁面**：批次 1 修已確認錯誤（不需真機）；批次 2 依實測結果增補（rxbounce / mClock 條目、實驗 0、seqread、機制重推）。

成功標準：

- harness tests 全綠 + shellcheck 0 + `make validate` exit 0。
- 每個跑過的 scenario 都留下 evidence bundle（原始輸出 + prediction + verdict），`HYPOTHESES.md` 對應條目推進到 `confirmed` / `violated`。
- 任何「A 比 B 快」的結論都有 n≥3 + 噪音帶佐證；量不出差異的旋鈕誠實標 `indistinguishable`。

## 2. 已確認的計畫錯誤（本 spec 的直接動機）

| # | 錯誤 | 證據 | 修法 |
|---|---|---|---|
| H-001 | 實驗 1 的 baseline（cache 留空）與變體（cache=none）是同一組設定：KubeVirt 對 block device 後端在 cache 留空時自動設 `cache=none` 並推 `io=native` | kubevirt v1.5.0 `converter.go:387-423`（`SetDriverCacheMode`）、`manager.go:838-842` | 實驗 1 改為 none / writethrough / writeback 三方對照；頁面「留空＝無優化意圖」敘述修正 |
| H-002 | baseline VMI 無 boot volume，VM 開不起來；補 boot 盤後資料盤是 `/dev/vdb`，計畫內所有 fio `--filename=/dev/vda` 都錯 | `rbd-io-experiment-plan.mdx` L36-64、L76-97 | VMI 補 containerDisk boot + cloud-init；fio 全改 `/dev/vdb` |

## 3. 環境基線

- **orchestrator**：macOS bastion（本 repo），ssh key = repo 內 `.ssh/id_ed25519`。
- **k8s**：`ceph-lab-k8s` = `192.168.18.160`，單節點 k0s；Rook operator（`rook-ceph`）+ external CephCluster（`rook-ceph-external`）；kubeconfig 存取方式沿用 `experiments/ceph-alert-real-lab` 的作法。
- **KubeVirt**：**尚未安裝**——Phase 2 安裝，版本 pin **v1.5.0**（與 submodule / 頁面對齊）。.160 是 PVE VM → 需 nested virtualization（pre-flight 驗 `/dev/kvm`）。
- **ceph**：cephadm v19.2.3，3 mon（.166/.167/.164）+ 9 OSD（.169/.171/.174 各 3）。媒體與網路使用者稱 SATA SSD + 10G，**未確認** → pre-flight 以 `ceph osd metadata`（rotational）與 `ethtool` 實測後寫入 environment snapshot。
- **版本錨點**：kubevirt v1.5.0 / libvirt v10.10.0 / qemu v9.1.0 / linux 6.8.0-52 / ceph v19.2.3 / ceph-csi v3.14.0（submodule pinned）。.160 實際 csi 版本（Rook v1.19.6 部署）由 pre-flight 記錄，差異寫入 snapshot（H-014）。
- **guest**：固定版本 cloud image（Ubuntu 22.04 cloud image，pre-flight 記 sha256）+ cloud-init：注入 ssh key、安裝定版 fio、關閉不必要服務。guest 存取 = `virtctl port-forward` 的 ssh。

## 4. 設計原則

1. **prediction 先行、機器比對**：每個 scenario header 宣告 signal / expected / window / rollback criterion；`lib/verdict.py` 比對，verdict 三態 `confirmed` / `violated` / `indistinguishable`（差異落在噪音帶內）。禁止事後改判。
2. **統計紀律（H-007）**：每個 fio 點 n≥3；baseline 先量 CoV 決定噪音帶；差異 > 噪音帶才可宣稱方向。
3. **量測有效性**：測試盤建立後全盤 pre-fill（H-005）；fio `--ramp_time=15 --runtime=60`（H-008）；iostat 收集窗與 fio measurement window 對齊、丟 ramp 段（H-009）；QEMU thread CPU 用 `/proc/<pid>/task/<tid>/schedstat` 差分 + 記 %steal（H-010）。
4. **生效驗證是前置條件不是事後檢查**：每變體 apply 後先斷言 `virsh dumpxml` / QEMU cmdline / `rbd showmapped` / sysfs 讀值符合預期（含 H-015 的 scheduler+nr_requests 並記），全過才開始量。
5. **變體切換 = 完整 manifest delete→recreate**（H-012）：每變體一份 VMI YAML；delete → wait gone → apply → wait ready → 斷言 QEMU PID 新起。
6. **tainted 偵測**：每輪前後抓 `ceph -s`（scrub / recovery / degraded）與 VMI restartCount / QEMU PID（H-016 / H-020）；tainted 該輪作廢自動重跑（上限 2 次），連續 tainted 中止並留 bundle。
7. **session 漂移哨兵**（H-017 / H-018）：每個執行 session 開頭重跑 baseline 哨兵點（randwrite 4k qd1 + seqwrite 1M 各 1 輪），落在既有噪音帶外 → 本 session 重建比較基準。
8. **rxbounce 監看**（H-004）：所有實驗全程收 host dmesg（`bad crc`、socket closed 訊息）；出現即記錄並升級為 rxbounce on/off 變體實驗。
9. **容量與清理**（H-025）：pre-flight `ceph df` 容量檢查；每變體測完刪 PVC 並確認 image 移除後才開下一個。
10. **家規**：read-only 預設、mutating 操作要 `--yes-really-inject`；bash 3.2 相容；stdout 只放機器要抓的行；TDD（fake ssh/kubectl/virtctl）；`shellcheck` 0；每次改動跑 `run-tests.sh` + `shellcheck` + `make validate`。唯一例外：fio JSON 解析與統計用 `lib/verdict.py`（python3，bastion 端執行）。

## 5. 實驗序列（refined plan）

執行順序即編號順序。「比較基準」欄明示 diff 對象（回應設計備忘）。

| 實驗 | 內容 | 比較基準 | 層級 |
|---|---|---|---|
| preflight | 環境 snapshot：媒體/網路/版本/容量/governor/`/dev/kvm`/SC imageFeatures（H-006/H-014/H-017） | — | read-only |
| exp0（新） | host 上直接對 `/dev/rbdX` 跑完整矩陣；`ioengine=libaio` vs `io_uring` 兩變體（H-021、H-013 替代路徑） | 兩變體互比 + 供後續算 headroom | automation-safe |
| baseline | 修正後 VMI（boot + `/dev/vdb`、pre-fill、n≥3）；量 CoV 定噪音帶；回答 H-003 虛擬化稅 | exp0（headroom） | automation-safe |
| exp1' | cache 三方：none / writethrough / writeback；buffered 工作負載重設計（direct=0 無 fsync + fsync=1 兩條，預測 Falsify 階段重推，H-023） | baseline（=none） | automation-safe |
| exp2 | IOThreads（`ioThreadsPolicy: auto` + `dedicatedIOThread`） | baseline | automation-safe |
| exp3 | blockMultiQueue（含 numjobs=4 對照組與 baseline numjobs=4） | baseline | automation-safe |
| exp4 | io: threads / native（io_uring 見 exp0；第二階段視差異決定 hook sidecar） | baseline | automation-safe |
| exp5 | RBD layout：object-size 4M / 16M / striping（獨立 PVC，重建不改） | baseline | automation-safe |
| exp6 | queue_depth 64/128/256（SC mapOptions）；機制敘述依 H-011 重推（nr_hw_queues=num_present_cpus） | baseline | automation-safe |
| exp8 | guest IO scheduler none vs 預設 | baseline | automation-safe（guest 內 sysfs） |
| exp9 | alloc_size 變體 + discard/fstrim 場景 | baseline | automation-safe |
| exp-ra（新） | readahead：guest / host read_ahead_kb 變體，seqread 主場（H-022） | baseline | automation-safe |
| exp7 | osd_op_num_shards（改 + 逐一重啟 9 OSD + 回退） | baseline | **gated** |
| exp-mclock（新） | osd_mclock_profile：balanced vs high_client_ops（H-019） | baseline | **gated** |

fio 矩陣 v2：`{randread, randwrite} × {qd1, qd8, qd32}` + `seqread 1M` + `seqwrite 1M` 共 8 點；統一 `--direct=1 --ioengine=libaio --ramp_time=15 --runtime=60 --time_based --group_reporting --output-format=json`，固定 randseed。特例：exp1' 的 buffered 對照、exp3 的 numjobs=4、exp9 的 trim。

收集 metric v2（每輪）：fio JSON、guest `/dev/vdb` iostat、host `/dev/rbdX` iostat（窗口對齊）、QEMU thread schedstat 差分 + guest %steal、QMP `query-blockstats`、host dmesg 增量、`ceph -s` 前後哨兵。

時間預算估算：每變體 ≈ 8 點 × 75s × n3 + 開銷 ≈ 35 分鐘；automation-safe 全序列 ≈ 20 變體 ≈ 12 小時 wall-clock → harness 支援按實驗分段跑、斷點續跑（bundle 存在即跳過已完成輪次）。

## 6. Harness 架構

```
experiments/rbd-io-perf/
├── HYPOTHESES.md            # 研究 backlog（已存在）
├── README.md                # 執行順序、安全界線、驗證 gate
├── lib/
│   ├── common.sh            # ssh 向量（flag 逐個寫死）、log→stderr、die、bundle helper
│   ├── vmi.sh               # 變體切換（delete→recreate→ready→生效驗證）
│   ├── fio.sh               # 矩陣 render、pre-fill、n 輪執行
│   ├── collect.sh           # iostat/schedstat/QMP/dmesg/ceph -s 收集與窗口對齊
│   └── verdict.py           # fio JSON 解析、mean/CoV、噪音帶比對、三態 verdict
├── manifests/
│   ├── vmi-baseline.yaml    # boot(containerDisk+cloud-init) + /dev/vdb(RBD PVC)
│   ├── vmi-exp{1..4}-*.yaml # 每變體一份完整 VMI
│   └── sc-*.yaml / pvc-*.yaml  # layout / queue_depth / alloc_size 變體
├── run/
│   ├── preflight.sh         # read-only 環境 snapshot
│   ├── install-kubevirt.sh  # v1.5.0，冪等，--yes-really-inject
│   ├── exp0-host-ceiling.sh
│   ├── baseline.sh
│   ├── scenario-exp{1..6,8,9,ra}-*.sh
│   ├── gated/scenario-exp7-osd-shards.sh
│   ├── gated/scenario-mclock.sh
│   ├── cleanup.sh           # best-effort、可重複
│   └── all.sh               # automation-safe 鏈（不含 gated/）
├── tests/                   # fake ssh/kubectl/virtctl + fio JSON fixtures
│   └── run-tests.sh
└── results/                 # git-ignored evidence bundles
```

evidence bundle（每輪一目錄）：prediction、原始 fio JSON、iostat 原始輸出、schedstat 前後、QMP 輸出、dmesg 增量、ceph -s 前後、verdict。`EVIDENCE-SUMMARY-<date>.md` 索引 commit 進 git。

## 7. 階段切分與 gates

| Phase | 內容 | Gate |
|---|---|---|
| 1 | harness 骨架 + manifests + tests（純本機離線可驗）；**批次 1 頁面修正**（H-001/H-002 錯誤，不需真機） | tests + shellcheck + make validate 全綠 |
| 2 | 真機 preflight → KubeVirt 安裝 → exp0 → baseline（噪音帶出爐） | **Gate 2：真機操作開始前等使用者 go**；baseline CoV 過大時停下來調整（H-007/H-017） |
| 3 | exp1'-6、exp8/9、exp-ra 全自動跑 | 每 scenario 的 assert 過才下一個 |
| 4 | gated：exp7、exp-mclock（使用者手動觸發，ok-to-stop → 回退 → HEALTH_OK） | 破壞性規矩 |
| 5 | Gate 3 synthesis：結果表生成、`HYPOTHESES.md` 收斂、批次 2 頁面增補（rxbounce/mClock 條目、實驗 0、seqread、H-011 機制重推） | **Gate 3：findings triage 由使用者選路線** |

## 8. 頁面修正清單

**批次 1（已確認，Phase 1 執行）**：

- `rbd-io-experiment-plan.mdx`：baseline Callout「留空＝不開 O_DIRECT」改為正確敘述（附 `SetDriverCacheMode` 錨點）；實驗 1 改三方對照；baseline VMI 補 boot volume；fio `--filename` 改 `/dev/vdb`；「生效驗證」補 cache 留空時 dumpxml 應看到 `cache='none' io='native'`。
- `rbd-io-tuning-catalog.mdx`：① 層 `cache` 與 ② 層推導條目補「留空時 converter 對 block device 自動 none」的行為（目前只寫了 SetOptimalIOMode 那一半）。

**批次 2（待實測，Phase 5 執行）**：rxbounce 條目（④ 層）、mClock 條目（⑤ 層）、實驗 0 與 seqread/readahead 補進實驗計畫頁、queue_depth 機制敘述重推（H-011）、結果表改每變體一列、實測數字填表。

## 9. 風險與邊界

- **nested virt 稅**：絕對數字不可外推；所有結論限定「此環境內相對差異」。頁面既有的「只信你自己環境的數字」原則不變。
- **mClock 天花板**（H-019）：若 exp0 顯示 host 端天花板遠低於 SSD 能力，先查 mClock profile 再跑 VM 實驗，避免整批數字被 QoS 上限壓扁。
- **單節點 k0s 資源**：VMI 4 vCPU + 4Gi；pre-flight 驗 node allocatable，不足則降規並記入 snapshot。
- **容量**：exp5/exp6 多 PVC + pre-fill，逐變體建刪，`ceph df` 前置檢查。
- **KubeVirt 安裝失敗 / nested 不支援**：Phase 2 的 install 是冪等腳本；`/dev/kvm` 不存在則中止並回報（fallback 討論再開）。

## 10. 驗收標準

1. `bash experiments/rbd-io-perf/tests/run-tests.sh` 全綠；`shellcheck lib/*.sh run/*.sh run/gated/*.sh tests/*.sh` 0；`make validate` exit 0。
2. 批次 1 頁面修正 merge，zero-fabrication 規則通過（新敘述都有 source 錨點）。
3. Phase 2-3 完成後：exp0 + baseline + 全部 automation-safe scenario 各留 evidence bundle；`EVIDENCE-SUMMARY-<date>.md` 索引；`HYPOTHESES.md` P0/P1 條目全部離開 `proposed`。
4. Gate 3 之後：批次 2 頁面增補 merge，結果表填實測數字（或 `indistinguishable` 標記）。
