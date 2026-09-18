#!/usr/bin/env python3
"""
Kiosk Control & OS Management HTTP/REST Server
Provides static asset delivery and REST API for hardware/system control.
Zero external dependencies (pure Python 3 standard library).
"""

import http.server
import json
import os
import re
import socket
import subprocess
import sys
import urllib.parse

PORT = int(os.environ.get("LOCAL_SERVER_PORT", "8080"))
DOC_ROOT = os.environ.get("CONTENT_DIR", os.getcwd())

def run_cmd(cmd, timeout=8):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
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

    cpu_temp = "N/A"
    try:
        if os.path.exists("/sys/class/thermal/thermal_zone0/temp"):
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                temp_raw = float(f.read().strip())
                cpu_temp = f"{temp_raw / 1000.0:.1f}°C"
    except Exception:
        pass

    disk_info = "N/A"
    try:
        ok, out = run_cmd("df -h / | awk 'NR==2 {print $3 \" / \" $2 \" (\" $5 \" used)\"}'")
        if ok:
            disk_info = out
    except Exception:
        pass

    active_wifi = "Disconnected"
    try:
        ok, out = run_cmd("nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2")
        if ok and out:
            active_wifi = out
    except Exception:
        pass

    return {
        "hostname": socket.gethostname(),
        "ip": ip,
        "uptime": uptime_str,
        "cpu_load": load_str,
        "cpu_temp": cpu_temp,
        "memory": ram_used,
        "disk": disk_info,
        "wifi": active_wifi,
        "display": os.environ.get("DISPLAY", ":0")
    }

def scan_wifi_networks():
    networks = []
    ok, out = run_cmd("sudo nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list --rescan yes 2>/dev/null")
    if ok and out:
        seen = set()
        for line in out.splitlines():
            parts = line.split(":")
            if len(parts) >= 2 and parts[0].strip():
                ssid = parts[0].strip()
                if ssid not in seen:
                    seen.add(ssid)
                    signal = parts[1].strip() if len(parts) > 1 else "?"
                    security = parts[2].strip() if len(parts) > 2 and parts[2].strip() else "Open"
                    networks.append({"ssid": ssid, "signal": signal, "security": security})
    else:
        ok, out = run_cmd("sudo iwlist scan 2>/dev/null | grep -E 'ESSID|Quality'")
        if ok and out:
            for line in out.splitlines():
                if "ESSID:" in line:
                    m = re.search(r'ESSID:"([^"]+)"', line)
                    if m and m.group(1):
                        networks.append({"ssid": m.group(1), "signal": "Good", "security": "WPA2"})
    return networks

def get_display_modes():
    modes = []
    current = "auto"
    ok, out = run_cmd("DISPLAY=:0 xrandr 2>/dev/null")
    if ok and out:
        for line in out.splitlines():
            m = re.search(r'^\s+(\d+x\d+)\s+', line)
            if m:
                mode_str = m.group(1)
                if mode_str not in modes:
                    modes.append(mode_str)
                if "*" in line:
                    current = mode_str
    return {"current": current, "available": modes}

class KioskHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DOC_ROOT, **kwargs)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/system/stats":
            self.send_json(200, get_system_stats())
            return
        elif path == "/api/system/wifi/scan":
            networks = scan_wifi_networks()
            self.send_json(200, {"networks": networks})
            return
        elif path == "/api/system/resolution":
            self.send_json(200, get_display_modes())
            return
        elif path == "/api/system/disks":
            ok, out = run_cmd("lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS && echo '---' && df -h")
            self.send_json(200, {"disks": out if ok else "Unavailable"})
            return

        return super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        post_raw = self.rfile.read(length).decode("utf-8") if length > 0 else ""
        
        post_json = {}
        if post_raw:
            try:
                post_json = json.loads(post_raw)
            except Exception:
                pass

        params = urllib.parse.parse_qs(parsed.query)
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
            rot = post_json.get("dir") or params.get("dir", ["normal"])[0]
            if rot in ["normal", "left", "right", "inverted"]:
                run_cmd(f"{env_display} xrandr -o {rot}")
                response_data["message"] = f"Display rotated to {rot}"
        elif path == "/api/system/resolution":
            mode = post_json.get("mode") or params.get("mode", ["auto"])[0]
            if mode == "auto":
                run_cmd(f"{env_display} xrandr --auto")
            else:
                ok, out = run_cmd(f"{env_display} xrandr -q | grep ' connected' | head -n 1 | awk '{{print $1}}'")
                primary = out if ok and out else ""
                if primary:
                    if mode == "1920x1080":
                        run_cmd(f"{env_display} xrandr --newmode '1920x1080_60.00' 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync 2>/dev/null; {env_display} xrandr --addmode {primary} '1920x1080_60.00' 2>/dev/null")
                        ok_m, _ = run_cmd(f"{env_display} xrandr --output {primary} --mode 1920x1080 2>/dev/null || {env_display} xrandr --output {primary} --mode '1920x1080_60.00' 2>/dev/null")
                        if not ok_m:
                            run_cmd(f"{env_display} xrandr --output {primary} --auto && {env_display} xrandr --output {primary} --scale-from 1920x1080")
                    else:
                        run_cmd(f"{env_display} xrandr --output {primary} --mode {mode}")
                else:
                    run_cmd(f"{env_display} xrandr -s {mode}")
            response_data["message"] = f"Resolution switched to {mode}"
        elif path == "/api/system/volume":
            action = post_json.get("action") or params.get("action", ["toggle"])[0]
            if action == "up":
                run_cmd("amixer sset Master 5%+ 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ +5% 2>/dev/null")
            elif action == "down":
                run_cmd("amixer sset Master 5%- 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ -5% 2>/dev/null")
            elif action == "mute":
                run_cmd("amixer sset Master mute 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 1 2>/dev/null")
            elif action == "unmute":
                run_cmd("amixer sset Master unmute 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null")
            elif str(action).isdigit() or str(action).endswith("%"):
                val = action if str(action).endswith("%") else f"{action}%"
                run_cmd(f"amixer sset Master {val} 2>/dev/null || pactl set-sink-volume @DEFAULT_SINK@ {val} 2>/dev/null")
            else:
                run_cmd("amixer sset Master toggle 2>/dev/null || pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null")
            response_data["message"] = f"Volume {action} executed"
        elif path == "/api/system/wifi/connect":
            ssid = post_json.get("ssid", "").strip()
            password = post_json.get("password", "").strip()
            if not ssid:
                self.send_json(400, {"status": "error", "message": "SSID is required"})
                return
            cmd = f'sudo nmcli dev wifi connect "{ssid}"'
            if password:
                cmd += f' password "{password}"'
            ok, out = run_cmd(cmd, timeout=15)
            response_data["status"] = "ok" if ok else "error"
            response_data["message"] = out
        elif path == "/api/system/terminal":
            subprocess.Popen("DISPLAY=:0 xterm -fa 'Monospace' -fs 14 -bg '#0b0f19' -fg '#f3f4f6' -geometry 100x30 &", shell=True)
            response_data["message"] = "Terminal window launched on display"
        elif path == "/api/system/exec":
            cmd = post_json.get("cmd") or params.get("cmd", [""])[0]
            if not cmd.strip():
                self.send_json(400, {"status": "error", "message": "Command is required"})
                return
            ok, out = run_cmd(cmd, timeout=12)
            response_data["exit_code"] = 0 if ok else 1
            response_data["output"] = out
        else:
            self.send_response(404)
            self.end_headers()
            return

        self.send_json(200, response_data)

    def send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    os.chdir(DOC_ROOT)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), KioskHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
