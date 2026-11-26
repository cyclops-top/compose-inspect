"""Isolate source metadata caching and empty/single-child flattening, without PixelCopy."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("serial")
parser.add_argument("output", type=Path)
args = parser.parse_args()
adb = ["adb", "-s", args.serial]
pkg = "dev.composeinspect.sample.nativebench"
port = subprocess.check_output(adb + ["forward", "tcp:0", "localabstract:composeinspect." + pkg], text=True).strip()
rows = []
modes = ["base", "cache", "children", "both"]
orders = [[(i + shift) % 4 for i in [0, 1, 3, 2]] for shift in range(4)]
def sample(mode, phase, round_id):
    req = dict(command="capture-gzip", geometryOnly=True, benchmarkMode=5, windowImages=False,
               tuneTree=mode in ("cache","both"), compactChildren=mode in ("children","both"))
    start = time.monotonic_ns()
    with socket.create_connection(("localhost", int(port)), 30) as sock, sock.makefile("rb") as f:
        sock.sendall(json.dumps(req).encode()+b"\n")
        n, = struct.unpack(">I", f.read(4))
        frame = f.read(n)
    duration = (time.monotonic_ns()-start)/1e6
    data = gzip.decompress(frame)
    d = json.loads(data)
    assert d.get("complete") and d["geometryOnly"] and b'"PerformanceProbe"' in data
    tree = hashlib.sha256(json.dumps(d["windows"],sort_keys=True).encode()).hexdigest()
    rows.append(dict(phase=phase, mode=mode, round=round_id, responseMs=duration, pid=d["pid"],
                     treeHash=tree, groups=d["stats"]["groups"], **d["timings"]))
try:
    for cold in range(5):
        subprocess.run(adb+["shell","am","force-stop",pkg], check=True)
        subprocess.run(adb+["shell","am","start","-W","-n",pkg+"/dev.composeinspect.sample.MainActivity",
                            "--es","scenario","performance"], check=True, stdout=subprocess.DEVNULL)
        time.sleep(1)
        sample("base","first",cold)
        sample("base","second",cold)
    for rnd in range(-4,24):
        for index in orders[rnd%4]:
            sample(modes[index],"warm",rnd)
    assert len({r["pid"] for r in rows if r["phase"]=="first"})==5
    assert all(len({r["treeHash"] for r in rows if r["pid"]==pid})==1 for pid in {r["pid"] for r in rows})
    args.output.write_text(json.dumps(rows,separators=(",",":"))+"\n")
finally:
    subprocess.run(adb+["forward","--remove","tcp:"+port],check=True)
