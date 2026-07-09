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
- 2026-07-08 `E-02 done results/E-02/<ts>/ — 虛擬化稅：rr-qd32 +36.7%、qd1/qd8 +9~17%、seq/rw-qd32 帶內；throwaway image/key 已清；頁面已回填`
- 2026-07-08 **E-10 已點火**（背景 orchestrator：`tools/e10-orchestrator.sh <bundle>`，~2h）：
  cache A/wt/wb 交錯 ×3、每次切換 stop/start + cmdline 生效斷言（A:direct=true,wc=on／wt:false,off／wb:false,on）、
  containerDisk 重啟重置已處理（cloud-init --wait + 重推 run_matrix.sh）。冪等：中斷後同指令重跑會跳過已完成 round。
  完成後：fio_stats.py cmp <A輪> <wt輪|wb輪> band.json → verdict.md → 回填 SUMMARY/頁面 → 收尾已自動回 baseline。
- 2026-07-08 `E-10 done results/E-10/20260708-015243 — H-004 confirmed（wb p999 +2064%、1.5~3.5s stall；wt 寫側嚴格劣化）；⚠cache-regime 陷阱：非 direct 讀側=host RAM（16G 盤<32G RAM），讀增益不可移植`
- 2026-07-08 **E-12 已點火**（背景 `tools/e12-orchestrator.sh`，io native vs threads 交錯×3，~75min；斷言 aio 欄位）。
- 2026-07-08 `E-12 done results/E-12/<ts> — prediction violated：threads 不輸 native（rr-qd32 +12.4%/p99 −7.2%），其餘全帶內；維持預設。未收 QEMU schedstat（deviation）`
- 2026-07-08 **E-14 已點火**（`tools/e14-orchestrator.sh`，dedicatedIOThread on/off 交錯×3；斷言 ua-data device 的 iothread 欄位）。單盤輪先跑；雙盤輪（獨佔主場）視結果加測。
- 2026-07-08 `E-14 done results/E-14/<ts> — 單盤 dedicatedIOThread 無感（confirmed）；收不回 rr-qd32 36.7% 稅；雙盤輪列 P3`
- 2026-07-08 **E-30 已點火**（`tools/e30-run.sh <bundle> <guest-ip> 3`，degraded 第一格：stop osd.3 →750s（含 600s out+backfill 開始）→ 回復；guest dg 負載 rw-qd8+rr-qd1 各 1s 粒度 lat log；health.jsonl 5s 粒度）。分析時對齊 timeline.txt 的 epoch 戳記。
- 2026-07-08 `E-30 done results/E-30/<ts> — down 未 out 完全無感（=baseline）；auto-out 後 backfill 是傷害視窗（rr-qd1 mean ×24、max 1.01s；rw max 76ms）；re-in recovery rw max 309ms；全自癒無 guest 症狀。健康碼 OSD_DOWN/PG_AVAILABILITY/PG_DEGRADED`
- 2026-07-08 **E-39 已點火**（`tools/e39-run.sh`：60G scratch image 加大 backfill 量→兩次獨立注入
  balanced vs high_client_ops，手動 `osd out` 立即觸發 backfill，各量 240s；status.jsonl 含 recovery 速率；
  結束自動還原 profile 預設並刪 config）。scratch image `kubevirt/ioperf-fill` 60G 保留供 E-31/E-34 重用，最後清理時 `rbd rm`。
- 2026-07-08 `E-42+E-50 done results/E-42/<ts> — migration IO 零中斷（1s 窗最差 8ms）；H-001 T3 實錘（RestartRequired 出現/migration 不套用/revert 不清條件）；mig-3 cmdline 樣本無效（pod race）`
- 2026-07-08 **E-36 已點火**（`tools/e36-run.sh <bundle> 10.244.1.195 8 0`：t30 盤（SC ceph-rbd-t30，osd_request_timeout=30 已驗 config_info）vs baseline 盤；停 PG 2.5 acting 的 osd.8+osd.0 → min_size 不滿 300s → 回復。VM 現有第 4 顆盤 datat30/PVC data-t30——實驗後保留或清理見 E-36 收尾）。
- 2026-07-08 E-36 首跑踩雷：`$OB（` 全形括號吃進變數名 → unbound（CLAUDE.md 已載明的 bash+CJK 標點雷，
  自家 runbook 腳本也要過 `${var}` 檢查）。已修（tools/e36-run.sh），重新點火。
