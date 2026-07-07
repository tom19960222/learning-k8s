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
