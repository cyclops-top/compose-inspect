#!/usr/bin/env python3
"""Exercise production RootsDetector with fake window/focus state, without a device."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
java_home = os.environ.get('JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home'], text=True).strip()
sources = {
    'android/view/WindowManager.java': '''package android.view;
public class WindowManager { public static class LayoutParams { public static final int FIRST_SYSTEM_WINDOW=2000, TYPE_APPLICATION_PANEL=1000, TYPE_APPLICATION_SUB_PANEL=1002,
        TYPE_APPLICATION_ATTACHED_DIALOG=1003, FIRST_SUB_WINDOW=1000;
    public Object token; public int type; public LayoutParams(int t) {type=t;} } }''',
    'android/view/View.java': '''package android.view;
public class View {
    public static final int VISIBLE=0; public int windowVisibility=VISIBLE;
    public int getWindowVisibility(){return windowVisibility;}
    public Object getWindowToken(){return this;}
    public boolean shown=true, attached=true, focused;
    private final WindowManager.LayoutParams params;
    public View(int type, boolean focus) { params=new WindowManager.LayoutParams(type); focused=focus; }
    public WindowManager.LayoutParams getLayoutParams(){return params;}
    public boolean isShown(){return shown;}
    public boolean isAttachedToWindow(){return attached;}
    public boolean hasWindowFocus(){return focused;}
}''',
    'android/view/inspector/WindowInspector.java': '''package android.view.inspector;
import android.view.View; import java.util.List;
public class WindowInspector { public static List<View> roots; public static List<View> getGlobalWindowViews(){return roots;} }''',
    'com/android/tools/agent/appinspection/XrHelper.java': '''package com.android.tools.agent.appinspection;
import android.view.View; import java.util.List;
public class XrHelper { public List<View> getXrViews(){return List.of();} }''',
    'com/android/tools/ui/inspector/inspectors/view/WindowSelectionTest.java': '''package com.android.tools.ui.inspector.inspectors.view;
import android.view.View; import android.view.inspector.WindowInspector;
import com.android.tools.agent.appinspection.XrHelper; import java.util.List;
public class WindowSelectionTest {
    static void expect(View expected, boolean skip, View... roots) {
        WindowInspector.roots=List.of(roots);
        if (RootsDetector.getRootViews(new XrHelper(),skip).get(0)!=expected) throw new AssertionError();
    }
    public static void main(String[] args) {
        View activity=new View(1,true), overlay=new View(2038,false), dialog=new View(2,true);
        expect(overlay,false,activity,overlay);
        expect(overlay,false,overlay,activity);
        expect(activity,true,activity,overlay);
        expect(overlay,false,activity,overlay);
        overlay.shown=false; expect(activity,false,activity,overlay);
        overlay.shown=true; overlay.attached=false; expect(activity,false,activity,overlay);
        expect(dialog,false,activity,dialog); expect(dialog,true,activity,dialog);
        View panel=new View(1002,false), other=new View(1000,false), media=new View(1001,false);
        panel.getLayoutParams().token=activity; other.getLayoutParams().token=dialog; media.getLayoutParams().token=activity;
        expect(panel,false,activity,panel,other,media); expect(panel,true,activity,panel,other,media);
        panel.windowVisibility=4; expect(activity,false,activity,panel,other,media);
        overlay.attached=true; WindowInspector.roots=List.of(overlay);
        try { RootsDetector.getRootViews(new XrHelper(),true); throw new AssertionError(); }
        catch (IllegalStateException expected) {}
        System.out.println("Window selection regression scenarios passed");
    }
}''',
}
with tempfile.TemporaryDirectory(prefix='window-selection-') as directory:
    out = Path(directory)
    files = []
    for name, content in sources.items():
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        files.append(str(target))
    production = root / 'ui-inspector/vendor/android/tools/base/ui-inspector/agent/inspectors/view/src/main/java/com/android/tools/ui/inspector/inspectors/view/RootsDetector.java'
    subprocess.run([str(Path(java_home)/'bin/javac'), '-d', str(out), *files, str(production)], check=True)
    subprocess.run([str(Path(java_home)/'bin/java'), '-cp', str(out), 'com.android.tools.ui.inspector.inspectors.view.WindowSelectionTest'], check=True)