- 2026-07-08 E-36 二跑無效：probe 的 dd 偏移沒 4k 對齊 → O_DIRECT 全 EINVAL（教訓：O_DIRECT probe 偏移必須 block 對齊）。
  已修（stride 改成 4k 的倍數）三跑中。**殘留線索**：二跑中 t30 盤一筆對齊寫入 blocked 311s
  ——若三跑重現，H-032（osd_request_timeout=30 應 30s abort）部分 violated，機制要回 T1 重查
  （懷疑：inactive PG 的 request 可能卡在 epoch barrier/paused 層，不在 handle_timeout 掃描的 o_requests 內）。
- 2026-07-08 `E-36 done results/E-36/<ts>（三跑）— H-032 **T3 violated**：osd_request_timeout=30 在 min_size 不滿情境不觸發
  （blocked 302.8s 無 abort 無 dmesg）；baseline 盤 blocked 293s 後自癒。機制矛盾開 H-034 追查
  （建議變體：連線層故障 vs PG inactive 對照）。頁面 osd_request_timeout 敘述已加 violated Callout。
  收尾狀態：VM 仍掛 4 顆盤（datat30 保留供 H-034 續用）；SC ceph-rbd-t30 保留。`
- 2026-07-08 **E-17 已點火**（`tools/e17-run.sh`，guest scheduler mq-deadline vs none 同 VM 交錯×3 免重啟，~65min；
  完成後 cmp grp 分組照舊：A=mq-deadline B=none）。
- **進度總覽（gen-1，截至此刻）**：done = E-00/01/02/03/10/12/14/30/36/39/42/50 + baseline-verify；
  running = E-17；**剩餘** = E-11(bus)/E-13(mq no-op)/E-15/16(CPU)/E-18(readahead)/E-19(qdepth,D類)/
  E-20(layout)/E-21(memory_target)/E-22(shards)/E-23(P3)/E-31~35+37~38(degraded 其餘)/E-40(crash)/
  E-41(需使用者 az stop)/E-43(P3)/E-51/52(部分證據已有)。orchestrator 模板齊全（e10/e12/e14 為 B 類模板、
  e17 為 A 類模板、e30/e36/e39 為注入模板），接手 agent 照模板換 patch/斷言即可。
- 2026-07-08 `E-17 done results/E-17/<ts> — none 優於 mq-deadline（seq +30~40%、rr-qd32 p99 −7.7%）；預設已是 none=檢查清單項。⚠實測到跨實驗漂移（sr-1m 對 E-01 -19%）——後續 E-1x 前建議跑 sentinel 輪`
- 2026-07-08 **E-18 已點火**（`tools/e18-run.sh`，readahead 128/512/4096 ×3 輪精簡矩陣 sr-1m/sr4k/rr-qd1，~40min；
  分析注意：mini matrix 只有 3 pattern，cmp 時 band.json 缺 sr4k-qd1 條目會用預設 10% band）。
- 2026-07-08 `E-18 done results/E-18/<ts> — 全檔位 indistinguishable（機制必然：O_DIRECT 不經 page cache，readahead 非旋鈕）；buffered 變體 P3 不追`
- **共享 NVMe 適足性裁定（使用者問答，2026-07-08）**：1 NVMe 切 3 OSD 對本 charter 夠用
  （噪音 0.4-2%、daemon 層注入不受影響）；例外=E-22 與媒體隔離類（解讀力打折）、
  E-30 的 ×24 倍率可能被同碟效應放大（機制成立、倍率環境綁定——頁面要標註）。
  若要補：跑完後單開一台 L32s_v3 數小時做 E-22 對照即可，不用整組重建。
- 2026-07-08 **改派 Sonnet subagent 執行**（使用者授權，省主線 rate limit）：第一棒 = E-13 + E-21
  （序列執行，subagent 自行記錄/回填/commit；主線只派工與抽查）。同時段主線不碰叢集。
