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
    magic, cpu, _, filetype, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
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


def ipa_name(info):
    return f"BurstLab-{info['CFBundleShortVersionString']}-unsigned.ipa"


def manifest_name(info):
    return f"BurstLab-{info['CFBundleShortVersionString']}-build.json"


def package(app, output=None):
    app = app.resolve()
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("Input must be an Xcode .app bundle")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if output is None:
        output = Path("build/dist") / ipa_name(info)
    executable_name = info["CFBundleExecutable"]
    if Path(executable_name).name != executable_name:
        raise ValueError("CFBundleExecutable must name a file inside the bundle")
    if not info.get("NSCameraUsageDescription"):
        raise ValueError("Missing camera usage description")
    if info.get("CFBundleIdentifier") != "dev.lucas.burstlab.ios":
        raise ValueError("Unexpected BurstLab bundle identifier")
    if not info.get("NSPhotoLibraryAddUsageDescription"):
        raise ValueError("Missing photo library add usage description")
    binary = inspect_device_executable(app / executable_name)
    paths = sorted(app.rglob("*"))
    if any(p.name == "embedded.mobileprovision" or p.name == "_CodeSignature" for p in paths):
        raise ValueError("Expected an unsigned bundle without a provisioning profile")
    manifest_path = output.with_name(manifest_name(info))
    if output.exists() or manifest_path.exists():
        raise FileExistsError("Build artifact already exists; use a new version or a different output directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
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
            "iPhone only. RAW probe; quality-biased Photo selects 12/16/20 frames "
            "from the first RAW shadow signal/noise model, with a retained-payload cap. Tripod modes use 16 frames. "
            "Photo refines local even-pixel translations on green-quad guides and applies a residual-noise-aware "
            "spectral finish after reference-anchored frequency merge. Demosaic, DNG-derived color "
            "transform with fallback white balance, bounded local SDR tone mapping and chroma denoise. "
            "Frequency-based motion rejection and local registration are experimental; subpixel alignment, super-resolution, HDR gain maps, "
            "automatic tripod detection and handheld night are not implemented. Explicit Night trades shutter "
            "duration (up to 0.5 s/frame) for lower ISO with robust fusion; Long uses equal-weight accumulation "
            "for motion trails. Night detects bright RAW highlights and can interleave 12 long/4 short frames, "
            "normalizing measured exposures into wide RAW radiance before local highlight compression. "
            "Bracket motion recovery is experimental. Photo uses guided spatial preview intent in scene-linear light "
            "when a matching proxy is available, retaining global rendering as fallback. Preview tone precedes the final gamut fit. "
            "Touch sets focus/exposure points. An on-demand CIRAWFilter comparison renders a saved single DNG "
            "at half dimensions, recording the decoder available on the OS; it does not replace burst processing. "
            "RAW diagnostics are one-shot, replace the previous export, are limited to 512 MiB and expire on app use after 24 hours. "
            "One capture receipt and tiny preview, up to 64 KiB total, replace themselves and share the expiration/cleanup policy. "
            "Image quality, peak "
            "memory and latency require measurement on iPhone SE 2022; see docs/roadmap.md."
        ),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Unsigned device IPA: {output}")
    print(f"Build manifest: {manifest_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, help="Defaults to build/dist/BurstLab-<version>-unsigned.ipa")
    args = parser.parse_args()
    package(args.app, args.output)
