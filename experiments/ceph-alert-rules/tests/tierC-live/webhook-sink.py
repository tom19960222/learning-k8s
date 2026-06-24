#!/usr/bin/env python3
"""Tier C webhook sink：記錄 Alertmanager 送來的 alert 與其 receiver（用 path 區分 /pager /slack）。
每收到一個 alert 就 append 一行：<receiver>\t<alertname>\t<key-label>\t<status> 到輸出檔。"""
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

OUTFILE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ceph-alert-sink.log"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9748


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        receiver = self.path.strip("/") or "root"
        try:
            data = json.loads(body)
            for a in data.get("alerts", []):
                lbl = a.get("labels", {})
                key = lbl.get("hostname") or lbl.get("ceph_daemon") or lbl.get("name") or "-"
                with open(OUTFILE, "a") as f:
                    f.write("%s\t%s\t%s\t%s\n" % (receiver, lbl.get("alertname", "-"), key, a.get("status", "-")))
        except Exception as e:  # noqa
            with open(OUTFILE, "a") as f:
                f.write("ERR\t%s\n" % e)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # 靜音
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
