#!/usr/bin/env python3
"""Socket-level daemon latency: per-event round-trip times, measured from
outside the shim so shim cost and daemon cost separate cleanly.

Usage: rpc_latency.py [socket]   (default: $XDG_RUNTIME_DIR/clicue.sock)

Informational, not a gate — run it when something feels slow and compare:
a healthy daemon answers redraws in well under 1ms; the shim's deadline
is 5ms (spec §8), so anything approaching that number is the bug.
"""
import json, os, socket, statistics, sys, time

sock_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "clicue.sock")

def frame(event, buffer, pending=None):
    return {"v": 1, "session": {"pid": os.getpid(), "start": 1}, "event": event,
            "buffer": buffer, "cursor": len(buffer), "cols": 213, "lines": 58,
            "keymap": "main", "pending": pending, "env": None, "hist": []}

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
f = s.makefile("rwb")

def rpc(req):
    t0 = time.perf_counter()
    f.write(json.dumps(req).encode() + b"\n")
    f.flush()
    line = f.readline()
    return (time.perf_counter() - t0) * 1000, line

dt, _ = rpc(frame({"kind": "hello"}, "",))
print(f"hello (session create + seed): {dt:.2f} ms")

print("\nredraw latency, 200 reqs per buffer:")
for b in ["g", "git ", "git s", "ls -", "docker "]:
    times = sorted(rpc(frame({"kind": "redraw"}, b))[0] for _ in range(200))
    dt, last = rpc(frame({"kind": "redraw"}, b))
    r = json.loads(last)
    print(f"  {b!r:10} p50={times[100]:6.2f} p99={times[198]:6.2f} max={times[-1]:7.2f} ms"
          f"  reply={len(last)}B spans={len(r.get('spans', []))}")

# A worst-case harvest-carrying accept: ~200 synthetic flags, the shape the
# shim sends on Tab. This is the request class that once took 6.7ms and
# broke the 5ms deadline (FlagStore cloned the table per explain()).
words = [f"-flag{i:03}" for i in range(200)]
descs = [f"{w}  -- synthetic description number {i}" for i, w in enumerate(words)]
h = {"pos": "clicue-bench-synthetic -", "path": "clicue-bench-synthetic", "iprefix": "", "words": words, "descs": descs, "sfx": {}}
pend = {"harvests": [dict(h, live=True), dict(h, live=False)]}
rpc(frame({"kind": "redraw"}, "clicue-bench-synthetic -"))
dt, line = rpc(frame({"kind": "key", "name": "accept"}, "clicue-bench-synthetic -", pending=pend))
print(f"\naccept + 2×200-word harvest (cold): {dt:.2f} ms")
times = sorted(rpc(frame({"kind": "key", "name": "accept"}, "clicue-bench-synthetic -"))[0] for _ in range(50))
print(f"accept cycling (warm):              p50={times[25]:.2f} p99={times[48]:.2f} ms")
if times[48] > 5.0 or dt > 5.0:
    print("WARNING: at or over the shim's 5ms deadline — Tab will fall back to compsys")
