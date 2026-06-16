# soak verdict: PASS

| 判準 | 實測 | 結果 |
|---|---|---|
| ping（jitter 注入下僅供參考） | 540273 tx / 540267 rx / lost 6 | ✅ |
| step 事件 ≤ 0（只計 |jump| ≥ 50ms） | 0 筆 | ✅ |
| lease sentinel 0 miss/backward | miss=0 backward=0 | ✅ |
| journal 無 error | 0 行 | ✅ |
| offset 滾動中位數(w=31) < 50ms | peak |median| = 47.0ms（raw peak 50ms = 探針 jitter 雜訊，7202 樣本） | ✅ |
