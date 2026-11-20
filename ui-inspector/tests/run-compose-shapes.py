#!/usr/bin/env python3
"""Integration check using Compose 1.12.1 AARs in the local Gradle cache and bundled JDK/SDK.
Downloads only the checksum-verified JSON test runtime from Maven Central.
Run: python3 ui-inspector/tests/run-compose-shapes.py
"""
import pathlib,glob,zipfile,tempfile,subprocess,urllib.request,hashlib,os
r=pathlib.Path(__file__).resolve().parents[2];w=r/'ui-inspector/vendor/android';j=pathlib.Path(os.environ.get('JAVA_HOME', str(w/'prebuilts/studio/jdk/jbr25/mac-arm64/Contents/Home')))/'bin'
sdk=pathlib.Path(os.environ.get('ANDROID_HOME', str(w/'prebuilts/studio/sdk/darwin')))
t=pathlib.Path(tempfile.mkdtemp(prefix='compose-shapes-test-'))
url='https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar';data=urllib.request.urlopen(url).read();expected=urllib.request.urlopen(url+'.sha1').read().decode().strip();assert hashlib.sha1(data).hexdigest()==expected
(t/'json.jar').write_bytes(data)
cp=[str(t/'json.jar'),str(sdk/'platforms/android-36/android.jar')]
cache=pathlib.Path.home()/'.gradle/caches/modules-2/files-2.1'
for module in ['foundation/foundation','ui/ui-unit','ui/ui-geometry','ui/ui-graphics','ui/ui-util','ui/ui','runtime/runtime']:
 group,artifact=module.split('/');paths=list(cache.glob(f'androidx.compose.{group}/{artifact}-android/1.12.1/*/*.aar'))
 if paths:
  with zipfile.ZipFile(paths[0]) as z:(t/(artifact+'.jar')).write_bytes(z.read('classes.jar'))
  cp.append(str(t/(artifact+'.jar')))
cp+=glob.glob(str(cache/'org.jetbrains.kotlin/kotlin-stdlib/2.4.20/*/kotlin-stdlib-2.4.20.jar'))
classpath=':'.join(cp)
source=w/'tools/base/ui-inspector/agent/inspectors/view/src/main/java/com/android/tools/ui/inspector/inspectors/view/ComposeStyles.java'
subprocess.run([str(j/'javac'),'-cp',classpath,'-d',str(t),str(source),str(r/'ui-inspector/tests/ComposeShapesTest.java'),str(r/'ui-inspector/tests/ComposeStylesPerformanceTest.java')],check=True)
subprocess.run([str(j/'java'),'-cp',str(t)+':'+classpath,'com.android.tools.ui.inspector.inspectors.view.ComposeShapesTest'],check=True)

subprocess.run([str(j/'java'),'-cp',str(t)+':'+classpath,'com.android.tools.ui.inspector.inspectors.view.ComposeStylesPerformanceTest'],check=True)
