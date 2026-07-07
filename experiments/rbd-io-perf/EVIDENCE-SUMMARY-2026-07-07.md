# rbd-io-perf Evidence Summary — 2026-07-07

Bundle 目錄在 `results/`（git-ignored）；本檔為索引。環境：pve3（PVE 9.0.11 / pve-qemu 10.1.2 / kernel 6.14.11-4-pve / ceph 19.2.3-pve2）、pool `ioperf`（ssd-only、size=2、osd.0+osd.8）、public net 1G（修線後）。

| 實驗 | 時間 | 注入 | Bundle | 結果 |
|---|---|---|---|---|
| E-00 preflight | 03:22 | read-only | `results/preflight/20260707-032234/` | snapshot 完成；fio 3.39 已裝（deb.debian.org 手動抓包）；VMID 1031-1039 空 |
| E-01 krbd-check | 03:22 | 自建 throwaway image + storage id，即刪 | （stdout 判定） | **krbd: usable**——features layering/exclusive-lock/object-map/fast-diff/deep-flatten 全過 kernel 6.14；雙軸成立（H-030 confirmed） |
| E-02 host ceiling | 03:23–04:2x | 自建 ioperf-ceiling 16G，測後刪 | `results/exp0/20260707-032324/` | n=3 全收；**寫側天花板災難級**（rw 4k qd1=33 IOPS、seqwrite 17.7 MB/s）；讀側 qd1 1126 / qd32 19.9k IOPS；seqread 202 MB/s > 1G 線速（H-034 雙峰得證）；libaio 高 QD 讀勝 io_uring 25.6%（**violated** 原「無差異」預期，機器判定入 bundle）；guardrail 未觸發（H-021 confirmed） |
| E-03 baseline | 08:08–09:2x | 建測試 VM 1031（virtio0 boot + virtio1 data 16G） | `results/baseline/20260707-080827/` | n=5 全收；噪音帶 qd32/seq 2.4–11%、qd1 讀 23.4%（雙峰）；**虛擬化稅≈0**（僅 qd1 讀 −30% 點估落帶內）；guest mq=4（H-026 T3 得證）；PVE 預設 direct:true+write-cache=on（H-033）。兩次 first-contact 失敗已修：cloud image 缺 qemu-guest-agent（cicustom snippet 解）、PVE9 agent 回傳裸 list |
