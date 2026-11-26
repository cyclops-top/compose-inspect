"""Compare first capture of independent processes with/without an APK signature index."""
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
cache = "code_cache/pipeline-return-index-v1"
port = subprocess.check_output(adb+["forward","tcp:0","localabstract:composeinspect."+pkg],text=True).strip()
rows = []
def capture(label, cached):
    subprocess.run(adb+["shell","am","force-stop",pkg],check=True)
    subprocess.run(adb+["shell","am","start","-W","-n",pkg+"/dev.composeinspect.sample.MainActivity",
                        "--es","scenario","performance"],check=True,stdout=subprocess.DEVNULL)
    time.sleep(1)
    req=dict(command="capture-gzip",geometryOnly=True,benchmarkMode=5,windowImages=True,
             tuneTree=True,fastPng=True,storePng=True,persistIndex=cached)
    start=time.monotonic_ns()
    with socket.create_connection(("localhost",int(port)),30) as s, s.makefile("rb") as f:
        s.sendall(json.dumps(req).encode()+b"\n")
        n,=struct.unpack(">I", f.read(4))
        frame=f.read(n)
    elapsed=(time.monotonic_ns()-start)/1e6
    doc,png=gzip.decompress(frame).split(b"\n",1)
    d=json.loads(doc)
    assert d.get("complete") and not d["diagnostics"] and d["stats"]["filteredValueCalls"]>0 and d["timings"]["native"]
    assert len(png)==1+sum(w.pop("pngBytes",0) for w in d["windows"]) and png.startswith(b"\x89PNG")
    digest=hashlib.sha256(json.dumps(d["windows"],sort_keys=True).encode()).hexdigest()
    if rows:
        assert digest==rows[0]["hash"] and d["stats"]==rows[0]["stats"]
    rows.append(dict(label=label,responseMs=elapsed,pid=d["pid"],hash=digest,stats=d["stats"],**d["timings"]))
    print(label, round(elapsed), round(d["timings"]["signatureMs"]), flush=True)
try:
    capture("populate",True)
    for i in range(5):
        for cached in ([False,True] if i%2==0 else [True,False]):
            capture("hit" if cached else "scan", cached)
    contents=subprocess.check_output(adb+["exec-out","run-as",pkg,"cat",cache])
    assert len(contents)>100
    for label,changed in [("truncated",contents[:len(contents)//2]),("stale",contents[:2]+b"X"+contents[3:])]:
        subprocess.run(adb+["shell","-T","run-as",pkg,"tee",cache],input=changed,stdout=subprocess.DEVNULL,check=True)
        capture(label, True)
    capture("restored",True)
    assert len({r["pid"] for r in rows})==len(rows)
    args.output.write_text(json.dumps(dict(indexBytes=len(contents),samples=rows),indent=2)+"\n")
finally:
    subprocess.run(adb+["forward","--remove","tcp:"+port],check=True)
