# Evidence Summary — 2026-07-09（ceph-slow-ops-detection）

每列一個 run：scenario、注入方式、bundle 目錄（results/，gitignored——保留在本機）、結果。
`violated` = prediction 被推翻 = 有發現，不是執行失敗。

| Run | Scenario | 注入 | Bundle | Verdict | 備註 |
|---|---|---|---|---|---|
| 0 | e00（第一次，4MB 物件） | 無（純 16×4MB bench） | results/20260709-083626-e00-negative-control | （中止：pgrep 自匹配） | 意外產出 H-015 violated + H-023 confirmed 的觀測窗：9/9 OSD counter 全增、max lat 44.7s、SLOW_OPS 兩路一漏一 blip |

（後續 run 由各 scenario 補列）