- 2026-07-08 `E-13 done results/E-13/20260708-095032 — confirmed：blockMultiQueue 是 no-op（兩變體 guest mq 都=4、cmdline 唯一差=mq 顯式寫 num-queues:4，QEMU AUTO 本就給 4）；fio 23/29 帶內，超帶項全歸因 drift/spiky-max（verdict.md 照實列）；頁面已回填。下一步 E-21。`
- 2026-07-08 **使用者裁示：全自動接力，一棒完成直接派下一棒不等人**。派工 queue（固定順序，
  每棒 = 一個 Sonnet subagent，序列執行、自行記錄回填 commit push、FATAL 才停）：
  1. （進行中）E-13 收尾 + E-21
  2. E-11（bus=scsi；⚠scsi 變體 guest 裝置名變 /dev/sda*，run_matrix filename 要跟著換；t30 盤仍是 virtio 不動）+ E-40（crash consistency：fio --verify=crc32c 寫入中 kill -9 qemu-kvm ×3 次 × {none,writeback}，verify_only 回讀+變體收尾回 baseline）
  3. E-37（deep-scrub 齊發 × osd_scrub_sleep 0 vs 0.1，degraded 模板）+ E-34（osd.3 週期 stop/start ×5 ± noout，degraded 模板）
  4. E-32（gray：systemctl set-property IOReadIOPSMax/IOWriteIOPSMax 限單 OSD，斷言 ceph health 全程 OK）+ E-33（worker 出口 tc netem loss 0.1%/0.5% 對 10.0.2.0/24，收尾 qdisc del）
  5. E-38（set-nearfull/full-ratio 到當前用量+ε 注入 full，觀察寫入 hang vs EIO，回復 0.85/0.95）+ E-51（改 SC 驗無效 + kubectl patch pv volumeAttributes 驗 escape hatch，被 API 拒也是結論）
  6. E-19（queue_depth 64/256 SC+PVC 變體，D 類，記 placement）+ E-15（CPU limit throttle：Guaranteed vs limits<vCPU，收 cgroup throttled_usec）
  7. E-35（mon 階梯：down 1 觀察→down 2 quorum 失→疊 osd kill→systemctl 恢復；⚠quorum 失時 ceph CLI 會 hang，恢復動作全走 systemctl）+ E-22（shards 16 rolling restart，rolling 全程收 client p99 時序）
  排除：E-31/E-41（需使用者 az）、E-16（要改 kubelet 設定，等使用者在線）、E-20 host 層（P3）、E-23/E-43（P3）。
- 2026-07-09 `E-13 done`（subagent 已 commit dcfd58a）+ `E-21 done results/E-21/20260708-153326 — indistinguishable（16G 盤 vs 12G cache 已足）；RSS 8G→1.5G/4G→1.1G 證 runtime 生效；印證 E-00 釘 4G 的判斷`。
  ⚠ subagent 監聽器在 E-21 ALL-DONE 後死亡未收尾，主線補記錄。**教訓：長時監聽 subagent 不穩 → 改「background bash 跑實驗 + 完成後主線派短命 subagent 只做收尾」**。
- 2026-07-09 **改回穩健模式**（subagent 監聽不可靠）：實驗用主線 nohup background bash 跑 +
  背景 poller 等 ALL-DONE/FATAL（=E-01~E-18 用過的可靠通知路徑），主線每次完成才醒來收尾。
  E-11 已點火（bus virtio vs scsi）。踩雷：orchestrator 內巢狀 awk 偵測裝置的跳脫被 mangle→
  空 filename→fio 秒 FATAL；已改成 run_matrix.sh 自偵測 16GiB 盤（免外部傳裝置名）。
- 2026-07-09 ⚠⚠ **重大事故與修復：多 session 共用同一 working tree、互相切 branch，導致本目錄 tracked 檔案從
  working tree 消失**（只剩 gitignored 的 results/）。診斷：我的 commit 全部安全（在 branch
  feat/ceph-mon-quorum-blind-spot，已 push origin，a462728 為最新），只是被別的 session 切走 checkout。
  **根治：開獨立 git worktree `/Users/ikaros/Documents/code/learning-k8s-kubevirt-wt`（branch
  feat/ceph-mon-quorum-blind-spot），之後所有 git 操作與實驗腳本都在此 worktree，不再碰共用 checkout。**
  接手 agent 注意：cd 到該 worktree 工作；results/ bundle 在 worktree 內（與主 checkout 的舊 results 分離）。
  E-11 heredoc 修正（scp re-push 偶發失敗 → 改每輪 heredoc 寫 run_matrix）也在此 worktree 重做並重啟。
