#!/usr/bin/env python3
"""用法:
  fio_stats.py cov  <dir含多輪同variant>                        # E-01: 每 pattern 的 mean/CoV, 產 band.json
  fio_stats.py cmp  <A_rounds_dir> <B_rounds_dir> <band.json>   # A/B 比對出 verdict 表
band.json = {pattern: {metric: band_fraction}}
規則: band = max(2*CoV_E01, 0.05)。|relative_diff| > band → 有方向, 否則 indistinguishable。
p99.9 僅在樣本數(iops*60)>=1e5 時輸出。stall flag: clat max > 1e9 ns。"""
import json, sys, glob, statistics as st, os

def load(d):
    out = {}
    for f in glob.glob(os.path.join(d, '**', 'fio-*.json'), recursive=True):
        try:
            j = json.load(open(f))
        except Exception as e:
            print(f"WARN skip {f}: {e}", file=sys.stderr); continue
        job = j['jobs'][0]
        pat = os.path.basename(f)[4:-5]
        rw = 'read' if job['read']['iops'] > job['write']['iops'] else 'write'
        s = job[rw]; pct = s['clat_ns']['percentile']
        m = {'iops': s['iops'], 'p50': pct['50.000000'], 'p99': pct['99.000000'],
             'p999': pct['99.900000'], 'max': s['clat_ns']['max'], 'samples': s['iops'] * 60}
        if m['max'] > 1e9:
            print(f"STALL-FLAG {f}: clat max {m['max']/1e9:.2f}s", file=sys.stderr)
        out.setdefault(pat, []).append(m)
    return out

def cov(vals):
    m = st.mean(vals)
    return (st.stdev(vals) / m if len(vals) > 1 and m else 0)

if sys.argv[1] == 'cov':
    r = load(sys.argv[2]); band = {}
    for p, ms in sorted(r.items()):
        band[p] = {k: max(2 * cov([m[k] for m in ms]), 0.05) for k in ('iops', 'p99', 'p999')}
        line = ' '.join(f"{k}:mean={st.mean([m[k] for m in ms]):.0f},cov={cov([m[k] for m in ms]):.1%}"
                        for k in ('iops', 'p50', 'p99', 'p999'))
        print(f"{p:10s} n={len(ms)} {line}")
    json.dump(band, open('band.json', 'w'), indent=1)
    print('band.json written')
else:
    A, B = load(sys.argv[2]), load(sys.argv[3]); band = json.load(open(sys.argv[4]))
    for p in sorted(A):
        if p not in B: continue
        for k in ('iops', 'p99', 'p999', 'max'):
            if k == 'p999' and st.mean([m['samples'] for m in A[p]]) < 1e5: continue
            a = st.mean([m[k] for m in A[p]]); b = st.mean([m[k] for m in B[p]])
            d = (b - a) / a if a else 0; bd = band.get(p, {}).get(k, 0.10)
            v = 'indistinguishable' if abs(d) < bd else ('B_higher' if d > 0 else 'B_lower')
            print(f"{p:10s} {k:5s} A={a:14.0f} B={b:14.0f} diff={d:+8.1%} band={bd:5.0%} -> {v}")
