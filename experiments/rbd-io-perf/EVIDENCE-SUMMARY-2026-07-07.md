# rbd-io-perf Evidence Summary — 2026-07-07

Bundle 目錄在 `results/`（git-ignored）；本檔為索引。環境：pve3（PVE 9.0.11 / pve-qemu 10.1.2 / kernel 6.14.11-4-pve / ceph 19.2.3-pve2）、pool `ioperf`（ssd-only、size=2、osd.0+osd.8）、public net 1G（修線後）。

| 實驗 | 時間 | 注入 | Bundle | 結果 |
|---|---|---|---|---|
| E-00 preflight | 03:22 | read-only | `results/preflight/20260707-032234/` | snapshot 完成；fio 3.39 已裝（deb.debian.org 手動抓包）；VMID 1031-1039 空 |
| E-01 krbd-check | 03:22 | 自建 throwaway image + storage id，即刪 | （stdout 判定） | **krbd: usable**——features layering/exclusive-lock/object-map/fast-diff/deep-flatten 全過 kernel 6.14；雙軸成立（H-030 confirmed） |
| E-02 host ceiling | 03:23–04:2x | 自建 ioperf-ceiling 16G，測後刪 | `results/exp0/20260707-032324/` | n=3 全收；**寫側天花板災難級**（rw 4k qd1=33 IOPS、seqwrite 17.7 MB/s）；讀側 qd1 1126 / qd32 19.9k IOPS；seqread 202 MB/s > 1G 線速（H-034 雙峰得證）；libaio 高 QD 讀勝 io_uring 25.6%（**violated** 原「無差異」預期，機器判定入 bundle）；guardrail 未觸發（H-021 confirmed） |
| E-03 baseline | 08:08–09:2x | 建測試 VM 1031（virtio0 boot + virtio1 data 16G） | `results/baseline/20260707-080827/` | n=5 全收；噪音帶 qd32/seq 2.4–11%、qd1 讀 23.4%（雙峰）；**虛擬化稅≈0**（僅 qd1 讀 −30% 點估落帶內）；guest mq=4（H-026 T3 得證）；PVE 預設 direct:true+write-cache=on（H-033）。兩次 first-contact 失敗已修：cloud image 缺 qemu-guest-agent（cicustom snippet 解）、PVE9 agent 回傳裸 list |
| E-04 exp-axis（頭牌） | 09:26–10:5x | 自建 ioperf-axis 16G krbd 手動 map；A/B 交錯 n=3 | `results/exp-axis/20260707-092652/` | **krbd seqwrite +17.9% 超帶（violated「無差異」）**；讀側 krbd 均值 +7~17% 但 librbd CoV 20-22% 撐大噪音帶（krbd CoV 僅 5-6%——穩定性差異本身是發現）；rw qd32 兩軸相同（寫天花板主導）。機器判定入 bundle |
| E-05 cache 三方 | 11:18–13:45 | qm set cache=wt/wb，A/B 交錯 n=3 + buffered 診斷 | `results/exp1-cache-*/`、`results/exp1-buffered/` | librbd 軸機制全數命中：**writethrough rw-qd32 −68.7%**（confirmed）、**writeback rw-qd1 +6,871% / qd32 +219%**（rbd_cache 吸收，confirmed，附 correctness 警語）；buffered+fsync=1（31 IOPS）≈ direct（33）→ H-023 修正預測命中；讀側全帶內 |
| E-07 iothread | 13:49–15:0x | qm set iothread=1 vs 0，A/B n=3 | `results/exp2-iothread/20260707-134920/` | 全 pattern ➖ 帶內（單盤單流預期一致）；本輪背景負載大（CoV 33-55%），高噪音視窗 |
| E-08 queues | 14:58–16:11 | --args 強制 num-queues=1，A/B n=3 | `results/exp8-queues/20260707-145801/` | mq 4↔1 生效驗證 ✓；**單 queue rw-qd32 +27.3%（勉強超帶）**、numjobs4 +114%（A 側 CoV 56% 品質弱）——「多 queue 較好」violated，瓶頸在 ceph 時 vring 條數無從發揮 |
| E-11 sched | 16:11–17:12 | guest scheduler none vs 預設 | `results/exp11-sched/20260707-161113/` | 全帶內 ➖ |
| E-13 readahead | 17:12–18:44 | guest read_ahead_kb 0/128/4096 | `results/exp13-readahead/20260707-171244/` | 全帶內 ➖（ra0 −9% 恰在帶上；qd16 大塊 seqread 自帶 pipeline） |
| E-09 layout | 18:44 | — | — | **FAILED**：PVE storage 不能掛任意名稱 image（unable to parse rbd volume name）——需改手動 map + raw path，待補跑 |
| E-12 alloc_size | 18:45–20:23 | 手動 map alloc_size=4096/65536 | `results/exp12-allocsize/20260707-184501/` | 全帶內 ✅（「沒差」預測命中） |
| E-14 rxbounce | 20:23–21:57 | 手動 map rxbounce on/off | `results/exp14-rxbounce/20260707-202304/` | **dmesg 零 bad crc**（此 workload 不觸發；H-004 條件預測 null 分支成立）；on/off 帶內 ➖ |
| E-10 qdepth | 21:57–00:5x | 手動 map queue_depth=64/128/256 | `results/exp10-qdepth/20260707-215739/` | nr_requests 生效 ✓；全帶內 ➖；設計註記：矩陣 qd32 < 最小深度 64，此旋鈕在本 workload 無從約束（H-011 per-hctx 語意亦然） |
