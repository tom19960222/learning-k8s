# exp5 — PollIntervalMaxSec 網路惡化耐受地圖

| tier | mode | poll | delay±jitter (ms) | loss (%) | peak \|offset\| | step | lease miss | verdict |
|---|---|---|---|---|---|---|---|---|
| a120 | asym | 256 | 120±0 | 0 | peak |median| = 74.3ms（raw peak 79ms = 探針 jitter 雜訊，7202 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| a200 | asym | 256 | 200±0 | 0 | peak |median| = 102.0ms（raw peak 113ms = 探針 jitter 雜訊，7202 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| a40 | asym | 256 | 40±0 | 0 | peak |median| = 20.0ms（raw peak 20ms = 探針 jitter 雜訊，7202 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| a80 | asym | 256 | 80±0 | 0 | peak |median| = 47.0ms（raw peak 50ms = 探針 jitter 雜訊，7202 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| c2048-j100 | sym | 2048 | 100±100 | 0 | peak |median| = 217.7ms（raw peak 278ms = 探針 jitter 雜訊，9001 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| c2048-j40 | sym | 2048 | 40±40 | 0 | peak |median| = 72.1ms（raw peak 100ms = 探針 jitter 雜訊，9001 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| clean | clean | 256 | 0±0 | 0 | peak |median| = 1.0ms（raw peak 3ms = 探針 jitter 雜訊，5402 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| j10 | sym | 256 | 10±10 | 0 | peak |median| = 44.0ms（raw peak 51ms = 探針 jitter 雜訊，9002 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| j100 | sym | 256 | 100±100 | 0 | peak |median| = 207.2ms（raw peak 291ms = 探針 jitter 雜訊，9001 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| j160 | sym | 256 | 160±160 | 0 | peak |median| = 275.4ms（raw peak 417ms = 探針 jitter 雜訊，9001 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| j250 | sym | 256 | 250±250 | 0 | peak |median| = 381.3ms（raw peak 518ms = 探針 jitter 雜訊，9001 樣本） | 1 筆 | miss=0 backward=0 | ❌ FAIL |
| j40 | sym | 256 | 40±40 | 0 | peak |median| = 68.2ms（raw peak 98ms = 探針 jitter 雜訊，9001 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
| loss10 | sym | 256 | 5±3 | 10 | peak |median| = 34.0ms（raw peak 36ms = 探針 jitter 雜訊，7340 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| loss30 | sym | 256 | 5±3 | 30 | peak |median| = 11.9ms（raw peak 468ms = 探針 jitter 雜訊，4355 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| loss50 | sym | 256 | 5±3 | 50 | peak |median| = 5.1ms（raw peak 475ms = 探針 jitter 雜訊，2138 樣本） | 0 筆 | miss=0 backward=0 | ✅ PASS |
| loss75 | sym | 256 | 5±3 | 75 | peak |median| = 60.0ms（raw peak 418ms = 探針 jitter 雜訊，5629 樣本） | 0 筆 | miss=0 backward=0 | ❌ FAIL |
