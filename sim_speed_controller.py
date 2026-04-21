#!/usr/bin/env python3
"""Lightweight HTTP API for dynamic Gazebo simulation speed control."""

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

WORLD = os.environ.get("GZ_WORLD_NAME", "default")
MIN_SPEED = 0.1
MAX_SPEED = 10.0
PORT = 9500

current_speed = float(os.environ.get("PX4_SIM_SPEED_FACTOR", "1.0"))


def set_gz_speed(factor):
    """Call gz service to update real_time_factor."""
    result = subprocess.run(
        [
            "gz", "service",
            "-s", f"/world/{WORLD}/set_physics",
            "--reqtype", "gz.msgs.Physics",
            "--reptype", "gz.msgs.Boolean",
            "--req", f"real_time_factor: {factor}",
            "--timeout", "5000",
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


class Handler(BaseHTTPRequestHandler):
    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json_response(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/sim/speed":
            self._json_response(200, {"speed_factor": current_speed, "world": WORLD})
        elif self.path == "/api/sim/health":
            self._json_response(200, {"status": "ok", "world": WORLD})
        else:
            self._json_response(404, {"error": "not found"})

    def do_POST(self):
        global current_speed
        if self.path != "/api/sim/speed":
            self._json_response(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
        except (json.JSONDecodeError, ValueError):
            self._json_response(400, {"error": "invalid JSON"})
            return

        factor = body.get("speed_factor")
        if factor is None:
            self._json_response(400, {"error": "missing speed_factor"})
            return

        try:
            factor = float(factor)
        except (TypeError, ValueError):
            self._json_response(400, {"error": "speed_factor must be a number"})
            return

        if not (MIN_SPEED <= factor <= MAX_SPEED):
            self._json_response(400, {"error": f"speed_factor must be between {MIN_SPEED} and {MAX_SPEED}"})
            return

        if set_gz_speed(factor):
            current_speed = factor
            self._json_response(200, {"success": True, "speed_factor": current_speed})
        else:
            self._json_response(502, {"error": "failed to set speed in Gazebo"})

    def log_message(self, format, *args):
        print(f"[sim_speed_controller] {args[0]}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[sim_speed_controller] Serving on port {PORT}, world={WORLD}, initial_speed={current_speed}")
    server.serve_forever()
