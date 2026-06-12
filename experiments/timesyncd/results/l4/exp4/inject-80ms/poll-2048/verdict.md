# soak verdict: PASS

| 判準 | 實測 | 結果 |
|---|---|---|
| ping 0 丟包 | 154723 tx / 154723 rx / lost 0 | ✅ |
| step 事件 ≤ 1（只計 |jump| ≥ 50ms） | 1 筆 | ✅ |
| lease sentinel 0 miss/backward | miss=0 backward=0 | ✅ |
| journal 無 error | 0 行 | ✅ |
