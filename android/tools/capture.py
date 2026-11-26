#!/usr/bin/env python3
"""Capture the SDK over ADB. Removes only its own ADB forward."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess


def capture(adb, serial, package, command="capture", component_details=False):
    geometry_only = not component_details
    if command == "capture":
        capability = "component-details-v1" if component_details else "geometry-only-v1"
        if capability not in capture(adb, serial, package, "hello").get("capabilities", []):
            raise RuntimeError(f"Update the target SDK to a build supporting {capability}")
    prefix = [adb] + (["-s", serial] if serial else [])
    port = subprocess.check_output(prefix + ["forward", "tcp:0", "localabstract:composeinspect." + package], text=True).strip()
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=20) as connection:
            connection.sendall((json.dumps({"command": command, "geometryOnly": geometry_only}) + "\n").encode())
            with connection.makefile("rb") as stream:
                data = stream.readline(32 * 1024 * 1024)
                if not data.endswith(b"\n"):
                    raise RuntimeError("Incomplete/oversized SDK response")
                result = json.loads(data)
                if "error" in result:
                    raise RuntimeError(result["error"])
                if command == "capture" and result.get("geometryOnly") is not geometry_only:
                    raise RuntimeError("SDK returned an unexpected capture mode")
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
