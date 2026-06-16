# soak verdict: FAIL

| 判準 | 實測 | 結果 |
|---|---|---|
| ping（jitter 注入下僅供參考） | 628524 tx / 628519 rx / lost 5 | ✅ |
| step 事件 ≤ 0（只計 |jump| ≥ 50ms） | 0 筆 | ✅ |
| lease sentinel 0 miss/backward | miss=0 backward=0 | ✅ |
| journal 無 error | 0 行 | ✅ |
| offset 滾動中位數(w=31) < 50ms | peak |median| = 68.2ms（raw peak 98ms = 探針 jitter 雜訊，9001 樣本） | ❌ |
