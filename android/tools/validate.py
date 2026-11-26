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
        assert ("assets/composeinspect/return-index-v1" in archive.namelist()) == expected
    initializer = "dev.composeinspect.sdk.InspectorInitProvider"
    present = ("L" + initializer.replace(".", "/") + ";").encode() in dex
    in_manifest = initializer.encode() in manifest or initializer.encode("utf-16le") in manifest
    assert present == expected and in_manifest == expected, f"Unexpected SDK packaging: {path}"
    index = "dev.composeinspect.sdk.ReturnIndexInitializer"
    assert (("L" + index.replace(".", "/") + ";").encode() in dex) == expected
    assert (index.encode() in manifest or index.encode("utf-16le") in manifest) == expected
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
        assert document["geometryOnly"] and document["stats"]["parameters"] == 0
        assert all(not w["styleCatalogs"] for w in document["windows"])
        assert all(not n.get("parameters") and "interaction" not in n for n in nodes)
        assert any(n.get("boundsInWindow") for n in nodes)
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
        assert not any(n["name"] in {"CompositionLocalProvider", "probeValue"} for n in nodes)
        rows = [n for n in nodes if n["name"] == "LazyRowProbe"]
        assert 0 < len(rows) < 100, "Only composed lazy items should be present"


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

        source = ROOT / "sample/src/main/java/dev/composeinspect/sample/MainActivity.kt"
        validate_sdk(output, source.read_text())
        print(f"[{version}] SDK geometry, source offsets and windows checks passed", flush=True)

        save(output / "validation.json", metadata)
        print(f"[{version}] Evidence: {output}", flush=True)


if __name__ == "__main__":
    main()
