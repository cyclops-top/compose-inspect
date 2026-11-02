#!/usr/bin/env python3
"""Rebuild the narrowly scoped Compose 1.12.1 metadata compatibility artifact.
All downloaded inputs are pinned by SHA-256; the official inspector cache is never edited.
"""
import hashlib
from pathlib import Path
import subprocess
import tempfile
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / 'vendor/android'
CACHE = ROOT / '.build/metadata-compat'
DEST = WORKSPACE / 'tools/base/ui-inspector/core/compat/compose-1.12.1-metadata-2.4.21.jar'
INPUTS = {
    'ui-android-1.12.1.aar': ('https://dl.google.com/dl/android/maven2/androidx/compose/ui/ui-android/1.12.1/ui-android-1.12.1.aar', '3f1ae17e237d9dc0a2a0f42cb04b85b8de6e12f67adc5f5c12173fe31e501cb2'),
    'kotlin-metadata-jvm-2.4.21.jar': ('https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-metadata-jvm/2.4.21/kotlin-metadata-jvm-2.4.21.jar', '848e8db928d4265c0302ddb95544eb127b52b0be13bd724b31dbee6bc16d8223'),
    'dexlib2-2.5.2.jar': ('https://repo.maven.apache.org/maven2/org/smali/dexlib2/2.5.2/dexlib2-2.5.2.jar', '5a5c8982d8bd7d6e3bb1a0713049e3c78b719ec32b20f6b619885cec30a0dd61'),
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build():
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in INPUTS.items():
        path = CACHE / name
        if not path.exists() or sha(path) != digest:
            temporary = path.with_suffix('.download')
            subprocess.run(['curl', '-fLsS', '--retry', '2', '--max-time', '120', '-o', str(temporary), url], check=True)
            if sha(temporary) != digest:
                raise RuntimeError(f'Checksum mismatch: {name}')
            temporary.replace(path)
    with tempfile.TemporaryDirectory(dir=CACHE) as tmp:
        out = Path(tmp)
        with ZipFile(CACHE / 'ui-android-1.12.1.aar') as aar:
            (out / 'original.jar').write_bytes(aar.read('inspector.jar'))
        maven = WORKSPACE / 'prebuilts/tools/common/m2/repository'
        java = WORKSPACE / 'prebuilts/studio/jdk/jbr25/mac-arm64/Contents/Home/bin'
        cp = ':'.join(map(str, [
            maven / 'org/ow2/asm/asm/9.9/asm-9.9.jar',
            maven / 'org/ow2/asm/asm-commons/9.9/asm-commons-9.9.jar',
            maven / 'com/google/guava/guava/33.4.0-jre/guava-33.4.0-jre.jar',
            CACHE / 'dexlib2-2.5.2.jar']))
        subprocess.run([str(java / 'javac'), '-cp', cp, '-d', str(out), str(ROOT / 'compat/UpgradeMetadata.java')], check=True)
        subprocess.run([str(java / 'java'), '-cp', str(out) + ':' + cp, 'UpgradeMetadata', str(out / 'original.jar'),
                        str(CACHE / 'kotlin-metadata-jvm-2.4.21.jar'), str(out)], check=True)
        subprocess.run([str(java / 'java'), '-cp', str(WORKSPACE / 'prebuilts/r8/r8.jar'), 'com.android.tools.r8.D8',
                        '--min-api', '26', '--lib', str(WORKSPACE / 'prebuilts/studio/sdk/darwin/platforms/android-36.1/android.jar'),
                        '--output', str(out / 'patched-dex.jar'), str(out / 'metadata-shaded.jar'), str(out / 'inspector.dex')], check=True)
        entries = {}
        with ZipFile(out / 'original.jar') as original:
            for item in original.infolist():
                name = item.filename
                if name.endswith('.dex') or ('metadata' in name and name.endswith('.kotlin_module')) or name.startswith('META-INF/services/deps.ui.inspection.kotlin.metadata.'):
                    continue
                entries[name] = original.read(item)
        with ZipFile(out / 'patched-dex.jar') as dex:
            for name in dex.namelist():
                if name.endswith('.dex'): entries[name] = dex.read(name)
        with ZipFile(CACHE / 'kotlin-metadata-jvm-2.4.21.jar') as metadata:
            for item in metadata.infolist():
                if item.filename.startswith('META-INF/services/') and not item.is_dir():
                    entries[item.filename.replace('kotlin.metadata.', 'deps.ui.inspection.kotlin.metadata.')] = metadata.read(item).replace(b'kotlin.metadata.', b'deps.ui.inspection.kotlin.metadata.')
                elif item.filename.endswith('.kotlin_module'):
                    entries[item.filename] = metadata.read(item)
        entries['META-INF/ComposeInspect-metadata-compat.txt'] = (ROOT / 'compat/NOTICE.txt').read_bytes()
        entries['META-INF/ComposeInspect-LICENSE.txt'] = (ROOT / 'compat/LICENSE.txt').read_bytes()
        with ZipFile(out / 'result.jar', 'w') as result:
            for name, data in sorted(entries.items()):
                entry = ZipInfo(name, (1980, 2, 1, 0, 0, 0))
                entry.compress_type = ZIP_DEFLATED
                result.writestr(entry, data)
        stdlib_root = maven / 'org/jetbrains/kotlin/kotlin-stdlib'
        fixture = stdlib_root / '2.4.0/kotlin-stdlib-2.4.0.jar'
        subprocess.run([str(java / 'javac'), '-cp', str(out / 'metadata-shaded.jar') + ':' + str(fixture),
                        '-d', str(out), str(ROOT / 'compat/MetadataCompatibilityTest.java')], check=True)
        for version, minor in [('2.2.10', '2'), ('2.4.0', '4')]:
            fixture = stdlib_root / version / f'kotlin-stdlib-{version}.jar'
            test_cp = ':'.join(map(str, [out, out / 'metadata-shaded.jar', out / 'result.jar', fixture]))
            subprocess.run([str(java / 'java'), '-cp', test_cp, 'MetadataCompatibilityTest', minor], check=True)
        DEST.parent.mkdir(parents=True, exist_ok=True)
        # Publish only a complete artifact; keep the existing file intact on any failed build.
        staged = DEST.with_suffix('.tmp')
        staged.write_bytes((out / 'result.jar').read_bytes())
        staged.replace(DEST)
    print(f'{sha(DEST)}  {DEST}')

if __name__ == '__main__':
    build()
