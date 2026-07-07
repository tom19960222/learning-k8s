# STATE — kubevirt-rbd-tuning 進度與 deviation log

> 接手的 agent：讀完 HYPOTHESES.md → EXPERIMENT-PLAN.md → RUNBOOK.md 後，從本檔最後一行繼續。
> 每完成一步 append 一行；偏離 runbook 的決定記進 Deviation log。

## 進度

- 2026-07-07 Frame/Enumerate/Gate1 完成；P0（H-001/002/003/006/020）T1 查證完成並回填 HYPOTHESES.md。
- 2026-07-07 Azure quota 實查：全 region cores=65、LSv3=65；主案 L32s_v3 需調 quota（見 AZURE-ENV-SPEC）。
- 2026-07-08 RUNBOOK.md 完成。**下一步：等使用者交付環境 → 填 RUNBOOK §0 表格 → E-00。**
- （之後每行格式：`E-XX done <bundle path> — <一句話結論>`）

## 待辦（環境到手後依序）

1. RUNBOOK §0 填 IP/FSID；確認 `.gitignore` 含 `experiments/kubevirt-rbd-tuning/results/`。
2. 建 `tools/fio_stats.py`（RUNBOOK §2.5 原文）與 `manifests/`（§3）。
3. E-00 → E-01（產 band.json，git 追蹤）→ E-02 → E-03 → E-50/51/52 → E-1x → E-3x → E-39~42 → 彙整。
4. Gate 3 停點：全部跑完後等使用者 triage 才寫 MDX。

## Deviation log

- E-13 預先修正：KubeVirt 無法強制 queues=1，實驗降級為 no-op 驗證（RUNBOOK §4 E-13，設計期已知）。
- E-20 預設走 host 層對照（csi 靜態供應繁瑣），VM 層 optional。
