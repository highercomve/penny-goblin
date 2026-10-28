#!/usr/bin/env python3
"""Regression checks for durable Android generation (no device needed)."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("customize", ROOT / "scripts/android-customize.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GenerationTest(unittest.TestCase):
    def test_incremental_generation_keeps_safe_identity_and_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / "platform/android", root / "platform/android")
            runtime = next((ROOT / "zig-pkg").glob("oriel-0.18.*/android/template/app/src/main/java/dev/oriel"))
            # Use the pinned package name, without relying on its cache root.
            template = root / "zig-pkg/oriel-0.18.fixture/android/template/app/src/main/java/dev/oriel"
            shutil.copytree(runtime, template)
            project = root / "android/app/src/main"
            shutil.copytree(runtime, project / "java/dev/oriel")
            (project / "java/dev/oriel/OrielHooksRegistry.kt").write_text("// DesktopHooks registered by build.zig\n")
            manifest = (runtime.parents[2] / "AndroidManifest.xml").read_text()
            for token in ("permissions", "features", "url_schemes", "audio_service", "android_components"):
                manifest = manifest.replace("@@" + token + "@@", "")
            (project / "AndroidManifest.xml").write_text(manifest)
            (project / "res/values").mkdir(parents=True)
            (project / "res/values/strings.xml").write_text('<resources><string name="app_name">Penny Goblin</string></resources>')
            (root / "android/app/build.gradle.kts").write_text('android { defaultConfig { applicationId = "com.pennygoblin.app" } }')
            module.customize(root, True)
            first = {str(p.relative_to(root)): p.read_bytes() for p in (root / "android").rglob("*") if p.is_file()}
            module.customize(root, True)
            second = {str(p.relative_to(root)): p.read_bytes() for p in (root / "android").rglob("*") if p.is_file()}
            self.assertEqual(first, second)
            self.assertIn('applicationId = "com.pennygoblin.adaptive.test"', (root / "android/app/build.gradle.kts").read_text())
            manifest = (project / "AndroidManifest.xml").read_text()
            self.assertIn("oriel:main-activity end", manifest)
            doc = ET.fromstring(manifest)
            a = module.ANDROID
            for feature in doc.findall("uses-feature"):
                self.assertEqual("false", feature.get(a + "required"))
            compare = next(x for x in doc.findall("application/activity") if x.get(a + "name") == "dev.oriel.CompareActivity")
            self.assertEqual(":compare", compare.get(a + "process"))
            self.assertEqual("true", compare.get(a + "exported"))
            module.customize(root, False)
            self.assertNotIn("FixtureProvider", (project / "AndroidManifest.xml").read_text())
            self.assertFalse((project / "java/dev/oriel/AdaptiveProbe.kt").exists())
            self.assertIn('applicationId = "com.pennygoblin.app"', (root / "android/app/build.gradle.kts").read_text())


if __name__ == "__main__":
    unittest.main()
