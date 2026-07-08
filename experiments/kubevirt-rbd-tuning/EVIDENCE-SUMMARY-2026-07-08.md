# EVIDENCE SUMMARY — 2026-07-08（環境世代 gen-1：FSID ab33c12c…、make start 後 ceph 重建即換代）

> bundle 原始檔在本機 `results/`（gitignored）；本檔是可進 git 的索引。頁面數字只准引用本檔或 bundle。

## E-00 環境盤點 — done

- Bundle：`results/E-00/20260708-*/snapshot.txt`、`memory-target-fix.txt`
- 版本：ceph **19.2.4**（pinned 19.2.3，patch 差）/ ceph-csi **v3.14.0** ✓ / KubeVirt **v1.5.0** ✓ / k8s v1.32.13 / 全節點 kernel **6.8.0-1059-azure**、Ubuntu 22.04
- 拓樸：3 mon（mgr active 在 mon-0）+ 3 OSD host × 3 OSD（L8s_v3，**1 顆 1.7T NVMe 切 3 OSD ~100G**，叢集 900G）；pool `kubevirt` size3/min_size2/pg64；workers D8s_v5×2 有 `/dev/kvm`
- **關鍵發現①**：cephadm autotune 把 `osd_memory_target` 抬到 **15.7G/OSD**——已修正：autotune=false、移除 host 級覆寫、釘回預設 **4294967296（4G）**（`memory-target-fix.txt` 有 verify 輸出）。E-21 的 A/B 就以 4G/8G 對照。
- **關鍵發現②**：`osd_mclock_max_capacity_iops_ssd` 實測值 ~**6000 IOPS/OSD**（osd.0=6242、osd.1=5992…）——mClock 用它算配額，這就是本環境 OSD 端天花板的量級（3 OSD 共享單 NVMe 的結果）。解讀高 QD 實驗時以此為分母。
- mClock profile 未顯式設定（= 預設 balanced）；`osd_op_num_shards_ssd` 未顯式設定（= 預設 8）。
- Kyverno `rbd-block-disk-group` policy 存在（RBD 裸裝置 GID 6 workaround）。
- RTT（cp→3 OSD 私網）：均 <1ms（詳 snapshot）。

## Baseline 生效驗證 — done（繼承錨點 T3 實錘）

- Bundle：`results/E-00-baseline-verify/qemu-cmdline.txt`
- data 盤 blockdev = `{"driver":"host_device","filename":"/dev/data","aio":"native",...,"cache":{"direct":true,"no-flush":false}}`、device `write-cache:"on"`、**json 無 num-queues 欄**（=AUTO）→ **「全留空 = cache=none + io=native + queues=vCPU」在 v1.5.0 真機成立**。
- guest `/sys/block/vdb/mq` = **4**（=vCPU 數）——H-026/繼承錨點 T3 confirmed。
- QEMU 行程名 = **`qemu-kvm`**（pid 84，非 qemu-system）——RUNBOOK 已修正 pgrep。
- host krbd 預設讀值：`nr_requests=128`、`read_ahead_kb=128`、scheduler=`none`（rbd0）。

## E-03 三邊界觀測驗證 — done（verdict: confirmed）

- Bundle：`results/E-03/<ts>/`（guest-iostat / host-iostat / qmp-domblkstat / guest-mq-count）
- 同一 60s 窗（E-01 round-1 的 rr 負載中）：guest vdb **27005 r/s** vs host rbd0 **26998 r/s**（差 0.03% ≪ 10% 判準）；`virsh domblkstat` 差分可用（rd_req 增量/60 與 iostat 同量級）。
- 虛擬化稅初值：guest await 1.12ms − host await 1.03ms ≈ **0.09ms/op**（qd32 高載時）。
- 三邊界收集管線全部自動化可用 → 後續實驗照此收。

## E-01 噪音帶 — done（H-008 **violated**：Azure 專屬叢集比 PVE 生產穩一個數量級）

- Bundle：`results/E-01/<ts>/e01/round-{1..5}-A/`（n=5 連跑；deviation：未跨 2h 時段）
- **IOPS CoV 0.4–2.0%**（v2 PVE 4k qd1 讀是 23.4%）；p99 CoV 0.5–7.9%；p999 除 sw-1m（35.2%）外 ≤9%。
- band.json（git 追蹤，`band = max(2×CoV, 5%)`）：多數 metric 判準落在 5%；sw-1m p999 判準 70%（seq write 尾端本質性抖，該 metric 幾乎只能出 indistinguishable——誠實限制）。
- **gen-1 baseline 錨點數字**：rr qd1/8/32 = **968 / 8458 / 26771** IOPS；rw = **597 / 5322 / 14751**；
  seq read/write = **2838 / 1233 MiB/s**。rr-qd1 p50=0.97ms、rw-qd1 p50=1.63ms。
- p999 樣本數規則生效：qd1 pattern（58k/36k 樣本 < 1e5）不報 p999。
- 對照 mClock 天花板 9×6000=54k：rr-qd32 已用到 27k（50%）；單 VM 單盤打不滿叢集。

## E-02 host 層天花板／虛擬化稅 — done

- Bundle：`results/E-02/<ts>/e02/`（k8s-1 直接 map /dev/rbd0，n=3；同 pool 新 image，非 guest 那顆——placement 差異已知）
- **虛擬化稅（host 相對 guest 的優勢）**：rr-qd32 **+36.7%**（26771→36602）、rr-qd8 +17.4%、rw-qd1 +11.9%、rw-qd8 +11.6%、rr-qd1 +9.0%；**rw-qd32 +4.7%、seq read/write +2.7%/+1.2% = indistinguishable**。
- 解讀：虛擬層（virtio+QEMU）的代價集中在高並行小塊隨機讀；寫側與大塊頻寬瓶頸在 ceph 端，虛擬層幾乎免費。rr-qd32 的 36.7% 缺口是 E-13（多 queue）/E-14（IOThread）最該追的 headroom。
- verdict 檔：`results/E-02/<ts>/verdict-vs-guest.txt`；throwaway image/key 已清理，HEALTH_OK。
