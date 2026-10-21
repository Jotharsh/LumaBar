#!/usr/bin/env python3
"""A pretend WiZ bulb for testing LumaBar without hardware.

    python3 scripts/fake_bulb.py            # listens on UDP 38899, prints every command
    python3 scripts/fake_bulb.py --port 48899

Add 127.0.0.1 as a bulb in LumaBar's Settings (or let it discover this Mac).
It also answers broadcast "registration" requests, so Search Network finds it.
"""
import argparse, json, socket

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=38899)
args = ap.parse_args()

state = {"state": True, "dimming": 60, "temp": 2700, "sceneId": 0}
MAC = "a8bb50fa4e00"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
sock.bind(("0.0.0.0", args.port))
print(f"fake WiZ bulb listening on UDP {args.port}", flush=True)

while True:
    data, addr = sock.recvfrom(4096)
    try:
        msg = json.loads(data)
    except ValueError:
        print("bad packet:", data, flush=True)
        continue
    if "result" in msg or "error" in msg:
        continue  # a reply, not a request (happens when LumaBar runs on the same Mac and shares port 38899)
    method, params = msg.get("method"), msg.get("params", {})
    print(f"{addr[0]}:{addr[1]} -> {json.dumps(msg, sort_keys=True)}", flush=True)
    if method == "setPilot":
        state.update(params)
        if "sceneId" in params:                 # entering a scene: colour/white settings no longer apply
            for k in ("temp", "r", "g", "b"): state.pop(k, None)
        elif "temp" in params or "r" in params:  # leaving scene mode
            state["sceneId"] = 0
            state.pop("speed", None)
            for k in (("r", "g", "b") if "temp" in params else ("temp",)): state.pop(k, None)
        reply = {"method": "setPilot", "env": "pro", "result": {"success": True}}
    elif method == "getPilot":
        reply = {"method": "getPilot", "env": "pro", "result": {"mac": MAC, "rssi": -55, **state}}
    elif method == "registration":
        reply = {"method": "registration", "env": "pro", "result": {"mac": MAC, "success": True}}
    else:
        reply = {"method": method, "error": {"code": -32601, "message": "Method not found"}}
    sock.sendto(json.dumps(reply).encode(), addr)
