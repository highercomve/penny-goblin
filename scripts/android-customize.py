#!/usr/bin/env python3
"""Durable, guarded customizations of Oriel's generated Android project.

Never change zig-pkg. Run after android-project and before Gradle, including
incremental builds. Unknown framework anchors fail rather than silently drift.
"""
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
ET.register_namespace("android", ANDROID[1:-1])


def customize(root: Path, test_profile=False):
    project = root / "android/app/src/main"
    source = project / "java/dev/oriel"
    shutil.copy2(root / "platform/android/DesktopHooks.kt", source / "DesktopHooks.kt")
    shutil.copy2(root / "platform/android/CompareActivity.kt", source / "CompareActivity.kt")
    activity_file = source / "OrielActivity.kt"
    text = activity_file.read_text()
    anchor = "    override fun dispatchKeyEvent(event: KeyEvent): Boolean {"
    if "// Penny Goblin compare window" not in text:
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '''
        // Penny Goblin compare window: separate native globals, shared SQLite ledger.
        if (event.keyCode == KeyEvent.KEYCODE_N && event.isCtrlPressed && event.isAltPressed) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                startActivity(Intent(this, CompareActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT))
            }
            return true
        }
''')
        activity_file.write_text(text)
    # Expose app shortcuts in Android's keyboard-shortcut helper.
    text = activity_file.read_text()
    anchor = "        val list = OrielRuntime.shortcuts"
    if "// Penny Goblin shortcut reference" not in text:
        assert text.count(anchor) == 1
        text = text.replace(anchor, '''        // Penny Goblin shortcut reference
        data.add(KeyboardShortcutGroup("Penny Goblin", listOf(
            KeyboardShortcutInfo("New payment", KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON),
            KeyboardShortcutInfo("New receipt", KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON),
            KeyboardShortcutInfo("Find payments", KeyEvent.KEYCODE_F, KeyEvent.META_CTRL_ON),
            KeyboardShortcutInfo("Save payment", KeyEvent.KEYCODE_S, KeyEvent.META_CTRL_ON),
            KeyboardShortcutInfo("Refresh", KeyEvent.KEYCODE_R, KeyEvent.META_CTRL_ON),
            KeyboardShortcutInfo("Comparison window", KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON or KeyEvent.META_ALT_ON)
        )))
''' + anchor)
        activity_file.write_text(text)
    native = source / "OrielNative.kt"
    templates = list((root / "zig-pkg").glob("oriel-0.18.*/android/template/app/src/main/java/dev/oriel/OrielNative.kt"))
    assert len(templates) == 1, "Review customizations before upgrading Oriel"
    content = templates[0].read_text()
    marker = "    // Penny Goblin desktop native state and scale."
    if marker not in content:
        anchor = "    private var density = resources.displayMetrics.density"
        assert content.count(anchor) == 1
        support = (root / "platform/android/native-desktop.inc.kt").read_text()
        content = content.replace(anchor, support + "\n" + anchor)
        content = content.replace("Nui.cssScale(w, resources.displayMetrics.density)", "Nui.cssScale(w, desktopScale(resources.displayMetrics.density))")
        content = content.replace("val scale = resources.displayMetrics.density", "val scale = desktopScale(resources.displayMetrics.density)")
        content = content.replace("val k = cssScale(wp, m.density)", "val k = cssScale(wp, v?.desktopScale(m.density) ?: m.density)")
        # Density/fontScale changes must relayout even without a physical size/dark-mode change.
        content = content.replace('NuiNative.event(window, 0, "dpr".bytes(), scale.toString().bytes())', 'NuiNative.event(window, 0, "dpr".bytes(), scale.toString().bytes())\n            if (width > 0) NuiNative.resize(window, cssWidth(width), cssHeight(height), dark)')
        anchor = "                if (!dragging && !longPressed) {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, "                if (!dragging && !longPressed && !pageDrag) {")
        anchor = "if (f.visibility != INVISIBLE) { f.visibility = INVISIBLE; invalidate() }"
        assert content.count(anchor) == 1
        content = content.replace(anchor, "if (f.visibility != INVISIBLE) { desktopRememberFocus(f); f.visibility = INVISIBLE; invalidate() }")
        anchor = "        if (Nui.dump) dumpFrames()"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n        desktopRelayout()")
        content = content.replace("v.setTextSize(TypedValue.COMPLEX_UNIT_DIP, fz)", "v.setTextSize(TypedValue.COMPLEX_UNIT_PX, fz * density)")
        anchor = "    override fun onConfigurationChanged(newConfig: Configuration) {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n        desktopRelayout(true)")
        anchor = "    override fun onGenericMotionEvent(e: MotionEvent): Boolean {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + '\n        desktopScrollUntil = android.os.SystemClock.uptimeMillis() + 1000\n        invalidate()\n        if (e.actionMasked == MotionEvent.ACTION_SCROLL && e.metaState and KeyEvent.META_CTRL_ON != 0) { desktopZoom(desktopZoomFactor * Math.pow(1.1, e.getAxisValue(MotionEvent.AXIS_VSCROLL).toDouble()).toFloat()); return true }')
        anchor = "    internal fun handleDrag(e: android.view.DragEvent, ox: Float, oy: Float): Boolean {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n        DesktopHooks.nativeDrag(this, e)?.let { return it }")
        anchor = "    override fun onResolvePointerIcon(e: MotionEvent, pointerIndex: Int): PointerIcon? {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n        if (desktopFieldAt(e.x, e.y) is EditText) return PointerIcon.getSystemIcon(context, PointerIcon.TYPE_TEXT)")
        anchor = "    override fun onTouchEvent(e: MotionEvent): Boolean {"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n        desktopPinch.onTouchEvent(e)\n        if (desktopPinch.isInProgress) return true")
        anchor = "            drawPage(canvas)"
        assert content.count(anchor) == 1
        content = content.replace(anchor, anchor + "\n            desktopScrollbars(canvas)")
        native.write_text(content)
    registry = source / "OrielHooksRegistry.kt"
    content = registry.read_text()
    # Registry's generated list is configured by build.zig, so no Kotlin registry patch.
    assert "DesktopHooks" in content, "DesktopHooks must be declared in build.zig"
    manifest = project / "AndroidManifest.xml"
    tree = ET.parse(manifest)
    doc = tree.getroot()
    for name in ("android.hardware.touchscreen", "android.hardware.camera", "android.hardware.camera.autofocus", "android.hardware.camera.any"):
        feature = next((x for x in doc.findall("uses-feature") if x.get(ANDROID + "name") == name), None)
        if feature is None:
            feature = ET.SubElement(doc, "uses-feature", {ANDROID + "name": name})
        feature.set(ANDROID + "required", "false")
    activity = next(x for x in doc.findall("application/activity") if x.get(ANDROID + "name") == "dev.oriel.OrielMainActivity")
    if not any(x.get(ANDROID + "label") == "Penny Goblin attachments" for x in activity.findall("intent-filter")):
        f = ET.SubElement(activity, "intent-filter", {ANDROID + "label": "Penny Goblin attachments"})
        ET.SubElement(f, "action", {ANDROID + "name": "android.intent.action.VIEW"})
        for category in ("DEFAULT", "BROWSABLE"):
            ET.SubElement(f, "category", {ANDROID + "name": "android.intent.category." + category})
        ET.SubElement(f, "data", {ANDROID + "scheme": "content"})
        for mime in ("image/jpeg", "image/png", "application/pdf"):
            ET.SubElement(f, "data", {ANDROID + "mimeType": mime})
    # Preserve Oriel's generation markers: ElementTree drops comments by default.
    # Only serialize when using a parser that retains comments on subsequent runs.
    text = manifest.read_text()
    for name in ("android.hardware.touchscreen", "android.hardware.camera", "android.hardware.camera.autofocus", "android.hardware.camera.any"):
        pattern = rf'<uses-feature\b[^>]*android:name="{re.escape(name)}"[^>]*/>'
        declaration = f'<uses-feature android:name="{name}" android:required="false" />'
        if re.search(pattern, text):
            text = re.sub(pattern, declaration, text)
        else:
            text = text.replace('<application', declaration + '\n    <application', 1)
    if 'android:label="Penny Goblin attachments"' not in text:
        fragment = ET.tostring(f, encoding="unicode").replace(' xmlns:android="http://schemas.android.com/apk/res/android"', '')
        anchor = '<!-- oriel:main-activity end -->'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n' + fragment)
    if 'android:name="dev.oriel.CompareActivity"' not in text:
        text = text.replace("<!-- oriel:components end -->", '''<!-- oriel:components end -->
        <activity android:name="dev.oriel.CompareActivity" android:process=":compare"
            android:taskAffinity="${applicationId}.compare" android:exported="false"
            android:launchMode="singleTask" android:resizeableActivity="true"
            android:windowSoftInputMode="adjustResize"
            android:configChanges="orientation|screenSize|smallestScreenSize|screenLayout|keyboard|keyboardHidden|navigation|uiMode|density|fontScale|layoutDirection|locale" />''')
    if test_profile:
        text = text.replace('android:name="dev.oriel.CompareActivity" android:process=":compare"', 'android:name="dev.oriel.CompareActivity" android:process=":compare"')
        text = re.sub(r'(android:name="dev.oriel.CompareActivity"[^>]*android:exported=")[^"]+', r'\g<1>true', text)
    else:
        text = re.sub(r'(android:name="dev.oriel.CompareActivity"[^>]*android:exported=")[^"]+', r'\g<1>false', text)
    fixture_name = "dev.oriel.FixtureProvider"
    if test_profile:
        for file in (root / "platform/android/test").glob("*.kt"):
            shutil.copy2(file, source / file.name)
        if fixture_name not in text:
            text = text.replace("</application>", '<provider android:name="dev.oriel.FixtureProvider" android:authorities="${applicationId}.fixtures" android:exported="true" android:grantUriPermissions="true" /></application>')
    else:
        for name in ("AdaptiveProbe.kt", "FixtureProvider.kt"):
            (source / name).unlink(missing_ok=True)
        text = re.sub(r'<provider\b[^>]*android:name="dev.oriel.FixtureProvider"[^>]*/>', '', text)
    manifest.write_text(text)
    gradle = root / "android/app/build.gradle.kts"
    text = gradle.read_text()
    app_id = "com.pennygoblin.adaptive.test" if test_profile else "com.pennygoblin.app"
    text, count = re.subn(r'applicationId = "[^"]+"', f'applicationId = "{app_id}"', text)
    assert count == 1
    gradle.write_text(text)
    strings = project / "res/values/strings.xml"
    label = "Penny Goblin Adaptive Test" if test_profile else "Penny Goblin"
    text = re.sub(r'(<string name="app_name">)[^<]*(</string>)', lambda m: m[1] + label + m[2], strings.read_text())
    strings.write_text(text)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-profile", action="store_true")
    args = parser.parse_args()
    customize(Path(__file__).resolve().parents[1], args.test_profile)
