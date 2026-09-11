#!/usr/bin/env python3
"""
Kiosk Control & HTTP Server
Provides static asset delivery and REST API for hardware/system control.
Zero external dependencies (pure Python 3 standard library).
"""

import http.server
import json
import os
import socket
import subprocess
import sys
import urllib.parse

PORT = int(os.environ.get("LOCAL_SERVER_PORT", "8080"))
DOC_ROOT = os.environ.get("CONTENT_DIR", os.getcwd())

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return res.returncode == 0, res.stdout.strip() or res.stderr.strip()
    except Exception as e:
        return False, str(e)

def get_system_stats():
    ip = "127.0.0.1"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception:
        pass

    uptime_str = "Unknown"
    try:
        with open("/proc/uptime", "r") as f:
            total_sec = float(f.readline().split()[0])
            hrs = int(total_sec // 3600)
            mins = int((total_sec % 3600) // 60)
            uptime_str = f"{hrs}h {mins}m"
    except Exception:
        pass

    load_str = "Unknown"
    try:
        with open("/proc/loadavg", "r") as f:
            load_str = f.readline().split()[0]
    except Exception:
        pass

    ram_used = "Unknown"
    try:
        ok, out = run_cmd("free -m | awk '/Mem:/ {print $3 \"MB / \" $2 \"MB\"}'")
        if ok:
            ram_used = out
    except Exception:
        pass

    return {
        "hostname": socket.gethostname(),
        "ip": ip,
        "uptime": uptime_str,
        "cpu_load": load_str,
        "memory": ram_used,
        "display": os.environ.get("DISPLAY", ":0")
    }

class KioskHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DOC_ROOT, **kwargs)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/system/stats":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            stats = get_system_stats()
            self.wfile.write(json.dumps(stats).encode("utf-8"))
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(length).decode("utf-8") if length > 0 else ""
        
        response_data = {"status": "ok"}
        env_display = "DISPLAY=:0 "

        if path == "/api/system/reboot":
            subprocess.Popen("sleep 1 && (sudo systemctl reboot || sudo reboot || reboot)", shell=True)
            response_data["message"] = "Reboot initiated"
        elif path == "/api/system/poweroff":
            subprocess.Popen("sleep 1 && (sudo systemctl poweroff || sudo poweroff || poweroff)", shell=True)
            response_data["message"] = "Shutdown initiated"
        elif path == "/api/system/restart-browser":
            subprocess.Popen("pkill -9 chromium", shell=True)
            response_data["message"] = "Browser restarting"
        elif path == "/api/system/screen-off":
            run_cmd(f"{env_display} xset dpms force off")
            response_data["message"] = "Display power turned off"
        elif path == "/api/system/screen-on":
            run_cmd(f"{env_display} xset dpms force on")
            response_data["message"] = "Display power turned on"
        elif path == "/api/system/rotate":
            params = urllib.parse.parse_qs(parsed.query)
            rot = params.get("dir", ["normal"])[0]
            if rot in ["normal", "left", "right", "inverted"]:
                run_cmd(f"{env_display} xrandr -o {rot}")
                response_data["message"] = f"Display rotated to {rot}"
        elif path == "/api/system/volume":
            params = urllib.parse.parse_qs(parsed.query)
            action = params.get("action", ["toggle"])[0]
            if action == "up":
                run_cmd("amixer sset Master 5%+")
            elif action == "down":
                run_cmd("amixer sset Master 5%-")
            else:
                run_cmd("amixer sset Master toggle")
            response_data["message"] = f"Volume {action} executed"
        else:
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(response_data).encode("utf-8"))

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    os.chdir(DOC_ROOT)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), KioskHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
