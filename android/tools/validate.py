#!/usr/bin/env python3
"""Validate the SDK on the sample app. Installs and restarts only dev.composeinspect.sample."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from zipfile import ZipFile

from capture import capture

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "dev.composeinspect.sample"


def run(command, log=None, timeout=240):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=timeout)
    if log:
        log.write_text(result.stdout + "\n" + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stderr[-4000:]}\n{result.stdout[-4000:]}")
    return result.stdout


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def apk_check(path, expected):
    with ZipFile(path) as archive:
        dex = b"".join(archive.read(name) for name in archive.namelist() if name.endswith(".dex"))
        manifest = archive.read("AndroidManifest.xml")
    initializer = "dev.composeinspect.sdk.InspectorInitProvider"
    present = ("L" + initializer.replace(".", "/") + ";").encode() in dex
    in_manifest = initializer.encode() in manifest or initializer.encode("utf-16le") in manifest
    assert present == expected and in_manifest == expected, f"Unexpected SDK packaging: {path}"
    if not expected:
        assert b"Ldev/composeinspect/collector/" not in dex
        assert b"Landroidx/compose/ui/tooling/data/" not in dex
    return {"initializerInDex": present, "initializerInManifest": in_manifest,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}


def business_hash():
    digest = hashlib.sha256()
    for path in sorted((ROOT / "sample/src/main").rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


FIXTURES = {
    "ProbeScreen", "ParameterCard", "DefaultCard", "InlineWrapper",
    "NonRestartableCard", "NoLayoutWrapper", "LazyRowProbe", "DialogContent", "PopupContent",
}


def sdk_nodes(document):
    for window in document["windows"]:
        for table in window["tables"]:
            pending = [table["tree"]]
            while pending:
                node = pending.pop()
                if not node:
                    continue
                if node.get("name"):
                    yield node
                pending.extend(reversed(node.get("children", [])))


def validate_sdk(directory, source):
    """Checks actual payloads against independently known fixture values and source offsets."""
    for scenario in ("main", "dialog", "popup"):
        document = json.loads((directory / f"sdk-{scenario}.json").read_text())
        assert document["complete"] and not document["diagnostics"], document["diagnostics"]
        nodes = list(sdk_nodes(document))
        required = {"dialog": {"DialogContent"}, "popup": {"PopupContent"}}.get(
            scenario, FIXTURES - {"DialogContent", "PopupContent"})
        captured = {n["name"] for n in nodes} & FIXTURES
        assert len(document["windows"]) == 1 and captured == required, (scenario, captured, required)
        for node in nodes:
            if node["name"] not in FIXTURES:
                continue
            location = node["source"]
            assert location["file"] == "MainActivity.kt"
            assert node["name"] in source.splitlines()[location["line"] - 1]
            # Fixture source is ASCII, so Python offsets and UTF-16 code units coincide.
            assert source[location["offset"]:].startswith(node["name"]), location
        if scenario != "main":
            continue
        card = next(n for n in nodes if n["name"] == "ParameterCard")
        params = {p["name"]: p for p in card["parameters"]}
        for name, value in {"title": "explicit-title", "count": 7, "enabled": True, "spacing": 12}.items():
            assert params[name]["value"]["value"] == value, (name, params[name])
        profile = {p["name"]: p["value"] for p in params["profile"]["value"]["fields"]}
        assert profile["name"]["value"] == "Ada" and profile["age"]["value"] == 37
        assert [p["value"] for p in profile["tags"]["items"]] == ["compose", "debug"]
        assert params["spacing"]["inlineClass"] == "androidx.compose.ui.unit.Dp"
        assert params["tint"]["inlineClass"] == "androidx.compose.ui.graphics.Color"
        defaults = next(n for n in nodes if n["name"] == "DefaultCard")["parameters"]
        assert {p["name"]: p["value"].get("value") for p in defaults} == {"title": "default-title", "count": 23, "nullable": None}
        assert all(p["fromDefault"] for p in defaults)
        rows = [n for n in nodes if n["name"] == "LazyRowProbe"]
        assert 0 < len(rows) < 100, "Only composed lazy items should be present"
        for name in ("InlineWrapper", "NonRestartableCard"):
            assert next(n for n in nodes if n["name"] == name)["parameters"] == [], name


def counter_value(document):
    card = next(node for node in sdk_nodes(document) if node["name"] == "ParameterCard")
    return next(p for p in card["parameters"] if p["name"] == "count")["value"]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=os.environ.get("ADB", "adb"))
    parser.add_argument("--serial", required=True)
    parser.add_argument("--versions", nargs="+", default=["1.12.1", "1.10.6"])
    args = parser.parse_args()
    adb = [args.adb, "-s", args.serial]
    assert run(adb + ["get-state"]).strip() == "device"
    initial_hash = business_hash()
    for version in args.versions:
        output = ROOT / "artifacts" / version
        output.mkdir(parents=True, exist_ok=True)
        gradle = [ROOT / "gradlew", "-p", ROOT, "--console=plain", f"-PcomposeVersion={version}"]
        metadata = {"composeVersionRequested": version, "businessSourceSha256": initial_hash,
                    "deviceApi": run(adb + ["shell", "getprop", "ro.build.version.sdk"]).strip(),
                    "deviceModel": run(adb + ["shell", "getprop", "ro.product.model"]).strip()}
        print(f"[{version}] Build SDK debug and SDK-free release", flush=True)
        run(gradle + [":sample:assembleDebug", ":sample:assembleRelease"], output / "sdk-build.log")
        shutil.copyfile(ROOT / "sample/build/outputs/apk/debug/sample-debug.apk", output / "sdk.apk")
        shutil.copyfile(ROOT / "sample/build/outputs/apk/release/sample-release-unsigned.apk", output / "release.apk")
        metadata["sdkApk"] = apk_check(output / "sdk.apk", True)
        metadata["releaseApk"] = apk_check(output / "release.apk", False)
        run(adb + ["install", "-r", output / "sdk.apk"])

        def launch(scenario):
            run(adb + ["shell", "am", "force-stop", PACKAGE])
            run(adb + ["shell", "am", "start", "-W", "-n", PACKAGE + "/.MainActivity", "--es", "scenario", scenario])
            time.sleep(1)

        for scenario in ("main", "dialog", "popup"):
            launch(scenario)
            result = capture(args.adb, args.serial, PACKAGE)
            save(output / f"sdk-{scenario}.json", result)
            print(f"[{version}] SDK {scenario}: {result['stats']}", flush=True)

        # Exercise a real recomposition, locating the action from its captured text and bounds.
        launch("main")
        before = capture(args.adb, args.serial, PACKAGE)
        for window in before["windows"]:
            nodes = sdk_nodes({"windows": [window]})
            target = next((node for node in nodes if node["name"] == "BasicText" and
                           any(p["name"] == "text" and p["value"].get("value") == "Increment: 7" for p in node["parameters"])), None)
            if target:
                left, top, right, bottom = target["boundsInWindow"]
                x, y = window["screenOffset"]
                run(adb + ["shell", "input", "tap", str(x + (left + right) // 2), str(y + (top + bottom) // 2)])
                deadline = time.monotonic() + 8
                while True:
                    result = capture(args.adb, args.serial, PACKAGE)
                    count = counter_value(result)
                    if count == 8:
                        save(output / "sdk-recomposed.json", result)
                        break
                    if count != 7 or time.monotonic() >= deadline:
                        raise AssertionError(f"Expected count 8 after one tap, received {count}")
                    time.sleep(.2)
                break
        else:
            raise AssertionError("Increment control missing")

        source = ROOT / "sample/src/main/java/dev/composeinspect/sample/MainActivity.kt"
        validate_sdk(output, source.read_text())
        print(f"[{version}] SDK values, source offsets, windows and recomposition checks passed", flush=True)

        save(output / "validation.json", metadata)
        print(f"[{version}] Evidence: {output}", flush=True)


if __name__ == "__main__":
    main()
