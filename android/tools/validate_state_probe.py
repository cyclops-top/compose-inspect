#!/usr/bin/env python3
"""Check an unexposed Boolean, explicit debug readers, and typed viewport data on a sample APK."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from capture import capture
from validate import sdk_nodes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", choices=["dev.composeinspect.sample", "dev.composeinspect.sample.research"],
                        default="dev.composeinspect.sample.research")
    parser.add_argument("--compose", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    def adb(*values):
        return subprocess.check_output(["adb", "-s", args.serial, *values], text=True, timeout=30).strip()

    def launch(activity, *extras):
        adb("shell", "am", "force-stop", args.package)
        adb("shell", "am", "start", "-W", "-n", args.package + "/dev.composeinspect.sample." + activity, *extras)
        time.sleep(.7)

    def read():
        data = capture("adb", args.serial, args.package)
        assert data["sdkVersion"] == "0.1.2" and data["complete"] and not data["diagnostics"]
        return data

    def tap(text):
        data = read()
        window, = data["windows"]
        nodes = [n for n in sdk_nodes(data) if n["name"] == "BasicText" and
                 any(p["name"] == "text" and p["value"].get("value") == text for p in n["parameters"])]
        node, = nodes
        l, t, r, b = node["boundsInWindow"]
        x, y = window["screenOffset"]
        adb("shell", "input", "tap", str(x+(l+r)//2), str(y+(t+b)//2))
        time.sleep(.2)

    def sample(expected):
        tap("Sample")
        pid = adb("shell", "pidof", args.package)
        lines = adb("logcat", "-d", "--pid", pid, "-v", "raw", "-s", "CompScopeStateProbe:I").splitlines()
        value = next(s for s in reversed(lines) if s.startswith("readers="))
        assert value == expected, (value, expected)
        return value

    def exposed():
        data = read()
        nodes = list(sdk_nodes(data))
        args_by_instance = [[p["name"] for p in n["parameters"]] for n in nodes if n["name"] == "HiddenFlag"]
        assert len(args_by_instance) == 2 and all("hiddenFlag" not in names for names in args_by_instance)
        return {"arguments": args_by_instance,
                "text": sorted(p["value"]["value"] for n in nodes if n["name"] == "BasicText"
                               for p in n["parameters"] if p["name"] == "text")}

    launch("InternalStateProbeActivity", "--ez", "register", "false")
    before = exposed()
    tap("Toggle A")
    assert exposed() == before
    unregistered = sample("readers=[]")
    launch("InternalStateProbeActivity", "--ez", "register", "true")
    readings = [sample("readers=[A=false, B=false]")]
    tap("Toggle A")
    readings.append(sample("readers=[A=true, B=false]"))
    tap("Remove A")
    readings.append(sample("readers=[B=false]"))
    viewports = {}
    for scenario in ["main", "interactions"]:
        launch("MainActivity", "--es", "scenario", scenario)
        for n in sdk_nodes(read()):
            for p in n["parameters"]:
                if "viewport" in p["value"]:
                    viewports[n["name"]] = p["value"]["viewport"]
    assert set(viewports) == {"LazyRow", "LazyColumn", "LazyVerticalGrid"}
    for viewport in viewports.values():
        assert viewport["count"] > 0 and viewport["end"] > viewport["start"]
        assert len({i["index"] for i in viewport["items"]}) == len(viewport["items"])
    result = dict(compose=args.compose, sdk="0.1.2", beforeAndAfter=before, unregistered=unregistered,
                  registered=readings, viewports=viewports)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
