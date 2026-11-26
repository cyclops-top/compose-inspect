"""Run the isolated pipeline APK on one arm64/API 34+ device, keeping all samples."""
import argparse
import gzip
import hashlib
import itertools
import json
import re
import socket
import struct
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("serial")
parser.add_argument("output", type=Path)
parser.add_argument("--framing", action="store_true", help="Compare whole gzip, stored PNG blocks and split protocol")
parser.add_argument("--scene", choices=["cards", "texture"])
parser.add_argument("--save-stored-frame", type=Path, help="Save one validated frame for the desktop decoder")
args = parser.parse_args()
args.output.mkdir(exist_ok=True, parents=True)
package = "dev.composeinspect.sample.nativebench"
adb = ["adb", "-s", args.serial]
modes = [
    ("base", {}), ("tree", {"tuneTree": True}), ("png", {"fastPng": True}),
    ("both", {"fastPng": True, "tuneTree": True}),
    ("split", {"fastPng": True, "tuneTree": True, "split": True}),
    ("treeOnly", {"tuneTree": True, "windowImages": False}),
]
ident = 0
orders = [[(i + shift) % 6 for i in [0, 1, 5, 2, 4, 3]] for shift in range(6)]
if args.framing:
    common = {"fastPng": True, "tuneTree": True}
    modes = [("both", common), ("stored", dict(common, storePng=True)), ("split", dict(common, split=True))]
    orders = list(itertools.permutations(range(3)))
for scene in ([args.scene] if args.scene else ["cards", "texture"]):
    subprocess.run(adb + ["shell", "am", "force-stop", package], check=True)
    subprocess.run(adb + ["shell", "am", "start", "-W", "-n", package + "/dev.composeinspect.sample.MainActivity",
                          "--es", "scenario", "performance", "--ez", "texture", str(scene == "texture").lower()], check=True)
    time.sleep(1)
    port = subprocess.check_output(adb + ["forward", "tcp:0", "localabstract:composeinspect." + package], text=True).strip()
    rows = []
    expected = None
    try:
        for rnd in range(-3, 24):
            for m in orders[rnd % len(orders)]:
                name, options = modes[m]
                verify = rnd == -3 and name == ("both" if args.framing else "png")
                ident += 1
                req = dict(command="capture-gzip", geometryOnly=True, windowImages=True, benchmarkMode=5, requestID=ident, verifyPng=verify)
                req.update(options)
                t = time.monotonic_ns()
                with socket.create_connection(("localhost", int(port)), timeout=30) as sock, sock.makefile("rb") as stream:
                    sock.sendall(json.dumps(req).encode() + b"\n")
                    size, = struct.unpack(">I", stream.read(4))
                    assert 0 < size < 32*1024*1024
                    compressed = stream.read(size)
                    assert len(compressed) == size
                    extra = stream.read() if req.get("split") else b""
                elapsed = (time.monotonic_ns()-t)/1e6
                payload = gzip.decompress(compressed)
                data, sep, png = payload.partition(b"\n")
                doc = json.loads(data)
                assert doc.get("complete") and doc["geometryOnly"] and b'"PerformanceProbe"' in data, str(doc)[:400]
                metrics = doc["timings"]
                if verify:
                    assert metrics["verified"], metrics
                if req["windowImages"]:
                    assert bool(req.get("fastPng")) == metrics["native"]
                    image = extra if req.get("split") else png[:-1]
                    assert image.startswith(b"\x89PNG") and len(image) == sum(w.get("pngBytes", 0) for w in doc["windows"])
                else:
                    image = b""
                if rnd == 0 and name == "stored" and args.save_stored_frame:
                    args.save_stored_frame.write_bytes(struct.pack(">I", size) + compressed)
                for w in doc["windows"]:
                    w.pop("pngBytes", None)
                tree = hashlib.sha256(json.dumps(doc["windows"], sort_keys=True).encode()).hexdigest()
                if expected is None:
                    expected = tree
                assert tree == expected
                rows.append(dict(id=ident, round=rnd, mode=name, responseMs=elapsed, imageBytes=len(image),
                                 wireBytes=size+4+len(extra), pid=doc["pid"], groups=doc["stats"]["groups"], **metrics))
            if rnd % 6 == 5:
                print(scene, rnd + 1, flush=True)
        pid = rows[0]["pid"]
        assert all(row["pid"] == pid for row in rows)
        logs = subprocess.check_output(adb + ["logcat", "-d", "--pid", str(pid), "-s", "PipelineBench:I", "-v", "raw"], text=True)
        timings = {int(i): list(map(float, values)) for i, *values in re.findall(r"id=(\d+) pack=([\d.]+) encode=([\d.]+) frame=([\d.]+) write=([\d.]+)", logs)}
        for row in rows:
            assert row["id"] in timings
            row.update(zip(["packMs", "encodeMs", "frameMs", "writeMs"], timings[row["id"]]))
        (args.output / (scene+".json")).write_text(json.dumps(dict(treeHash=expected, samples=rows), separators=(",", ":"))+"\n")
    finally:
        subprocess.run(adb + ["forward", "--remove", "tcp:"+port], check=True)
