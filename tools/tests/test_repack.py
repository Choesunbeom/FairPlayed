import importlib.util
import os
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

FILE = Path(__file__).resolve().parents[1] / "repack_for_iphone.py"
spec = importlib.util.spec_from_file_location("repack", FILE)
repack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repack)

class RepackTests(unittest.TestCase):
    def test_embeds_target_and_replicates_sinf(self):
        with tempfile.TemporaryDirectory() as folder:
            base, target, output = [os.path.join(folder, filename) for filename in ("base.ipa", "target.ipa", "output.ipa")]
            with zipfile.ZipFile(base, "w") as z:
                z.writestr("Payload/FairPlayed.app/FairPlayed", b"executable")
                z.writestr("Payload/FairPlayed.app/Info.plist", b"plist")
                z.writestr("Payload/FairPlayed.app/EmbeddedPayload/OLD/data", b"stale")
                z.writestr("Payload/FairPlayed.app/_CodeSignature/CodeResources", b"old signature")
            manifest = plistlib.dumps({
                "SinfPaths": ["SC_Info/Main.sinf"],
                "SinfReplicationPaths": ["Frameworks/Child.framework/SC_Info/Child.sinf", "Watch/skip.sinf"]
            })
            with zipfile.ZipFile(target, "w") as z:
                z.writestr("Payload/Game.app/Info.plist", b"plist")
                z.writestr("Payload/Game.app/Game", b"encrypted")
                z.writestr("Payload/Game.app/SC_Info/Manifest.plist", manifest)
                z.writestr("Payload/Game.app/SC_Info/Main.sinf", b"license")
                z.writestr("Payload/Game.app/Watch/Watch.app/Watch", b"skip")
            repack.repack(base, target, output)
            with zipfile.ZipFile(output) as z:
                names = set(z.namelist())
                self.assertIn("Payload/FairPlayed.app/EmbeddedPayload/Game/Game", names)
                self.assertEqual(z.read("Payload/FairPlayed.app/EmbeddedPayload/Game/Frameworks/Child.framework/SC_Info/Child.sinf"), b"license")
                self.assertNotIn("Payload/FairPlayed.app/EmbeddedPayload/OLD/data", names)
                self.assertNotIn("Payload/FairPlayed.app/_CodeSignature/CodeResources", names)
                self.assertFalse(any("/Watch/" in n for n in names))
    def test_safe_paths(self):
        self.assertTrue(repack.safe_path("Payload/Game.app/Game"))
        self.assertFalse(repack.safe_path("Payload/../evil"))
        self.assertFalse(repack.safe_path("/absolute"))
        self.assertFalse(repack.safe_path("dir\\evil"))

if __name__ == "__main__":
    unittest.main()
