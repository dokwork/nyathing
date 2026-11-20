#!/usr/bin/env python3
"""Run one or more test animations through Nyathing's local API."""

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

runtime = os.environ.get("XDG_RUNTIME_DIR")
socket_path = os.path.join(
    runtime or os.environ.get("TMPDIR", tempfile.gettempdir()),
    "nyathing.sock" if runtime else f"nyathing-{os.getuid()}.sock",
)
config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(Path.home(), ".config")
config_path = Path(config_home) / "nyathing" / "config.toml"


def request(value):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(socket_path)
        stream = client.makefile("rwb")
        stream.write(json.dumps(value).encode() + b"\n")
        stream.flush()
        response = json.loads(stream.readline())
        if not response.get("ok"):
            raise RuntimeError(response.get("error", "Local API request failed"))
        return response


def api_is_ready():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1)
            client.connect(socket_path)
        return True
    except OSError:
        return False


def configured_value(text, key, default):
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*([\"'])(.*?)\1", text, re.M)
    return match.group(2) if match else default


def configured_seconds(text, key, default):
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*([0-9.]+)", text, re.M)
    return float(match.group(1)) if match else default


app = None
started_here = False
activity_ids = []
try:
    if not api_is_ready():
        app = subprocess.Popen([".build/debug/nyathing", "--nyathing-server"])
        started_here = True
        startup_deadline = time.monotonic() + 30
        while not api_is_ready():
            if app.poll() is not None:
                raise RuntimeError(
                    f"Nyathing exited during startup with status {app.returncode}"
                )
            if time.monotonic() >= startup_deadline:
                raise TimeoutError("Timed out waiting for Nyathing's local API")
            time.sleep(0.2)

    settings = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    interval = configured_seconds(settings, "keepalive_interval_seconds", 5.0)
    timeout = configured_seconds(settings, "activity_timeout_seconds", 30.0)
    animations = os.environ.get("ANIMATIONS", "").replace(",", " ").split()
    if not animations:
        animation = os.environ.get("ANIMATION")
        if animation is None:
            animation = configured_value(settings, "default_animation", "nyathing_36x36.png")
            if animation != "random":
                animation = str(config_path.parent / "animations" / animation)
        animations = [animation]
    for animation in animations:
        activity_id = request({
            "command": "start",
            "animation": animation,
            "keepalive_interval_seconds": interval,
        })["activity_id"]
        activity_ids.append(activity_id)
        print(f"Started {animation} ({activity_id})")

    keepalive_delay = interval
    run_deadline = time.monotonic() + 5
    while time.monotonic() < run_deadline:
        time.sleep(min(keepalive_delay, run_deadline - time.monotonic()))
        for activity_id in activity_ids:
            request({"command": "keepalive", "activity_id": activity_id})
finally:
    for activity_id in activity_ids:
        try:
            request({"command": "stop", "activity_id": activity_id})
        except Exception as error:
            print(f"Warning: could not stop test activity: {error}", file=sys.stderr)
    if started_here and app is not None and app.poll() is None:
        app.terminate()
        try:
            app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
