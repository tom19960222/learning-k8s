# STATE — kubevirt-rbd-tuning 進度與 deviation log

> 接手的 agent：讀完 HYPOTHESES.md → EXPERIMENT-PLAN.md → RUNBOOK.md 後，從本檔最後一行繼續。
> 每完成一步 append 一行；偏離 runbook 的決定記進 Deviation log。

## 進度

- 2026-07-07 Frame/Enumerate/Gate1 完成；P0（H-001/002/003/006/020）T1 查證完成並回填 HYPOTHESES.md。
- 2026-07-07 Azure quota 實查：全 region cores=65、LSv3=65；主案 L32s_v3 需調 quota（見 AZURE-ENV-SPEC）。
- 2026-07-08 RUNBOOK.md 完成。
- 2026-07-08 環境交付（cyshih-kubevirt-ceph-lab @japanwest）並體檢通過：3mon+9osd HEALTH_OK、
  kubevirt v1.5.0 ✓、ceph-csi v3.14.0 ✓、kernel 6.8 ✓、RWX Block PVC 實測 Bound ✓、
  cephadm systemd unit 形式 ✓（E-32/35/36 注入手法可用）。RUNBOOK §0 已填實際值。
  **下一步：建 tools/ + manifests/（RUNBOOK §2.5/§3）→ E-00 正式盤點。**
- 2026-07-08 tools/fio_stats.py + manifests/{01-pvc,02-vm} 建立（pubkey=azure-lab）。
- 2026-07-08 `E-00 done results/E-00/<ts>/ — 版本全對齊；修正 autotune osd_memory_target 15.7G→4G（記入 SUMMARY）；mClock 天花板 ~6k IOPS/OSD`。
  **執行約束（使用者 2026-07-08 指示）：az CLI 對共享帳號零 write——E-31/E-41 的 VM stop/start 由使用者執行。**
  **下一步：kubectl 建 vmtest ns + PVC + VM → pre-fill → E-01。**
- 2026-07-08 baseline VM 建立：ns vmtest、PVC data-baseline(RWX Block 16Gi ceph-rbd) Bound、
  VMI Running @cyshih-k8s-2、IP 10.244.1.92、LIVE-MIGRATABLE=True、guest fio 3.36/vdb 16G。
  guest 連線 = ProxyCommand 經 cp（ProxyJump 跳板段吃不到 key，deviation 已知；函式見下）。
- 2026-07-08 **E-01 已點火**：guest 上 `nohup bash e01.sh`（pid 1930）＝prefill + 5 輪矩陣，
  預計 ~60min；進度看 guest `/home/ubuntu/e01/status`（ALL-DONE 為完成）。
  接手方式：`vmssh 'cat e01/status'` → 完成後把 `/home/ubuntu/e01/` scp 回
  `results/E-01/<ts>/` → `python3 tools/fio_stats.py cov results/E-01/<ts>` 產 band.json（放本目錄，git 追蹤）。
  vmssh 函式（zsh 注意 `g` 是 alias 不可用）：
  `vmssh(){ ssh -i ~/.ssh/azure-lab -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o ProxyCommand='ssh -i ~/.ssh/azure-lab -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -W %h:%p azureuser@20.89.248.121' ubuntu@10.244.1.92 "$@"; }`
  Deviation：E-01 五輪連跑未跨 2h 時段（rate limit 考量）；後續任一實驗前跑 sentinel 輪可補驗時段漂移。
- （之後每行格式：`E-XX done <bundle path> — <一句話結論>`）

## 待辦（環境到手後依序）

1. RUNBOOK §0 填 IP/FSID；確認 `.gitignore` 含 `experiments/kubevirt-rbd-tuning/results/`。
2. 建 `tools/fio_stats.py`（RUNBOOK §2.5 原文）與 `manifests/`（§3）。
3. E-00 → E-01（產 band.json，git 追蹤）→ E-02 → E-03 → E-50/51/52 → E-1x → E-3x → E-39~42 → 彙整。
4. Gate 3 停點：全部跑完後等使用者 triage 才寫 MDX。

## Deviation log

- E-13 預先修正：KubeVirt 無法強制 queues=1，實驗降級為 no-op 驗證（RUNBOOK §4 E-13，設計期已知）。
- E-20 預設走 host 層對照（csi 靜態供應繁瑣），VM 層 optional。
- 環境 vs 規格書（2026-07-08 體檢，全部可接受）：
  - OSD = **L8s_v3 fallback**（1 實體 NVMe 切 3 OSD，非 L32s 主案）→ E-22 與 per-OSD 隔離類解讀力降，同碟鄰居效應寫結論時標註。
  - ceph 19.2.4（pinned 19.2.3，patch 版差）；Ubuntu 22.04（kernel 6.8-azure，krbd 對齊不受影響）；k8s 1.32.13。
  - CSI = 原生 ceph-csi（非 Rook external）；SC `ceph-rbd` 的 imageFeatures 只有 `layering`；
    RUNBOOK §3 的 SC 模板 secret 名改用 `csi-rbd-secret@ceph-csi-rbd`、clusterID=FSID。
  - guest key 用 `~/.ssh/azure-lab.pub`（非 repo key）；kubectl 可直接於 Mac 執行。
  - 生命週期歸 azure-iac-lab repo 的 make（stop=清 NVMe+自動重建）；共享訂閱只准動 cyshih-*。

- 2026-07-08 MDX 專題頁上線：`next-site/content/vm-storage-perf/features/rbd-io-production-tuning.mdx`
  （P0 四分類+三 violated 直覺+已完成 T3；實驗回填表留空——每完成一個實驗要同步回填此頁）。
  slug 已入 projects.ts features+featureGroups(效能調教)。quiz 未加（等實驗數字齊再出題）。
- 2026-07-08 `E-01 done results/E-01/<ts>/ — H-008 violated：IOPS CoV 0.4–2.0%（判準多為 5%），band.json 已產出（git 追蹤）；baseline 錨點 rr 968/8458/26771、rw 597/5322/14751 IOPS、seq 2838/1233 MiB/s；頁面表已回填。下一步 E-02（host 天花板，worker k8s-1）。`
- 2026-07-08 **E-02 已點火**：worker k8s-1（20.63.217.150）nohup e02.sh（pid 8618）＝
  /dev/rbd0（kubevirt/ioperf-host，client.hosttest）prefill+3 輪矩陣，~35min；
  進度 `tail -1 /home/azureuser/e02/status`。完成後：scp e02/ → results/E-02/<ts>/ →
  fio_stats.py cmp <E-01輪> <E-02輪> band.json 算虛擬化稅 → 清理：worker `sudo rbd unmap /dev/rbd0`、
  mon `sudo rbd rm kubevirt/ioperf-host && sudo ceph auth rm client.hosttest`。
