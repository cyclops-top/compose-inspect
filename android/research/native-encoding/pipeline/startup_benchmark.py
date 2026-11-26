"""Validate the actual SDK's Startup task on the performance screen of the debug sample."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("serial")
parser.add_argument("old_apk", type=Path)
parser.add_argument("new_apk", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
adb = ["adb", "-s", args.serial]
pkg = "dev.composeinspect.sample"
index = "code_cache/composeinspect-return-index-v1"
port = subprocess.check_output(adb+["forward","tcp:0","localabstract:composeinspect."+pkg],text=True).strip()
rows = []
def install(apk):
    subprocess.run(adb+["install","-r",str(apk)],check=True)
def sample(mode):
    subprocess.run(adb+["shell","am","force-stop",pkg],check=True)
    if mode in ["early","prewarm"]:
        subprocess.run(adb+["shell","run-as",pkg,"rm","-f",index],check=True)
    if mode == "damaged":
        subprocess.run(adb+["shell","-T","run-as",pkg,"tee",index],input=b"broken",stdout=subprocess.DEVNULL,check=True)
    start=subprocess.check_output(adb+["shell","am","start","-W","-n",pkg+"/dev.composeinspect.sample.MainActivity",
                                       "--es","scenario","performance"],text=True)
    launch=int(re.search(r"TotalTime: (\d+)",start).group(1))
    if mode in ["prewarm","damaged","control"]:
        time.sleep(6)
    ready=subprocess.run(adb+["shell","run-as",pkg,"test","-s",index],capture_output=True).returncode==0
    t=time.monotonic_ns()
    with socket.create_connection(("localhost",int(port)),30) as s, s.makefile("rb") as f:
        s.sendall(b'{"command":"capture-gzip","geometryOnly":true}\n')
        n,=struct.unpack(">I",f.read(4))
        payload=f.read(n)
    elapsed=(time.monotonic_ns()-t)/1e6
    d=json.loads(gzip.decompress(payload))
    assert d.get("complete") and d["geometryOnly"] and d["stats"]["filteredValueCalls"]>0, str(d)[:200]
    tree=hashlib.sha256(json.dumps(d["windows"],sort_keys=True).encode()).hexdigest()
    assert not rows or tree==rows[0]["tree"]
    if mode in ["prewarm","damaged"]: assert ready and d["timings"]["returnIndexWaitMs"] < 100
    rows.append(dict(mode=mode,launchMs=launch,responseMs=elapsed,cachePresentBeforeRequest=ready,
                     pid=d["pid"],tree=tree,stats=d["stats"],**d["timings"]))
    print(mode,launch,round(elapsed),d["timings"].get("returnIndexWaitMs"),flush=True)
try:
    install(args.old_apk)
    for _ in range(3): sample("control")
    install(args.new_apk)
    for i in range(3):
        for mode in (["early","hit","prewarm"] if i%2==0 else ["prewarm","hit","early"]): sample(mode)
    sample("damaged")
    assert len({r["pid"] for r in rows}) == len(rows)
    args.output.write_text(json.dumps(rows,indent=2)+"\n")
finally:
    subprocess.run(adb+["forward","--remove","tcp:"+port],check=True)
