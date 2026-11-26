"""Prepare an isolated arm64 benchmark checkout. Run from any directory."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("destination", type=Path, help="New directory for a copy of the Android project")
parser.add_argument("--ndk", type=Path, default=os.environ.get("ANDROID_NDK_HOME"), required="ANDROID_NDK_HOME" not in os.environ)
args = parser.parse_args()
root = args.destination.resolve()
shutil.copytree(HERE.parents[1], root,
                ignore=shutil.ignore_patterns("build", ".gradle", ".kotlin", "artifacts", "research", ".cxx"))
p = root / "sample/build.gradle.kts"
p.write_text(p.read_text().replace('applicationId = "dev.composeinspect.sample"', 'applicationId = "dev.composeinspect.sample.nativebench"')
             .replace('    id("top.cyclops.compose-inspector")\n', '')  # Benchmarks compare runtime DEX indexing.
             .replace("sample.SemanticsReadBenchmark", "sample.NativeEncodingBenchmark"))
p = root / "inspector-sdk/src/main/java/dev/composeinspect/sdk/InspectorInitProvider.kt"
p.write_text(p.read_text().replace("var compressed = false", "var compressed = false\n                                var benchmarkMode = 0")
             .replace("val json = JsonResponseEncoder.encode(response)", "val json = dev.composeinspect.research.ResearchEncoder.encode(response, benchmarkMode)")
             .replace('val command = options.getString("command")', 'val command = options.getString("command")\n                                    benchmarkMode = options.optInt("benchmarkMode", 0)'))
dst = root / "inspector-sdk/src/main/java/dev/composeinspect/research"
dst.mkdir(parents=True)
shutil.copy2(HERE / "ResearchEncoder.kt", dst)
shutil.copy2(HERE / "NativeEncodingBenchmark.kt", root / "sample/src/androidTest/java/dev/composeinspect/sample")
lib = root / "sample/src/debug/jniLibs/arm64-v8a/libtreebench.so"
lib.parent.mkdir(parents=True)
host = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
cc = args.ndk / "toolchains/llvm/prebuilt" / host / "bin/aarch64-linux-android26-clang++"
subprocess.run([cc, "-O2", "-std=c++17", "-shared", "-fPIC", "-static-libstdc++", HERE / "encode.cpp", "-o", lib], check=True)
