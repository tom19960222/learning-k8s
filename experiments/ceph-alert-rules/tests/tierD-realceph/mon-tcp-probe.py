#!/usr/bin/env python3
"""Out-of-band mon liveness probe（發現二的緩解）。

直接 TCP 連每台 mon 的 msgr2 port(3300)，匯出 `ceph_mon_tcp_up{mon,addr}` 0/1——
**完全不經過 mgr**。mgr 在 quorum 失守時會凍結它匯出的 ceph_mon_quorum_status；這支探針
是叢集外的獨立事實來源，mon 真的 down（port 關）就量得到。每次被 scrape 時即時探一輪。

用法：mon-tcp-probe.py <listen_port> name=ip name=ip ...
  例：mon-tcp-probe.py 9793 ceph-lab-mon-01=192.168.18.166 ceph-lab-mon-02=192.168.18.167 ceph-lab-mon-03=192.168.18.164

限制：偵測的是「mon process / port 可達」，不是「mon 在 quorum」。能抓 mon-down（mgr 凍結時的盲區），
但抓不到「所有 mon 都活著卻網路分區」這種更罕見的情況——那需要真的對每台跑 quorum_status。
"""
import sys
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9793
MONS = [tuple(a.split("=", 1)) for a in sys.argv[2:]]  # [(name, ip), ...]
MSGR2_PORT = 3300


def probe(ip):
    try:
        s = socket.create_connection((ip, MSGR2_PORT), timeout=2)
        s.close()
        return 1
    except Exception:
        return 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        lines = ["# HELP ceph_mon_tcp_up out-of-band TCP reachability of each mon msgr2 port",
                 "# TYPE ceph_mon_tcp_up gauge"]
        for name, ip in MONS:
            lines.append('ceph_mon_tcp_up{mon="%s",addr="%s"} %d' % (name, ip, probe(ip)))
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
