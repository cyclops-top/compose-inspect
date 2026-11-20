#!/usr/bin/env python3
"""Rebuild CLI/Core and View Inspector against a checksum-pinned bootstrap runtime.

This is an incremental source build, not a full AOSP/native build. Frozen-source
checks reject changes to the payload, protocol and native layers that are reused.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "vendor/android/tools/base/ui-inspector"
CACHE = ROOT / ".build/standalone"
LOCK = json.loads((ROOT / "standalone-build.lock.json").read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def dependency(item):
    path = CACHE / item["file"]
    if not path.exists():
        candidates = list((Path.home() / ".gradle/caches/modules-2/files-2.1").glob(item["gradle_path"])) if "gradle_path" in item else []
        local = next((p for p in candidates if digest(p) == item["sha256"]), None)
        if local:
            data = local.read_bytes()
        else:
            print("Downloading", item["file"], flush=True)
            data = urllib.request.urlopen(item["url"], timeout=90).read()
            if item.get("base64"):
                data = base64.b64decode(data)
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise RuntimeError("Dependency checksum mismatch: " + item["file"])
        path.write_bytes(data)
    if digest(path) != item["sha256"]:
        raise RuntimeError("Cached dependency checksum mismatch: " + str(path))
    return path


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def proto_string(field, value):
    value = value.encode()
    return bytes([field * 8 + 2]) + varint(len(value)) + value


def relocate_protobuf(data):
    """Relocate only class-file UTF8 constants; all constant-pool indices stay intact.

    Compile-time bridge to the existing device payload's protobuf namespace.
    These dependency classes are not bundled into the rebuilt View Inspector.
    """
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("Expected Java class file")
    result = bytearray(data[:10])
    count = struct.unpack_from(">H", data, 8)[0]
    pos, index = 10, 1
    sizes = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4,
             15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
    while index < count:
        tag = data[pos]
        pos += 1
        result.append(tag)
        if tag == 1:
            size = struct.unpack_from(">H", data, pos)[0]
            pos += 2
            value = data[pos:pos + size]
            pos += size
            value = value.replace(b"com/google/protobuf", b"com/android/tools/idea/protobuf")
            value = value.replace(b"com.google.protobuf", b"com.android.tools.idea.protobuf")
            result += struct.pack(">H", len(value)) + value
        else:
            size = sizes[tag]
            result += data[pos:pos + size]
            pos += size
            if tag in (5, 6):
                index += 1
        index += 1
    return bytes(result) + data[pos:]


def add_bytes(archive, name, data):
    entry = zipfile.ZipInfo(name, (2010, 1, 1, 0, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(entry, data)


def add_tree(archive, root):
    for path in sorted(root.rglob("*")):
        if path.is_file():
            add_bytes(archive, path.relative_to(root).as_posix(), path.read_bytes())


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    java_home = os.environ.get("JAVA_HOME")
    if not java_home:
        java_home = subprocess.check_output(["/usr/libexec/java_home", "-v", "25+"], text=True).strip()
    java = Path(java_home) / "bin/java"
    javac = Path(java_home) / "bin/javac"
    sdk = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
    android = sdk / "platforms/android-36/android.jar"
    d8 = sdk / "build-tools/36.0.0/lib/d8.jar"
    for path in (java, javac, android, d8):
        if not path.is_file():
            raise RuntimeError("Missing build tool: " + str(path))

    actual = {}
    for root in ("common", "agent/payload", "art-tooling"):
        actual.update({p.relative_to(SOURCE).as_posix(): digest(p) for p in (SOURCE / root).rglob("*") if p.is_file()})
    if actual != LOCK["frozen_sources"]:
        raise RuntimeError("Reused native/payload/protocol sources changed; use the full Bazel build and refresh the bootstrap lock.")

    seed = CACHE / "bootstrap.jar"
    if not seed.exists():
        candidate = Path(os.environ.get("UI_INSPECTOR_BOOTSTRAP", str(ROOT / "lib/ui-inspector.jar")))
        if not candidate.is_file() or digest(candidate) != LOCK["bootstrap_sha256"]:
            raise RuntimeError("Set UI_INSPECTOR_BOOTSTRAP to the original checksum-pinned baseline JAR.")
        shutil.copy2(candidate, seed)
    if digest(seed) != LOCK["bootstrap_sha256"]:
        raise RuntimeError("Bootstrap checksum mismatch")
    deps = {item["file"]: dependency(item) for item in LOCK["dependencies"]}

    with tempfile.TemporaryDirectory(prefix="compile-", dir=CACHE) as temp:
        work = Path(temp)
        compile_deps = work / "compile-deps.jar"
        device_deps = work / "device-deps.jar"
        with zipfile.ZipFile(seed) as original, zipfile.ZipFile(compile_deps, "w") as host, zipfile.ZipFile(device_deps, "w") as device:
            for entry in original.infolist():
                data = original.read(entry)
                host.writestr(entry, data)
                if entry.filename.endswith(".class") and entry.filename.startswith(("com/google/protobuf/", "com/android/tools/ui/inspector/view/inspector/protocol/", "com/android/tools/ui/inspector/protocol/")):
                    add_bytes(device, entry.filename.replace("com/google/protobuf", "com/android/tools/idea/protobuf"), relocate_protobuf(data))
            # Bazel's fat JAR overwrote adblib's unnamed.kotlin_module. Recreate
            # its package facade index for compilation; never replace runtime code.
            names = sorted(n.rsplit("/", 1)[-1][:-6] for n in original.namelist() if n.startswith("com/android/adblib/") and n.count("/") == 3 and n.endswith("Kt.class"))
            package = proto_string(1, "com.android.adblib") + b"".join(proto_string(2, n) for n in names)
            module = struct.pack(">5I", 3, 2, 2, 0, 0) + b"\x0a" + varint(len(package)) + package
            add_bytes(host, "META-INF/standalone-adblib.kotlin_module", module)

        print("Compiling Kotlin CLI/Core", flush=True)
        compiler_cp = os.pathsep.join(str(deps[n]) for n in ("kotlin-compiler-embeddable-2.4.21.jar", "kotlin-build-tools-api-2.4.21.jar", "kotlin-script-runtime-2.4.21.jar", "annotations-13.0.jar")) + os.pathsep + str(seed)
        kotlin_sources = sorted((SOURCE / "core/src/main/java").rglob("*.kt")) + sorted((SOURCE / "cli/src/main/java").rglob("*.kt"))
        host_classes = work / "host"
        run(java, "-cp", compiler_cp, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-module-name", "ui-inspector-standalone", "-classpath", compile_deps, "-d", host_classes, *kotlin_sources)

        print("Compiling and dexing View Inspector", flush=True)
        inspection = work / "inspection.jar"
        with zipfile.ZipFile(deps["inspection-1.0.0.aar"]) as aar:
            inspection.write_bytes(aar.read("classes.jar"))
        java_sources = sorted((SOURCE / "agent/inspectors/view/src/main/java").rglob("*.java")) + sorted((SOURCE / "common/src/main/java").rglob("*.java"))
        view_classes = work / "view"
        cp = os.pathsep.join(map(str, (android, device_deps, inspection, deps["annotation-jvm-1.9.1.jar"])))
        run(javac, "--release", "17", "-cp", cp, "-d", view_classes, *java_sources)
        classes_jar = work / "view-classes.jar"
        with zipfile.ZipFile(classes_jar, "w") as archive:
            add_tree(archive, view_classes)
        dex = work / "dex"
        dex.mkdir()
        run(java, "-cp", d8, "com.android.tools.r8.D8", "--min-api", "29", "--lib", android, "--classpath", device_deps, "--classpath", inspection, "--output", dex, classes_jar)
        view_jar = work / "view-inspector.jar"
        with zipfile.ZipFile(view_jar, "w") as archive:
            add_tree(archive, dex)
            add_tree(archive, SOURCE / "agent/inspectors/view/src/main/resources")

        resource = "tools/base/ui-inspector/agent/inspectors/view/view-inspector.jar"
        output = work / "ui-inspector.jar"
        preserved = ("com/android/tools/ui/inspector/common/", "com/android/tools/ui/inspector/protocol/", "com/android/tools/ui/inspector/view/")
        info = {"mode": "standalone-incremental", "baseline_commit": LOCK["baseline_commit"], "bootstrap_sha256": digest(seed),
                "source_sha256": {p.relative_to(SOURCE).as_posix(): digest(p) for p in kotlin_sources + java_sources},
                "java_home": str(Path(java_home)), "android_jar_sha256": digest(android), "d8_sha256": digest(d8)}
        with zipfile.ZipFile(seed) as original, zipfile.ZipFile(output, "w") as archive:
            for entry in original.infolist():
                name = entry.filename
                if name == resource or (name.startswith("com/android/tools/ui/inspector/") and name.endswith(".class") and not name.startswith(preserved)):
                    continue
                archive.writestr(entry, original.read(entry))
            add_tree(archive, host_classes)
            add_bytes(archive, resource, view_jar.read_bytes())
            add_bytes(archive, "META-INF/composeinspect-build.json", json.dumps(info, sort_keys=True, indent=2).encode())
        run(java, "-jar", output, "--version")
        run(java, "-jar", output, "dump-ui", "--help")
        destination = ROOT / "lib/ui-inspector.jar"
        destination.parent.mkdir(exist_ok=True)
        output.replace(destination)
        info["output_sha256"] = digest(destination)
        (CACHE / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
        print("Built:", destination, "\nSHA-256:", info["output_sha256"], flush=True)


if __name__ == "__main__":
    main()
