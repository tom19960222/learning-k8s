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
