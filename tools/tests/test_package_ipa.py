import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("package_ipa", Path(__file__).resolve().parents[1] / "package_ipa.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def macho(platform=2, cpu=0x0100000C):
    # Mach-O 64-bit header plus LC_BUILD_VERSION, using Apple's platform IDs.
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, platform, 0x100000, 0x1B0000, 0)


class IPAPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_rejects_arm64_simulator_and_macos_binaries(self):
        executable = self.root / "App"
        for platform in (1, 7):
            with self.subTest(platform=platform):
                executable.write_bytes(macho(platform=platform))
                with self.assertRaisesRegex(ValueError, "not a simulator"):
                    packager.inspect_device_executable(executable)

    def test_rejects_truncated_load_commands(self):
        executable = self.root / "App"
        executable.write_bytes(macho()[:-1])
        with self.assertRaisesRegex(ValueError, "Truncated"):
            packager.inspect_device_executable(executable)

    def test_rejects_bundle_without_camera_usage(self):
        app = self.root / "BurstLab.app"
        app.mkdir()
        (app / "BurstLab").write_bytes(macho())
        info = {"CFBundleExecutable": "BurstLab", "CFBundleIdentifier": "dev.test.burstlab", "CFBundleShortVersionString": "0.1.0"}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "camera usage"):
            packager.package(app, self.root / "dist" / "BurstLab-unsigned.ipa")

    def test_device_package_layout_and_manifest(self):
        app = self.root / "BurstLab.app"
        app.mkdir()
        (app / "BurstLab").write_bytes(macho())
        info = {"CFBundleExecutable": "BurstLab", "CFBundleIdentifier": "dev.test.burstlab", "CFBundleShortVersionString": "0.1.0",
                "NSCameraUsageDescription": "Burst captures"}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        output = self.root / "dist" / "BurstLab-unsigned.ipa"
        packager.package(app, output)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), {"Payload/BurstLab.app/BurstLab", "Payload/BurstLab.app/Info.plist"})
            self.assertEqual(archive.read("Payload/BurstLab.app/BurstLab"), macho())
        manifest = json.loads((output.parent / "BurstLab-0.1.0-build.json").read_text())
        self.assertEqual(manifest["binary"]["platform"], "iPhoneOS")
        self.assertEqual(len(manifest["ipa_sha256"]), 64)

    def test_default_package_names_include_version(self):
        info = {"CFBundleShortVersionString": "1.4.2"}
        self.assertEqual(packager.ipa_name(info), "BurstLab-1.4.2-unsigned.ipa")
        self.assertEqual(packager.manifest_name(info), "BurstLab-1.4.2-build.json")


if __name__ == "__main__":
    unittest.main()
