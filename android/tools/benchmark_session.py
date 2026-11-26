#!/usr/bin/env python3
"""Compare one-shot and session-scoped ADB forwards on the static sample performance screen."""
import argparse
from contextlib import contextmanager
import gzip
import hashlib
import json
import math
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import time

LIMIT = 32 * 1024 * 1024


def request(port, command):
    with socket.create_connection(("127.0.0.1", port), timeout=20) as sock, sock.makefile("rb") as stream:
        sock.sendall(json.dumps({"command": command, "geometryOnly": True}).encode() + b"\n")
        if command == "hello":
            return json.loads(stream.readline(65536)), 0
        size, = struct.unpack(">I", stream.read(4))
        if not 0 < size <= LIMIT:
            raise ValueError("Invalid gzip frame size")
        frame = stream.read(size)
        if len(frame) != size:
            raise ValueError("Incomplete gzip response")
        return json.loads(gzip.decompress(frame)), size + 4


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", choices=["dev.composeinspect.sample", "dev.composeinspect.sample.research"],
                        default="dev.composeinspect.sample.research")
    parser.add_argument("--compose", required=True, help="Resolved Compose version of installed sample build")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    expected_sdk = "0.1.5-SNAPSHOT"

    def adb(*args_):
        return subprocess.check_output(["adb", "-s", args.serial, *args_], text=True, timeout=30).strip()

    def validate(response, pid=None):
        if (response.get("packageName") != args.package or response.get("sdkVersion") != expected_sdk
                or response.get("protocolVersion") != 1 or not response.get("pid")
                or (pid is not None and response["pid"] != pid)):
            raise ValueError("SDK identity changed")

    @contextmanager
    def session():
        port = int(adb("forward", "tcp:0", "localabstract:composeinspect." + args.package))
        try:
            hello, _ = request(port, "hello")
            validate(hello)
            if not {"gzip-json-v1", "geometry-only-v1"}.issubset(hello["capabilities"]):
                raise ValueError("Missing geometry capture or gzip capability")
            yield port, hello["pid"]
        finally:
            adb("forward", "--remove", "tcp:" + str(port))

    def launch():
        adb("shell", "am", "force-stop", args.package)
        adb("shell", "am", "start", "-W", "-n", args.package + "/dev.composeinspect.sample.MainActivity",
            "--es", "scenario", "performance")
        time.sleep(0.7)

    rows = []
    def sample(mode, phase, shared=None):
        start = time.perf_counter()
        if shared is None:
            with session() as (port, pid):
                data, size = request(port, "capture-gzip")
        else:
            port, pid = shared
            data, size = request(port, "capture-gzip")
        elapsed = (time.perf_counter() - start) * 1000
        validate(data, pid)
        if not data["geometryOnly"] or not data["complete"] or data["diagnostics"]:
            raise ValueError("Partial capture")
        windows = json.dumps(data["windows"], sort_keys=True, separators=(",", ":")).encode()
        if b'"PerformanceProbe"' not in windows:
            raise ValueError("Wrong foreground screen")
        rows.append(dict(mode=mode, phase=phase, ms=round(elapsed, 2), collectMs=data["timings"]["collectMs"],
                         wireBytes=size, pid=pid, groups=data["stats"]["groups"],
                         windowsSHA256=hashlib.sha256(windows).hexdigest()))

    # Both modes must establish a session for the first capture after process launch.
    for i in range(5):
        for mode in (["fresh", "reuse"] if i % 2 == 0 else ["reuse", "fresh"]):
            launch()
            sample(mode, "cold")
    with session() as shared:
        for i in range(20):
            for mode in (["fresh", "reuse"] if i % 2 == 0 else ["reuse", "fresh"]):
                sample(mode, "warm", shared if mode == "reuse" else None)

    warm = [r for r in rows if r["phase"] == "warm"]
    if len({r["windowsSHA256"] for r in warm}) != 1:
        raise ValueError("Stable-screen window payloads differ")
    summary = {}
    for phase in ["cold", "warm"]:
        for mode in ["fresh", "reuse"]:
            values = sorted(r["ms"] for r in rows if r["phase"] == phase and r["mode"] == mode)
            summary[phase + "_" + mode] = dict(n=len(values), median=round(statistics.median(values), 2),
                                                 p95=values[math.ceil(len(values)*0.95)-1])
    report = dict(compose=args.compose, sdk=expected_sdk, model=adb("shell", "getprop", "ro.product.model"),
                  api=adb("shell", "getprop", "ro.build.version.sdk"), package=args.package,
                  summary=summary, samples=rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
