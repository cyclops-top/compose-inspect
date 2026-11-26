#!/usr/bin/env python3
"""Capture the SDK over ADB. Removes only its own ADB forward."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess


def exchange(port, options, body=b""):
    with socket.create_connection(("127.0.0.1", port), timeout=20) as connection:
        connection.sendall(json.dumps(options).encode() + b"\n" + body)
        with connection.makefile("rb") as stream:
            data = stream.readline(32 * 1024 * 1024)
            if not data.endswith(b"\n"):
                raise RuntimeError("Incomplete/oversized SDK response")
            result = json.loads(data)
            if "error" in result:
                raise RuntimeError(result["error"])
            return result


def prepare(port, package):
    hello = exchange(port, {"command": "hello"})
    if hello.get("packageName") != package:
        raise RuntimeError("Unexpected SDK package")
    if "collectorABI" not in hello:
        return hello
    if hello["collectorABI"] != 1:
        raise RuntimeError("Unsupported collector ABI")
    resources = Path(__file__).resolve().parents[2] / "macOS/Sources/ComposeInspectCore/Collector"
    jar = (resources / "collector.jar").read_bytes()
    metadata = json.loads((resources / "collector.json").read_text())
    if not metadata["version"] or metadata["digest"] != hashlib.sha256(jar).hexdigest():
        raise RuntimeError("Bundled collector does not match its version manifest")
    options = dict(collectorABI=1, collectorVersion=metadata["version"], digest=metadata["digest"], pid=hello["pid"],
                   signature=base64.b64encode((resources / "collector.sig").read_bytes()).decode())
    ready = exchange(port, dict(command="prepare", **options))
    if ready.get("state") == "missing":
        ready = exchange(port, dict(command="install", length=len(jar), **options), jar)
    if hello.get("checksCollectorVersion") and ready.get("collectorVersion") != metadata["version"]:
        raise RuntimeError("Unexpected collector version")
    if ready.get("digest") != options["digest"] or ready.get("pid") != hello["pid"]:
        raise RuntimeError("Collector identity changed")
    return ready


def capture(adb, serial, package, command="capture", component_details=False):
    prefix = [adb] + (["-s", serial] if serial else [])
    port = subprocess.check_output(prefix + ["forward", "tcp:0", "localabstract:composeinspect." + package], text=True).strip()
    try:
        hello = prepare(int(port), package)
        if command == "hello":
            return hello
        capability = "component-details-v1" if component_details else "geometry-only-v1"
        if capability not in hello.get("capabilities", []):
            raise RuntimeError(f"Update the target SDK to a build supporting {capability}")
        result = exchange(int(port), dict(command=command, geometryOnly=not component_details))
        if result.get("geometryOnly") != (not component_details) or result.get("pid") != hello["pid"]:
            raise RuntimeError("Unexpected capture mode or PID")
        return result
    finally:
        subprocess.run(prefix + ["forward", "--remove", "tcp:" + port], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=os.environ.get("ADB", "adb"))
    parser.add_argument("--serial")
    parser.add_argument("--package", default="dev.composeinspect.sample")
    parser.add_argument("--command", choices=["hello", "capture"], default="capture")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pretty", action="store_true", help="Write indented JSON (can be much larger for deep trees)")
    parser.add_argument("--component-details", action="store_true")
    args = parser.parse_args()
    result = capture(args.adb, args.serial, args.package, args.command, args.component_details)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None, separators=None if args.pretty else (",", ":")) + "\n")
    print(json.dumps(result.get("stats", result), ensure_ascii=False))


if __name__ == "__main__":
    main()
