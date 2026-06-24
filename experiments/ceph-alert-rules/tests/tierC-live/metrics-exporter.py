#!/usr/bin/env python3
"""Tier C3 端到端用：一個假 ceph exporter，/metrics 吐出 osd-host-a 整台 down 的合成 metric。
讓真 Prometheus 抓進去、跑真 recording rule + alert，驗證它產出的 label 與 Tier A 斷言一致。"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9750
METRICS = b"""# TYPE ceph_osd_up untyped
ceph_osd_up{ceph_daemon="osd.0"} 0
ceph_osd_up{ceph_daemon="osd.1"} 0
# TYPE ceph_osd_metadata gauge
ceph_osd_metadata{ceph_daemon="osd.0",hostname="osd-host-a"} 1
ceph_osd_metadata{ceph_daemon="osd.1",hostname="osd-host-a"} 1
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(METRICS)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