- 2026-07-09 `E-11 done — bus IOPS indistinguishable、virtio-scsi 尾延遲較差（max +20~150%）；結合 H-006 → 無理由換 bus`。E-11 收尾在 worktree 完成。下一棒：E-40（crash consistency）。
- 2026-07-09 **E-40 延後**（crash-consistency 方法論有陷阱：O_DIRECT 在 writeback 下是否帶 FUA、
  fio verify_only 對未寫區也報錯——自動跑易出誤導資料，待使用者醒著確認方法論。tools/e40-run.sh 草稿已寫但未跑）。
- 2026-07-09 **E-37 已點火**（worktree，deep-scrub 齊發 × osd_scrub_sleep 0 vs 0.1，degraded 模板；
  兩段各 480s，結束自動 config rm 還原）。queue 順序微調：E-40→延後，改跑 E-37→E-34→…
- worktree 補記：node_modules 從主 checkout symlink（make validate 才過）；接手 agent 若 worktree 重建要重做此 symlink。
- 2026-07-09 `E-37 done — deep-scrub 確實跑（scrub 時戳在窗內）但 client 零擾動，scrub_sleep 兩檔無差。與 E-39 同模式：NVMe headroom 下 Ceph QoS 旋鈕不可分辨→合併結論「投資 headroom 而非 QoS 微調」`
- 2026-07-09 **E-34 已點火**（worktree，OSD flapping：osd.3 週期 stop60/start60 ×5 × noout on/off，~26min）。
  完成後接：E-32(gray)→E-33(netem)→E-38(pool full)→E-51(可調性)→E-19(qdepth)→E-15(cpu throttle)→E-35(mon 階梯)→E-22(shards)。
  **E-40 保留待使用者審方法論**（crash consistency）。E-31/E-41/E-16 需使用者（az/kubelet）。
- 2026-07-09 `E-34 done — flapping 傷害大（rr-qd1 p999 1146ms）；noout confirmed 砍 mean −43%/p999 −71%（→335ms）但不消 peering 尖峰。生產：flapping 立即 set noout 止血+查根因。與 E-30 合：控制 out 就控制大部分 down 傷害`
- 2026-07-09 `E-34 done`（commit 9a66746）。
- 2026-07-09 **E-32 已點火**（gray failure：osd.3=dm-0=252:0 systemd cgroup 限速 150 IOPS，~9min；
  斷言 ceph health 全程 OK=觀測盲區）。osd.3 device 對映：ceph osd metadata 3 → /dev/dm-0（cyshih-osd-1）。
- 2026-07-09 E-32 兩次踩雷後改法（記錄供接手）：gray failure 的 cgroup 磁碟限速在 cephadm/podman OSD **不可行**——
  (v1) dm-0(252:0) 限速：cgroup io.max 對 dm 裝置不咬；(v2) systemd unit cgroup 限速：ceph-osd 實際在
  podman 子 cgroup `libpod-payload-<hash>`（每次重啟變）、且 io controller 未必下放。**改用 tc netem 50ms
  延遲注入 osd host 網卡**（v3，一定生效）。osd.3 device 對映=dm-0/nvme0n1(259:0)@cyshih-osd-1。
- 2026-07-09 **E-32 v3 已點火**（netem 50ms on osd-1 eth0+eth1，~9min）。**使用者 rate limit 已回，仍全自動接力**。
- 2026-07-09 `E-32 v3 done — 一等發現：host +50ms gray 使 client 寫 ×40/讀 ×19，ceph health 全程 OK（觀測盲區 confirmed）；size=3 per-host replica → 一台慢 host 毒化全部寫入。生產：不能只看 ceph health，需 client p99+per-OSD latency+RTT 監控。回饋 ceph-alert`
- 2026-07-09 **E-33 已點火**（netem loss 0.1%/0.5% on osd-1，兩段各 ~11min）。
  剩餘 queue：E-33→E-38(pool full)→E-51(可調性)→E-19(qdepth)→E-15(cpu throttle)→E-35(mon 階梯)→E-22(shards)。
  E-40 待使用者審方法論；E-31/E-41/E-16 待使用者操作。
