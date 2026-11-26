"""Measure a complete fast capture through a reused ADB forward, including paired window PNG."""
import argparse
import gzip
import hashlib
import itertools
import json
from pathlib import Path
import socket
import struct
import subprocess
import time

PACKAGE = "dev.composeinspect.sample.nativebench"
parser = argparse.ArgumentParser()
parser.add_argument("serial")
parser.add_argument("output", type=Path)
args = parser.parse_args()
adb = ["adb", "-s", args.serial]
port = subprocess.check_output(adb + ["forward", "tcp:0", "localabstract:composeinspect." + PACKAGE], text=True).strip()
rows = []
tree_hash = None
orders = list(itertools.permutations([0, 5, 6]))
try:
    for round_id in range(-3, 24):
        for mode in orders[round_id % len(orders)]:
            req = dict(command="capture-gzip", windowImages=True, geometryOnly=True, benchmarkMode=mode)
            start = time.monotonic_ns()
            with socket.create_connection(("localhost", int(port)), 30) as sock, sock.makefile("rb") as stream:
                sock.sendall(json.dumps(req).encode() + b"\n")
                size, = struct.unpack(">I", stream.read(4))
                assert 0 < size <= 32 * 1024 * 1024
                frame = stream.read(size)
                assert len(frame) == size
            elapsed = (time.monotonic_ns() - start) / 1e6
            data, pngs = gzip.decompress(frame).split(b"\n", 1)
            doc = json.loads(data)
            assert doc["geometryOnly"] and doc["complete"] and not doc["diagnostics"]
            assert doc["packageName"] == PACKAGE and b'"PerformanceProbe"' in data
            assert pngs.startswith(b"\x89PNG") and len(pngs) == 1 + sum(w["pngBytes"] for w in doc["windows"] if "pngBytes" in w)
            # PNG may change if the status bar clock ticks. Compare just the tree across fresh captures.
            for w in doc["windows"]:
                w.pop("pngBytes", None)
            digest = hashlib.sha256(json.dumps(doc["windows"], sort_keys=True).encode()).hexdigest()
            if tree_hash is None:
                tree_hash = digest
            assert tree_hash == digest, "Fixture changed"
            rows.append(dict(round=round_id, mode=mode, responseMs=elapsed, collectMs=doc["timings"]["collectMs"],
                             groups=doc["stats"]["groups"], pid=doc["pid"], size=size))
        print(round_id, flush=True)
    assert len({r["pid"] for r in rows}) == 1
    args.output.write_text(json.dumps(dict(treeHash=tree_hash, samples=rows), indent=2) + "\n")
finally:
    subprocess.run(adb + ["forward", "--remove", "tcp:" + port], check=True)
