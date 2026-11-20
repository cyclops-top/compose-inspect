#!/usr/bin/env python3
"""Build/install the probe and compare SDK-only captures with an SDK-free inspector baseline.

Only dev.composeinspect.sample is installed/restarted. Requires an explicitly selected device.
JAVA_HOME is the Gradle JDK; INSPECTOR_JAVA_HOME may select Java 25+ for ui-inspector.
"""
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
from compare import compare, sdk_nodes, validate_sdk

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "dev.composeinspect.sample"


def run(command, log=None, env=None, timeout=240):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, env=env, timeout=timeout)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default=os.environ.get("ADB", "adb"))
    parser.add_argument("--serial", required=True)
    parser.add_argument("--versions", nargs="+", default=["1.12.1", "1.10.6"])
    parser.add_argument("--sdk-only", action="store_true", help="Refresh SDK/release evidence without invoking ui-inspector")
    args = parser.parse_args()
    adb = [args.adb, "-s", args.serial]
    assert run(adb + ["get-state"]).strip() == "device"
    inspector = ROOT.parent / "ui-inspector/bin/ui-inspector"
    inspector_env = os.environ.copy()
    # Don't accidentally run the inspector with Gradle's JDK 17/21.
    inspector_env.pop("JAVA_HOME", None)
    if os.environ.get("INSPECTOR_JAVA_HOME"):
        inspector_env["JAVA_HOME"] = os.environ["INSPECTOR_JAVA_HOME"]
    initial_hash = business_hash()
    for version in args.versions:
        output = ROOT / "artifacts" / version
        output.mkdir(parents=True, exist_ok=True)
        gradle = [ROOT / "gradlew", "-p", ROOT, "--console=plain", f"-PcomposeVersion={version}"]
        metadata = {"composeVersionRequested": version, "businessSourceSha256": initial_hash,
                    "deviceApi": run(adb + ["shell", "getprop", "ro.build.version.sdk"]).strip(),
                    "deviceModel": run(adb + ["shell", "getprop", "ro.product.model"]).strip()}
        print(f"[{version}] Build SDK debug and SDK-free release", flush=True)
        run(gradle + [":sample:assembleDebug", ":sample:assembleRelease", ":sample:composeDependencyReport"], output / "sdk-build.log")
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
            target = next((node for node, _ in nodes if node["name"] == "BasicText" and
                           any(p["name"] == "text" and p["value"].get("value") == "Increment: 7" for p in node["parameters"])), None)
            if target:
                left, top, right, bottom = target["boundsInWindow"]
                x, y = window["screenOffset"]
                run(adb + ["shell", "input", "tap", str(x + (left + right) // 2), str(y + (top + bottom) // 2)])
                time.sleep(.5)
                save(output / "sdk-recomposed.json", capture(args.adb, args.serial, PACKAGE))
                break
        else:
            raise AssertionError("Increment control missing")

        source = ROOT / "sample/src/main/java/dev/composeinspect/sample/MainActivity.kt"
        validate_sdk(output, source.read_text())
        print(f"[{version}] SDK values, source offsets, windows and recomposition checks passed", flush=True)

        if not args.sdk_only:
            print(f"[{version}] Build/install identical business sources without SDK", flush=True)
            run(gradle + ["-PwithInspectorSdk=false", ":sample:assembleDebug", ":sample:composeDependencyReport"], output / "baseline-build.log")
            shutil.copyfile(ROOT / "sample/build/outputs/apk/debug/sample-debug.apk", output / "baseline.apk")
            metadata["baselineApk"] = apk_check(output / "baseline.apk", False)
            run(adb + ["install", "-r", output / "baseline.apk"])
            for scenario in ("main", "dialog", "popup"):
                launch(scenario)
                result_path = output / f"inspector-{scenario}.json"
                result_path.unlink(missing_ok=True)  # Failed runs must not reuse an old success.
                run([inspector, "dump-ui", "--device", args.serial, "--package", PACKAGE,
                     "--include", "attributes,semantics,system-composables", "--output", result_path],
                    output / f"inspector-{scenario}.log", env=inspector_env)
                print(f"[{version}] Inspector {scenario} captured", flush=True)
            sdk_deps = {line for line in (output / "sdk-build.log").read_text().splitlines() if line.startswith("COMPOSE_DEPENDENCY debug")}
            baseline_deps = {line for line in (output / "baseline-build.log").read_text().splitlines() if line.startswith("COMPOSE_DEPENDENCY debug")}
            # Tooling-data is deliberately added. Every shared Compose artifact must retain its version.
            def coordinates(lines):
                return {tuple(line.split()[-1].split(":")[:2]): line.split()[-1].split(":")[-1] for line in lines}
            sd, bd = coordinates(sdk_deps), coordinates(baseline_deps)
            assert sd and bd
            assert all(sd[key] == value for key, value in bd.items()), "SDK changed a host Compose dependency"
            assert bd[("androidx.compose.ui", "ui-android")] == version
            metadata["hostComposeVersionsUnchanged"] = True
            metadata["resolvedSdkComposeDependencies"] = sorted(sdk_deps)
            metadata["resolvedBaselineComposeDependencies"] = sorted(baseline_deps)
        else:
            metadata["baselineRefreshed"] = False
        assert business_hash() == initial_hash, "Business sources changed during comparison"
        jar = ROOT.parent / "ui-inspector/lib/ui-inspector.jar"
        metadata["inspectorJarSha256"] = hashlib.sha256(jar.read_bytes()).hexdigest() if jar.exists() else None
        save(output / "validation.json", metadata)
        save(output / "comparison.json", compare(output))
        print(f"[{version}] Evidence: {output}", flush=True)


if __name__ == "__main__":
    main()
