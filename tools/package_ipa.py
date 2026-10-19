"""Package an iPhone-device build for local signing; no Apple credentials required."""
import argparse
import hashlib
import json
import os
import plistlib
import stat
import struct
import zipfile
from pathlib import Path


def inspect_device_executable(path):
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError("Executable is shorter than a Mach-O 64-bit header")
    magic, cpu, _, _, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError("Expected a thin arm64 Mach-O executable for iPhone")
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError("Truncated Mach-O load commands")
    offset = 32
    platforms = []
    signed = False
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Invalid Mach-O command table")
        command, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid Mach-O command length")
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("Invalid LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        if command == 0x25:  # LC_VERSION_MIN_IPHONEOS, older toolchains
            platforms.append(2)
        if command == 0x1D:  # LC_CODE_SIGNATURE
            signed = True
        offset += size
    if offset != end or not platforms or any(p != 2 for p in platforms):
        raise ValueError("Expected an iPhoneOS device build, not a simulator executable")
    if signed:
        raise ValueError("Expected an unsigned build; executable already declares a code signature")
    return {"architecture": "arm64", "platform": "iPhoneOS", "code_signature": False}


def package(app, output):
    app = app.resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Input must be an Xcode .app bundle")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable_name = info["CFBundleExecutable"]
    if Path(executable_name).name != executable_name:
        raise ValueError("CFBundleExecutable must name a file inside the bundle")
    if not info.get("NSCameraUsageDescription"):
        raise ValueError("Missing camera usage description")
    binary = inspect_device_executable(app / executable_name)
    paths = sorted(app.rglob("*"))
    if any(p.name == "embedded.mobileprovision" or p.name == "_CodeSignature" for p in paths):
        raise ValueError("Expected an unsigned bundle without a provisioning profile")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            if path.is_dir() and not path.is_symlink():
                continue
            name = "Payload/" + app.name + "/" + path.relative_to(app).as_posix()
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = path.lstat().st_mode << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            if path.is_symlink():
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path).encode())
            else:
                archive.writestr(entry, path.read_bytes())
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA archive integrity check failed")
    manifest = {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "binary": binary,
        "ipa_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "installation": "Must be signed locally before installation on iPhone",
        "scope": (
            "iPhone only. F1: capability probe (RAW/processed formats, ISO, exposure, memory) plus single JPEG capture "
            "saved to Photos. The burst pipeline (alignment, merge, night, long exposure, look) is not implemented yet; "
            "see docs/roadmap.md. RAW availability on iPhone SE 2022 is still unverified on hardware."
        ),
    }
    manifest_path = output.with_name("BurstLab-build.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Unsigned device IPA: {output}")
    print(f"Build manifest: {manifest_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/dist/BurstLab-unsigned.ipa"))
    args = parser.parse_args()
    package(args.app, args.output)