- 2026-07-09 `E-33 done — prediction violated：0.1/0.5% loss 對 client 幾乎無影響（TCP 快速重傳吸收，低RTT不觸發RTO）。跨實驗洞察：Ceph-on-TCP 延遲(E-32 ×40)遠比丟包(E-33 1.1×)致命→監控重心放 RTT`
- 2026-07-09 `E-38 done — nearfull 只告警不擋寫（v1 意外驗到）；full 下寫入 hang 96s 非 EIO，恢復後成功完成（confirmed H-022，同 min_size hang 型）。踩雷：full_ratio 要三個 ratio 依序設(nearfull<backfillfull<full)否則 out-of-order 被拒。生產：nearfull 是必須行動告警線`
- 2026-07-09 **E-51 已點火**（可調性真機：改 SC mapOptions（預期無效）vs patch PV volumeAttributes（escape hatch）；含 VM 重啟 ×3，~12min）。剩餘 queue：E-51→E-19(qdepth D類)→E-15(cpu throttle)→E-35(mon 階梯)→E-22(shards)。
- 2026-07-09 `E-51 done — patch PV volumeAttributes 被 API 拒（source immutable）→ mapOptions 無 escape hatch，H-002 T3 完整閉環，D 類=建置期定死坐實。host nr_requests 讀取回空(size比對未中)但非關鍵`
- 2026-07-09 **E-19 已點火**（queue_depth 64 vs 256，D類新 SC+PVC，各 3 輪 rr/rw qd1+qd32x4，~25min；含 cleanup 換回 baseline PVC + 刪變體 SC/PVC）。
  ⚠ 生效驗證 nr_requests 讀取用 /sys/block/rbdN/size==33554432 比對，E-51/E-19 都回空（node ssh 也偶逾時）——
  queue_depth 是否生效改由 fio 差異反推；接手 agent 若要修 host 驗證，先確認 rbd size 單位/多裝置問題。
- 2026-07-09 `E-19 done — H-009 部分 violated：queue_depth 256 高並行 +10~21% IOPS 且 p99 更好，qd1 零代價（預測的尾延遲懲罰不存在，因 cap 對低並行無影響）。純加分但 D 類建置期定死`
- 2026-07-09 **E-15 已點火**（CPU throttle H-018：Guaranteed(lim=4) vs throttled(lim=2)+guest stress-ng --cpu 4，量 fio p99.9+cgroup throttled_usec，~18min）。剩餘 queue：E-15→E-35(mon 階梯)→E-22(shards)。E-40/E-31/E-41/E-16 待使用者。
- 2026-07-09 `E-15 done — 強力 confirmed H-018：CPU limit<vCPU 使 p99 ×7.4（7.6→55.8ms）、IOPS 砍半、p50 不變。關鍵修正：門檻是 limit≥vCPU 數不是 QoS class（兩變體皆 Guaranteed）。catalog 缺的隱形旋鈕，最易誤設最難察覺`
- 2026-07-09 **E-35 延後**（同 E-40：mon quorum 全失是唯一可能 brick 整個 Azure 叢集的實驗，無人看管不做，留給使用者在線監督）。
- 2026-07-09 **E-22 已點火**（osd_op_num_shards 8 vs 16，C類；含兩次 rolling restart 帶 degraded 負載量 client 代價，~30min）。
  **自動 queue 到此為止**：E-22 完成後，剩餘全部需使用者（E-35 mon/E-40 crash/E-31 az node/E-41 az/E-16 kubelet）。
- 2026-07-09 `E-22 done — shards 8/16 效果 indistinguishable（8 已足，同 E-37/39 headroom 模式）；但 rolling restart 9 OSD 使 client qd1 讀 p99→1360ms（C類代價實錄）。改 startup 參數＝degraded 窗。**自動 queue 全部完成**`
- 2026-07-09 ===== 自動接力 queue 執行完畢。剩餘全需使用者監督：E-35(mon quorum)/E-40(crash consistency 方法論)/E-31(az node stop)/E-41(az node 硬斷 failover)/E-16(kubelet CPUManager)。下一步建議：使用者在線時做這 5 個 → 然後 Gate 3 收尾（HYPOTHESES 全 triage + 專題頁 quiz + 最終總結）=====
